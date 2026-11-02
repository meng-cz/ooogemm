#!/usr/bin/env python3
"""Validate completed cases, pair controls, and export CSV/SVG ablation reports."""
from __future__ import annotations
import argparse
import csv
import json
import math
import os
from pathlib import Path
import statistics
import sys
from collections import defaultdict

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT))
from lab.ablation.core import REASONS, canonical, digest
from lab.ablation.results import validate


def comparison_key(spec, include_logical):
    spec = json.loads(canonical(spec))
    spec['hardware'].pop('mode')
    if not include_logical:
        for key in ('a_logic', 'b_logic', 'acc_logic'):
            spec['hardware'].pop(key)
    return canonical(spec)


def read_results(root):
    results = []
    for path in sorted(root.rglob('result.json')):
        result = json.loads(path.read_text())
        if result['status'] != 'complete':
            raise ValueError(f'incomplete result: {path}')
        validate(result['metrics'], result['spec'])
        results.append(result)
    return results


def flatten(results):
    controls = {(r['spec']['hardware']['mode'], comparison_key(r['spec'], True)): r for r in results}
    static = {comparison_key(r['spec'], False): r for r in results if r['spec']['hardware']['mode'] == 'static'}
    rows = []
    for result in results:
        spec, stats = result['spec'], result['metrics']
        hw = spec['hardware']
        row = dict(hw, m=spec['mnk'][0], n=spec['mnk'][1], k=spec['mnk'][2], count=spec['count'],
                   **spec['delay'], trace=spec['trace'], id=digest(spec), studies=','.join(result['studies']))
        for key in ('cycles', 'throughput', 'latency', 'input_bus_util', 'output_bus_util', 'lane_active',
                    'mac_active', 'whole_array_idle_cycles', 'requests', 'responses', 'peak_outstanding',
                    'reordered_responses', 'store_beats', 'output_hash'):
            row[key] = stats[key]
        row['mac_utilization'] = stats['mac_active']/(stats['cycles']*hw['lane']*hw['width']**2)
        row['useful_utilization'] = math.prod(spec['mnk'])*spec['count']/(stats['cycles']*hw['lane']*hw['width']**2)
        for category in ('sampled_delay', 'observed_delay'):
            for key, value in stats[category].items(): row[category+'_'+key] = value
        for reason in REASONS:
            row['lane_idle_'+reason] = stats['lane_idle'][reason]
            row['mac_idle_'+reason] = stats['mac_idle'][reason]
            row['mac_idle_share_'+reason] = stats['mac_idle'][reason]/(stats['cycles']*hw['lane']*hw['width']**2)
            row['blocker_'+reason] = stats['blocker_cycles'][reason]
        row['blocks'] = canonical(stats['blocks'])
        row['speedup_static'] = row['speedup_gemm_inorder'] = ''
        row['static_logical_match'] = row['inorder_output_match'] = row['static_output_match'] = ''
        if hw['mode'] == 'dynamic':
            other = controls.get(('dynamic_inorder', comparison_key(spec, True)))
            if other:
                row['speedup_gemm_inorder'] = other['metrics']['cycles']/stats['cycles']
                row['inorder_output_match'] = other['metrics']['output_hash'] == stats['output_hash']
            other = static.get(comparison_key(spec, False))
            if other:
                row['speedup_static'] = other['metrics']['cycles']/stats['cycles']
                row['static_logical_match'] = all(other['spec']['hardware'][k] == hw[k] for k in ('a_logic', 'b_logic', 'acc_logic'))
                row['static_output_match'] = other['metrics']['output_hash'] == stats['output_hash']
        rows.append(row)
    return rows


def aggregate(rows):
    keys = ('mode', 'lane', 'width', 'a', 'b', 'acc', 'a_logic', 'b_logic', 'acc_logic',
            'store_rows', 'slot_acc_count', 'optimization', 'subtile_k', 'load_data_width', 'm', 'n', 'k', 'count',
            'distribution', 'mean', 'trace')
    groups = defaultdict(list)
    for row in rows: groups[tuple(row[k] for k in keys)].append(row)
    output = []
    for key, group in groups.items():
        row = dict(zip(keys, key), seeds=len(group))
        row['studies'] = ','.join(sorted(set(s for r in group for s in r['studies'].split(','))))
        for metric in ('throughput', 'latency', 'mac_utilization', 'useful_utilization', 'requests',
                       'speedup_static', 'speedup_gemm_inorder', *('mac_idle_share_'+r for r in REASONS)):
            match_field = {'speedup_static':'static_output_match',
                           'speedup_gemm_inorder':'inorder_output_match'}.get(metric)
            values = [r[metric] for r in group if r[metric] != '' and
                      (match_field is None or r[match_field] is True)]
            row[metric+'_mean'] = statistics.mean(values) if values else ''
            row[metric+'_std'] = statistics.stdev(values) if len(values) > 1 else (0 if values else '')
            if match_field:
                row[metric+'_pairs'] = len(values)
        output.append(row)
    return output


def write_csv(path, rows):
    if not rows: return
    with path.open('w', newline='') as f:
        writer = csv.DictWriter(f, fieldnames=list(rows[0]))
        writer.writeheader(); writer.writerows(rows)


def plots(rows, directory):
    os.environ.setdefault('MPLCONFIGDIR', '/tmp/ooogemm-ablation-matplotlib')
    import matplotlib
    matplotlib.use('Agg')
    import matplotlib.pyplot as plt
    import numpy as np
    colors = dict(static='#666666', dynamic='#1673b8', dynamic_inorder='#d36b23')
    views = defaultdict(list)
    for row in rows:
        if not row['trace']:
            views[(row['lane'],row['width'],row['m'],row['n'],row['k'],row['count'])].append(row)
    outputs = []
    for view, group in views.items():
        lane, width, m, n, k, count = view
        stem=f'L{lane}_W{width}_{m}x{n}x{k}_Cnt{count}'
        latency = [r for r in group if 'latency' in r['studies'].split(',')]
        if latency:
            fig, ax = plt.subplots(figsize=(7,4))
            for mode in colors:
                for distribution, style in [('fixed','-'), ('uniform','--'), ('longtail',':')]:
                    line = sorted([r for r in latency if r['mode']==mode and r['distribution']==distribution], key=lambda r:r['mean'])
                    if line:
                        ax.errorbar([r['mean'] for r in line], [r['throughput_mean'] for r in line],
                                    yerr=[r['throughput_std'] for r in line], color=colors[mode],
                                    linestyle=style, marker='o', label=f'{mode}/{distribution}')
            ax.set(xlabel='Theoretical mean response delay (cycles)', ylabel='GEMM / Kcycle', title=stem)
            ax.legend(fontsize=7); ax.grid(alpha=.2); fig.tight_layout()
            path=directory/f'latency_{stem}.svg'; fig.savefig(path); plt.close(fig); outputs.append(path)
        idle = [r for r in group if 'idle' in r['studies'].split(',') and r['distribution']=='fixed' and r['mean']==4]
        if idle:
            fig, ax=plt.subplots(figsize=(8,4))
            bottom=np.zeros(len(idle))
            names=[r['mode'] for r in idle]
            ax.bar(names,[r['mac_utilization_mean'] for r in idle],label='active',color='#339966')
            bottom += [r['mac_utilization_mean'] for r in idle]
            for reason in REASONS:
                values=np.array([r['mac_idle_share_'+reason+'_mean'] for r in idle])
                if values.any():
                    ax.bar(names,values,bottom=bottom,label=reason); bottom+=values
            ax.set(ylabel='Fraction of physical MAC opportunities', ylim=(0,1), title=stem)
            ax.legend(fontsize=7,bbox_to_anchor=(1.02,1),loc='upper left'); fig.tight_layout()
            path=directory/f'idle_{stem}.svg'; fig.savefig(path); plt.close(fig); outputs.append(path)
        baseline = next((r for r in idle if r['mode']=='dynamic'), None)
        if baseline:
            capacity=[r for r in group if r['mode']=='dynamic' and 'capacity' in r['studies'].split(',')]
            for distribution, mean in sorted({(r['distribution'],r['mean']) for r in capacity}):
                for resource in ('ab','acc'):
                    candidates=[]
                    for r in capacity:
                        if (r['distribution'],r['mean']) != (distribution,mean): continue
                        if resource=='ab':
                            valid=(r['a']==r['b'] and r['a_logic']==r['b_logic'] and
                                   (r['acc'],r['acc_logic'])==(baseline['acc'],baseline['acc_logic']))
                            x,y=r['a'],r['a_logic']
                        else:
                            valid=all(r[f]==baseline[f] for f in ('a','b','a_logic','b_logic'))
                            x,y=r['acc'],r['acc_logic']
                        if valid and r['speedup_gemm_inorder_mean']!='': candidates.append((x,y,r['speedup_gemm_inorder_mean']))
                    if not candidates: continue
                    xs=sorted({p[0] for p in candidates}); ys=sorted({p[1] for p in candidates})
                    matrix=np.full((len(ys),len(xs)),np.nan)
                    for x,y,value in candidates: matrix[ys.index(y),xs.index(x)]=value
                    fig,ax=plt.subplots(figsize=(6,4))
                    image=ax.imshow(np.ma.masked_invalid(matrix),origin='lower',aspect='auto',cmap='viridis')
                    ax.set_xticks(range(len(xs)),xs); ax.set_yticks(range(len(ys)),ys)
                    ax.set(xlabel=f'{resource.upper()} physical entries',ylabel=f'{resource.upper()} logical entries',title=f'{stem} {distribution}/{mean}')
                    fig.colorbar(image,ax=ax,label='Dynamic / GEMM-in-order throughput')
                    fig.tight_layout(); path=directory/f'capacity_{resource}_{stem}_{distribution}_{mean}.svg'
                    fig.savefig(path); plt.close(fig); outputs.append(path)
    return outputs


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--data-root',type=Path,default=ROOT/'data/ablation/full')
    parser.add_argument('--out-dir',type=Path)
    parser.add_argument('--no-plots',action='store_true')
    args=parser.parse_args()
    results=read_results(args.data_root)
    if not results: parser.error(f'no completed results in {args.data_root}')
    directory=args.out_dir or args.data_root/'summary'
    directory.mkdir(parents=True,exist_ok=True)
    rows=flatten(results); grouped=aggregate(rows)
    write_csv(directory/'runs.csv',rows)
    write_csv(directory/'aggregate.csv',grouped)
    comparisons=[{k:r[k] for k in ('id','lane','width','m','n','k','distribution','mean','seed',
                    'a','b','acc','a_logic','b_logic','acc_logic','speedup_static','speedup_gemm_inorder',
                    'static_logical_match','inorder_output_match','static_output_match')} for r in rows if r['mode']=='dynamic']
    write_csv(directory/'comparisons.csv',comparisons)
    figures=[] if args.no_plots else plots(grouped,directory)
    lines=['# GEMM ablation report','',f'Validated runs: {len(results)}; seed groups: {len(grouped)}.',
           '', 'Ratios greater than 1 indicate higher dynamic throughput. Static comparisons match physical capacity; '
           '`static_logical_match` identifies equal logical capacity. GEMM-in-order comparisons match every hardware parameter.',
           '', 'MAC shares use physical PE/lane execution opportunities. Padding work is included in physical activity; '
           'useful utilization uses the requested MNK. Primary idle reasons partition idle opportunities; raw blockers may overlap.',
           '', 'Seed standard deviation is zero for a single observation; it is not a confidence interval. '
           'Sampled delays have equal theoretical means, not necessarily identical finite-sample means.']
    if args.data_root.name=='smoke': lines+=['','This is a bounded functional smoke run, not evidence for full-scale performance conclusions.']
    lines+=['','## Output consistency','','| Reference | Matching payload checksums | Different payload checksums |',
            '| --- | ---: | ---: |']
    for field,label in [('static_output_match','static'),('inorder_output_match','GEMM in order')]:
        lines.append(f'| {label} | {sum(r[field] is True for r in rows)} | {sum(r[field] is False for r in rows)} |')
    lines+=['','Different checksums require investigation; they are not treated as validated speedups. '
            'The checksum covers the complete stored payload, including padded entries. '
            'runs.csv and comparisons.csv retain raw timing ratios and the matching flags; aggregate.csv and the table below exclude mismatched pairs.',
            '', '## Paired dynamic measurements','','| Reference | Matching pairs | Mean ratio | Min | Max |', '| --- | ---: | ---: | ---: | ---: |']
    for key,field,label in [('speedup_static','static_output_match','static'),
                            ('speedup_gemm_inorder','inorder_output_match','GEMM in order')]:
        values=[r[key] for r in rows if r[key]!='' and r[field] is True]
        if values: lines.append(f'| {label} | {len(values)} | {statistics.mean(values):.4f} | {min(values):.4f} | {max(values):.4f} |')
    lines+=['','The table pools configurations for navigation; use aggregate.csv and the per-shape figures for controlled comparisons.',
            '', f'Generated {len(figures)} SVG figures. Blank heatmap cells have no valid paired measurement.']
    (directory/'report.md').write_text('\n'.join(lines)+'\n')
    print(f'Validated {len(results)} runs; report={directory / "report.md"}; figures={len(figures)}')
    return 0


if __name__=='__main__':
    raise SystemExit(main())
