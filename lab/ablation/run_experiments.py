#!/usr/bin/env python3
"""Independent ablation task source, also consumed by lab/full.py."""
from __future__ import annotations

import argparse
import json
import os
import sys
from dataclasses import asdict, dataclass, replace
from pathlib import Path

ROOT_DIR = Path(__file__).resolve().parents[2]
if str(ROOT_DIR) not in sys.path:
    sys.path.insert(0, str(ROOT_DIR))
from lab.ablation.core import HERE, MODES, SCHEMA_VERSION, Hardware, build, build_dir, canonical, digest
from lab.ablation.results import complete


MAX_FULL_TASKS = 299


@dataclass(frozen=True)
class Task:
    hw: Hardware
    m: int
    n: int
    k: int
    count: int
    distribution: str
    mean: int
    seed: int
    studies: tuple[str, ...]
    out_dir: Path
    out_file: Path
    log_file: Path
    trace: bool = False
    timeout: int = 14400

    @property
    def axis(self):
        return '+'.join(self.studies)

    @property
    def spec(self):
        return {'schema_version': SCHEMA_VERSION, 'hardware': asdict(self.hw),
                'mnk': [self.m, self.n, self.k], 'count': self.count,
                'delay': {'distribution': self.distribution, 'mean': self.mean, 'seed': self.seed},
                'trace': self.trace}


def make_parser():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('-j', '--jobs', type=int, default=12)
    parser.add_argument('--count', type=int, default=100)
    parser.add_argument('--ablation-profile', choices=('full', 'smoke'), default='full')
    parser.add_argument('--ablation-config', type=Path, default=HERE/'defaults.json')
    parser.add_argument('--ablation-studies', default='latency,idle,capacity')
    parser.add_argument('--ablation-trace', action='store_true')
    parser.add_argument('--data-root', type=Path, default=ROOT_DIR/'data/ablation')
    parser.add_argument('--force', action='store_true')
    parser.add_argument('--dry-run', action='store_true')
    parser.add_argument('--rebuild', action='store_true')
    parser.add_argument('--no-prebuild', action='store_true')
    return parser


def read_config(path):
    config = json.loads(Path(path).read_text())
    if not config['shapes'] or any(len(s) != 3 or any(not isinstance(n, int) or n <= 0 for n in s) for s in config['shapes']):
        raise ValueError('shapes must be positive M/N/K triples')
    if not config['hardware'] or not config['seeds'] or not config['delay_means']:
        raise ValueError('hardware, seeds and delay_means must be nonempty')
    if any(not isinstance(n, int) or n < 1 or n > (2**32-1)//16 for n in config['delay_means']):
        raise ValueError('invalid delay means')
    if any(not isinstance(n, int) or n < 0 or n >= 2**64 for n in config['seeds']):
        raise ValueError('seeds must be uint64 values')
    known_lanes = {entry['lane'] for entry in config['hardware']}
    known_shapes = {tuple(shape) for shape in config['shapes']}
    for study in ('latency', 'capacity'):
        lanes = config[study+'_lanes']
        shapes = config[study+'_shapes']
        if not lanes or any(type(lane) is not int or lane not in known_lanes for lane in lanes):
            raise ValueError(f'{study}_lanes must select configured hardware lanes')
        if not shapes or any(not isinstance(shape, list) or len(shape) != 3 or
                             any(type(n) is not int or n <= 0 for n in shape) or
                             tuple(shape) not in known_shapes for shape in shapes):
            raise ValueError(f'{study}_shapes must select configured M/N/K triples')
    mean, seed = config['capacity_stress_mean'], config['capacity_stress_seed']
    if type(mean) is not int or not 1 <= mean <= (2**32-1)//16:
        raise ValueError('invalid capacity stress mean')
    if type(seed) is not int or not 0 <= seed < 2**64:
        raise ValueError('capacity stress seed must be a uint64 value')
    if config['build_jobs'] < 1 or config['timeout_seconds'] < 1:
        raise ValueError('build jobs and timeout must be positive')
    return config


def base_hardware(entry, mode, config):
    return Hardware(mode=mode, **entry, a_logic=entry['a']//2, b_logic=entry['b']//2,
                    acc_logic=entry['acc']//2, subtile_k=config['subtile_k'],
                    load_data_width=config['load_data_width'])


def changed(hw, **values):
    if hw.mode == 'static':
        for physical, logical in (('a', 'a_logic'), ('b', 'b_logic'), ('acc', 'acc_logic')):
            if physical in values:
                values[logical] = values[physical]//2
    return replace(hw, **values)


def scaled(value, ratio):
    numerator, denominator = ratio
    if numerator <= 0 or denominator <= 0 or (value*numerator) % denominator:
        raise ValueError(f'capacity ratio {ratio} does not produce an integer from {value}')
    return value*numerator//denominator


def capacity_hardware(base, config):
    yield base
    for field in ('a', 'b', 'acc'):
        for ratio in config['physical_ratios']:
            yield changed(base, **{field: scaled(getattr(base, field), ratio)})
    if base.mode != 'static':
        for field in ('a', 'b', 'acc'):
            for ratio in config['logical_ratios']:
                yield changed(base, **{field+'_logic': scaled(getattr(base, field), ratio)})
    for resource in ('ab', 'acc'):
        fields = ('a', 'b') if resource == 'ab' else ('acc',)
        for physical_ratio in config['cross_physical_ratios']:
            if base.mode == 'static':
                yield changed(base, **{f: scaled(getattr(base, f), physical_ratio) for f in fields})
                continue
            for logical_ratio in config['cross_logical_ratios']:
                values = {f: scaled(getattr(base, f), physical_ratio) for f in fields}
                values.update({f+'_logic': scaled(getattr(base, f), logical_ratio) for f in fields})
                if all(values[f+'_logic'] < values[f] for f in fields):
                    yield changed(base, **values)


def capacity_stress_hardware(base, config):
    """Retest only individual resource-pressure points under long-tail delay."""
    for field in ('a', 'b', 'acc'):
        yield changed(base, **{field: scaled(getattr(base, field), config['capacity_stress_physical_ratio'])})
    if base.mode != 'static':
        for field in ('a', 'b', 'acc'):
            yield changed(base, **{field+'_logic': scaled(getattr(base, field), config['capacity_stress_logical_ratio'])})


def build_all_tasks(args):
    if args.count <= 0:
        raise ValueError('count must be positive')
    config = read_config(args.ablation_config)
    selected = set(args.ablation_studies.replace(',', ' ').split())
    if not selected or selected - {'latency', 'idle', 'capacity'}:
        raise ValueError('ablation studies must select latency, idle and/or capacity')
    tasks = {}
    root = args.data_root.resolve()/args.ablation_profile

    def add(hw, shape, distribution='fixed', mean=4, seed=1, studies=('capacity',)):
        task = Task(hw, *shape, args.count, distribution, mean, seed, tuple(studies), root, root, root,
                    args.ablation_trace, 120 if args.ablation_profile == 'smoke' else config['timeout_seconds'])
        key = digest(task.spec)
        folder = root/hw.mode/hw.tag/key
        task = replace(task, out_dir=folder, out_file=folder/'result.json', log_file=folder/'run.log')
        if key in tasks:
            task = replace(task, studies=tuple(sorted(set(tasks[key].studies) | set(task.studies))))
        tasks[key] = task

    if args.ablation_profile == 'smoke':
        # At most forty small simulations, including three production L4/W32
        # runs. Counts >2 are rejected to prevent accidentally large local runs.
        if args.count > 2:
            raise ValueError('smoke profile requires --count 1 or --count 2')
        tiny_config = dict(config, subtile_k=8)
        entry = dict(lane=1, width=8, a=8, b=8, acc=8, store_rows=1, slot_acc_count=1)
        for mode in MODES:
            hw = replace(base_hardware(entry, mode, tiny_config), optimization='-O0')
            for shape in ((1,8,8), (16,16,16), (17,9,9)):
                add(hw, shape, studies=('idle', 'latency'))
                add(hw, shape, 'longtail', 32, studies=('latency',))
            if mode != 'static':
                for field in ('a', 'b', 'acc'):
                    add(changed(hw, **{field: 6}), (16,16,16))
                    add(changed(hw, **{field+'_logic': 2}), (16,16,16))
                add(changed(hw, a=6, b=6, a_logic=5, b_logic=5), (16,16,16))
                add(changed(hw, acc=6, acc_logic=5), (16,16,16))
            else:
                for field in ('a', 'b', 'acc'):
                    add(changed(hw, **{field: 6}), (16,16,16))
            standard = dict(lane=4, width=32, a=16, b=16, acc=32, store_rows=2, slot_acc_count=2)
            add(replace(base_hardware(standard, mode, config), optimization='-O0'), (16,64,64), studies=('idle', 'latency'))
        assert len(tasks) <= 40
    else:
        for entry in config['hardware']:
            for mode in MODES:
                base = base_hardware(entry, mode, config)
                for shape in config['shapes']:
                    add(base, shape, studies=('idle', 'latency'))
                if base.lane in config['latency_lanes']:
                    for shape in config['latency_shapes']:
                        for mean in config['delay_means']:
                            for distribution in ('fixed', 'uniform', 'longtail'):
                                for seed in ([1] if distribution == 'fixed' else config['seeds']):
                                    add(base, shape, distribution, mean, seed, studies=('latency',))
                if base.lane in config['capacity_lanes']:
                    for hw in dict.fromkeys(capacity_hardware(base, config)):
                        for shape in config['capacity_shapes']:
                            add(hw, shape)
                    for hw in dict.fromkeys(capacity_stress_hardware(base, config)):
                        for shape in config['capacity_shapes']:
                            add(hw, shape, 'longtail', config['capacity_stress_mean'],
                                config['capacity_stress_seed'])
        if len(tasks) > MAX_FULL_TASKS:
            raise ValueError(f'full ablation matrix generates {len(tasks)} tasks; '
                             f'limit is {MAX_FULL_TASKS}. Reduce the configured study ranges.')
    return [task for task in tasks.values() if selected.intersection(task.studies)]


def task_label(task):
    return (f'{task.axis} {task.hw.mode} {task.hw.tag} MNK={task.m}x{task.n}x{task.k} '
            f'Count={task.count} delay={task.distribution}:{task.mean} seed={task.seed}')


def command_for_task(task):
    return [sys.executable, str(HERE/'run_case.py'), '--spec', canonical(task.spec),
            '--out-dir', str(task.out_dir), '--studies', ','.join(task.studies),
            '--timeout', str(task.timeout)]


def make_env(args, hw=None):
    # Do not inherit the legacy scripts' FORCE/REBUILD/LOAD_RSP_DELAY overrides:
    # all experimental hardware and memory parameters are explicit in the spec.
    return os.environ.copy()


def task_complete(task):
    return complete(task.out_file, task.spec)


def prebuild_hardware(args, tasks, print_lock):
    if args.dry_run or args.no_prebuild:
        return True
    config = read_config(args.ablation_config)
    needed = [task for task in tasks if args.force or not task_complete(task)]
    for hw in dict.fromkeys(task.hw for task in needed):
        with print_lock:
            print(f'ablation: prebuild {hw.mode} {hw.tag} log={build_dir(hw) / "build.log"}', flush=True)
        build(hw, getattr(args, 'build_jobs', config['build_jobs']), args.rebuild)
    return True


def main():
    # Delegate scheduling to the exact full.py worker pool rather than adding
    # a second, subtly different execution/resume implementation.
    from lab import full
    cli = [arg.replace("--data-root", "--ablation-data-root", 1) if arg.startswith("--data-root") else arg for arg in sys.argv[1:]]
    sys.argv = [str(HERE.parent/'full.py'), '--experiments', 'ablation', *cli]
    return full.main()


if __name__ == '__main__':
    raise SystemExit(main())
