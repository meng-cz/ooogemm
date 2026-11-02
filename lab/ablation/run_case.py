#!/usr/bin/env python3
"""Run one canonical case and atomically publish a validated completion JSON."""
import argparse
import fcntl
import json
import math
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT))
from lab.ablation.core import Hardware, build, canonical, digest
from lab.ablation.results import queue_layout, validate


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--spec', required=True)
    parser.add_argument('--out-dir', type=Path, required=True)
    parser.add_argument('--studies', default='')
    parser.add_argument('--timeout', type=int, default=14400)
    args = parser.parse_args()
    spec = json.loads(args.spec)
    hw = Hardware(**spec['hardware'])
    directory = args.out_dir.resolve()
    directory.mkdir(parents=True, exist_ok=True)
    with (directory/'run.lock').open('w') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        result_path = directory/'result.json'
        result_path.unlink(missing_ok=True)
        stats_path = directory/'stats.partial.json'
        stats_path.unlink(missing_ok=True)
        exe = build(hw)
        m, n, k = spec['mnk']
        delay = spec['delay']
        # Conservative upper bound includes serialized worst-case responses.
        tm, tn, tk = math.ceil(m/hw.width), math.ceil(n/hw.width), math.ceil(k/hw.subtile_k)
        max_delay = 16*delay['mean'] if delay['distribution'] == 'longtail' else 2*delay['mean']
        max_requests = spec['count']*tm*tn*tk*2*math.ceil(hw.width*hw.subtile_k*8/hw.load_data_width)
        max_cycles = 200000 + max_requests*(max_delay+128) + spec['count']*tm*tn*tk*256
        command = [str(exe), f'--m={m}', f'--n={n}', f'--k={k}', f'--count={spec["count"]}',
                   f'--max-cycles={max_cycles}', f'--out={directory / "metrics.txt"}',
                   f'--delay-distribution={delay["distribution"]}', f'--delay-mean={delay["mean"]}',
                   f'--delay-seed={delay["seed"]}', f'--ablation-stats={stats_path}']
        if spec['trace']:
            command.append(f'--cycle-trace={directory / "cycles.csv"}')
        print('ablation: case', digest(spec), ' '.join(command), flush=True)
        child = subprocess.Popen(command, start_new_session=True)
        def stop(signum, frame):
            if child.poll() is None:
                os.killpg(child.pid, signal.SIGTERM)
                child.wait()
            raise SystemExit(128+signum)
        signal.signal(signal.SIGTERM, stop)
        signal.signal(signal.SIGINT, stop)
        try:
            rc = child.wait(timeout=args.timeout)
        except subprocess.TimeoutExpired:
            os.killpg(child.pid, signal.SIGKILL)
            child.wait()
            raise RuntimeError(f'simulation exceeded {args.timeout} seconds')
        if rc:
            raise RuntimeError(f'simulation failed: rc={rc}')
        metrics = json.loads(stats_path.read_text())
        validate(metrics, spec)
        metrics['mac_utilization'] = metrics['mac_active']/(metrics['cycles']*hw.lane*hw.width**2)
        metrics['useful_utilization'] = m*n*k*spec['count']/(metrics['cycles']*hw.lane*hw.width**2)
        metrics['lane_idle_share'] = {r:v/(metrics['cycles']*hw.lane) for r,v in metrics['lane_idle'].items()}
        metrics['mac_idle_share'] = {r:v/(metrics['cycles']*hw.lane*hw.width**2) for r,v in metrics['mac_idle'].items()}
        idle_total = sum(metrics['mac_idle'].values())
        metrics['mac_idle_composition'] = {r:v/idle_total if idle_total else 0 for r,v in metrics['mac_idle'].items()}
        result = {'status':'complete', 'spec':spec, 'studies':args.studies.split(','),
                  'queue_layout':queue_layout(hw), 'metrics':metrics}
        # The completion marker contains every required statistic. Incomplete
        # logs, metrics.txt, or raw JSON are never sufficient for resume.
        with tempfile.NamedTemporaryFile('w', dir=directory, prefix='.result-', delete=False) as out:
            temporary = Path(out.name)
            try:
                out.write(canonical(result)+'\n')
                out.flush()
                os.fsync(out.fileno())
            except BaseException:
                temporary.unlink(missing_ok=True)
                raise
        temporary.replace(result_path)
        stats_path.unlink()
        print(f'ablation: complete result={result_path}', flush=True)
    return 0


if __name__ == '__main__':
    try:
        raise SystemExit(main())
    except (RuntimeError, ValueError, OSError) as exc:
        print(f'ablation: failed: {exc}', file=sys.stderr, flush=True)
        raise SystemExit(1)
