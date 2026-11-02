#!/usr/bin/env python3
"""Bounded verification: unit tests, optional production lint and 40-case smoke."""
import argparse
from pathlib import Path
import subprocess
import sys

ROOT=Path(__file__).resolve().parents[2]
sys.path.insert(0,str(ROOT))
from lab.ablation.core import HERE, MODES, build_command
from lab.ablation.run_experiments import base_hardware, read_config


def logged(command,path):
    path.parent.mkdir(parents=True,exist_ok=True)
    with path.open('w') as log:
        rc=subprocess.run(command,cwd=ROOT,stdout=log,stderr=subprocess.STDOUT).returncode
    if rc:
        print(path.read_text()[-8000:],file=sys.stderr)
        raise RuntimeError(f'check failed ({rc}); log={path}')
    print(f'PASS log={path}',flush=True)


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--lint',action='store_true')
    parser.add_argument('--smoke',action='store_true')
    parser.add_argument('--check-dir',type=Path,default=Path('/tmp/ooogemm_ablation_checks'))
    args=parser.parse_args()
    directory=args.check_dir.resolve(); directory.mkdir(parents=True,exist_ok=True)
    subprocess.run([sys.executable,'-m','unittest','lab.test_full_builds',
                    'lab.ablation.test_experiments','-v'],cwd=ROOT,check=True)
    memory=directory/'test_memory'
    logged(['c++','-std=c++17','-O2','-I',str(HERE),str(HERE/'test_memory.cpp'),'-o',str(memory)], directory/'memory-build.log')
    subprocess.run([str(memory)],check=True)
    for policy in (0,1):
        target=directory/f'scheduler-{policy}'
        logged(['verilator','--binary','--timing','--assert','--top-module','test_scheduler',
                '-Wno-TIMESCALEMOD','--Mdir',str(target),f"-GIN_ORDER=1'b{policy}",
                str(ROOT/'src/sche/uop.sv'),str(ROOT/'src/sche/dynamic_sche.sv'),str(HERE/'test_scheduler.sv')],target/'build.log')
        subprocess.run([str(target/'Vtest_scheduler')],check=True)
    if args.lint:
        config=read_config(HERE/'defaults.json')
        for entry in config['hardware']:
            for mode in MODES:
                hw=base_hardware(entry,mode,config)
                logged(build_command(hw,lint=True),directory/f'lint-L{hw.lane}-{mode}.log')
    if args.smoke:
        subprocess.run([sys.executable,'lab/full.py','--experiments','ablation','--ablation-profile','smoke',
                        '--count','2','-j','2'],cwd=ROOT,check=True)
        from lab.ablation.summarize import read_results, flatten
        rows=flatten(read_results(ROOT/'data/ablation/smoke'))
        if any(r['inorder_output_match'] is False for r in rows):
            raise RuntimeError('GEMM policy change altered paired output payloads')
        differences=sum(r['static_output_match'] is False for r in rows)
        if differences:
            print(f'NOTICE: {differences} static/dynamic payload comparisons differ; '
                  'see README validation findings and exclude these pairs from validated speedups.')
    print('All requested bounded checks passed. No full experiment matrix was run.')
    return 0


if __name__=='__main__':
    raise SystemExit(main())
