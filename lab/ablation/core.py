"""Canonical hardware/run identity and isolated Verilator builds."""
from __future__ import annotations

import fcntl
import hashlib
import inspect
import json
import os
import subprocess
from dataclasses import asdict, dataclass
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
HERE = Path(__file__).resolve().parent
SCHEMA_VERSION = 1
REASONS = ('wait_a', 'wait_b', 'wait_ab', 'gemm_head_of_line', 'a_physical_full',
           'b_physical_full', 'acc_physical_full', 'acc_reuse_gap', 'issue_port',
           'operand_delivery', 'static_wave', 'output_reclaim', 'control',
           'pipeline_fill', 'pipeline_drain')
MODES = ('static', 'dynamic', 'dynamic_inorder')


def canonical(value) -> str:
    return json.dumps(value, sort_keys=True, separators=(',', ':'), allow_nan=False)


def digest(value) -> str:
    return hashlib.sha256(canonical(value).encode()).hexdigest()[:20]


@dataclass(frozen=True)
class Hardware:
    mode: str
    lane: int
    width: int
    a: int
    b: int
    acc: int
    a_logic: int
    b_logic: int
    acc_logic: int
    store_rows: int
    slot_acc_count: int
    subtile_k: int = 32
    load_data_width: int = 1024
    optimization: str = "-O2"

    def __post_init__(self):
        if self.optimization not in ('-O0','-O1','-O2','-O3','-Os'):
            raise ValueError('unsupported C++ optimization level')
        if self.mode not in MODES:
            raise ValueError(f'unknown mode: {self.mode}')
        if any(v <= 0 for k, v in asdict(self).items() if k not in ('mode', 'optimization')):
            raise ValueError('hardware sizes must be positive')
        for n in (self.width, self.subtile_k, self.load_data_width, self.slot_acc_count):
            if n & (n-1):
                raise ValueError('width, subtile K, bus width and slot grouping must be powers of two')
        if self.width < 8 or self.width % self.store_rows:
            raise ValueError('width must be >=8 and divisible by store_rows')
        if min(self.a, self.b) < 4:
            raise ValueError('operand buffers must have at least four entries')
        if self.mode == 'static':
            if any(n % 2 for n in (self.a, self.b, self.acc)):
                raise ValueError('static physical capacities must have even ping-pong halves')
            if (self.a_logic, self.b_logic, self.acc_logic) != (self.a//2, self.b//2, self.acc//2):
                raise ValueError('static logical capacity is determined by ping-pong halves')
        elif any(l >= p for l, p in ((self.a_logic, self.a), (self.b_logic, self.b), (self.acc_logic, self.acc))):
            raise ValueError('dynamic ablation requires logical capacity below physical capacity')
        row_bits = self.subtile_k*8
        if max(row_bits, self.load_data_width) % min(row_bits, self.load_data_width):
            raise ValueError('operand row and bus width must divide one another')

    @property
    def top(self):
        return 'static' if self.mode == 'static' else 'dynamic'

    @property
    def tag(self):
        return (f'L{self.lane}_W{self.width}_A{self.a_logic}-{self.a}'
                f'_B{self.b_logic}-{self.b}_ACC{self.acc_logic}-{self.acc}_{digest(asdict(self))}')


def source_paths(hw: Hardware) -> list[Path]:
    names = ['sche/uop.sv', 'sche/blocksel.sv']
    names += (['sche/new_static_uopparse.sv'] if hw.top == 'static' else
              ['sche/dynamic_uopparse.sv', 'sche/dynamic_rename.sv', 'sche/dynamic_sche.sv'])
    names += ['buf/oprandbuf.sv', 'sram/sram1r1w.sv', 'pe/fdot8e4m3.sv',
              'pe/paccreg.sv', 'sram/sram2r1w.sv', 'pe/pe.sv', 'sa/lanebuf.sv',
              'sa/sa.sv', 'mem/loadunit.sv', 'mem/storeunit.sv', f'top_{hw.top}.sv']
    return [ROOT/'src'/n for n in names] + [HERE/'perf_monitor.sv', ROOT/f'lab/{hw.top}/{hw.top}.cpp']


def build_identity(hw: Hardware):
    # Include all instrumentation headers as dependencies, including files
    # referenced by `include rather than passed to Verilator on the command line.
    dependencies = source_paths(hw) + sorted(HERE.glob('*.svh')) + [HERE/'experiment.hpp']
    return {'hardware': asdict(hw), 'schema_version': SCHEMA_VERSION,
            'recipe': inspect.getsource(build_command) + inspect.getsource(source_paths),
            'sources': {str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest() for p in dependencies}}


def build_dir(hw: Hardware) -> Path:
    return Path(os.environ.get('ABLATION_BUILD_ROOT', '/tmp/ooogemm_ablation')) / digest(build_identity(hw))


def build_command(hw: Hardware, jobs: int = 4, lint: bool = False) -> list[str]:
    parameters = {'LANE_NUM': hw.lane, 'SA_WIDTH': hw.width, 'SUBTILE_K': hw.subtile_k,
                  'ABUF_SIZE': hw.a, 'BBUF_SIZE': hw.b, 'PACC_NUM': hw.acc,
                  'STORE_ROWS_PER_CYCLE': hw.store_rows, 'LOAD_DATA_WIDTH': hw.load_data_width}
    defines = {'LANE_NUM_TEST': hw.lane, 'SA_WIDTH_TEST': hw.width, 'SUBTILE_K_TEST': hw.subtile_k,
               'ABUF_SIZE_TEST': hw.a, 'BBUF_SIZE_TEST': hw.b, 'PACC_NUM_TEST': hw.acc,
               'STORE_ROWS_PER_CYCLE_TEST': hw.store_rows, 'LOAD_DATA_WIDTH_TEST': hw.load_data_width}
    if hw.top == 'dynamic':
        parameters.update(ABUF_LOGIC_SIZE=hw.a_logic, BBUF_LOGIC_SIZE=hw.b_logic,
                          PACC_LOGIC_SIZE=hw.acc_logic, SCHED_SLOT_ACC_COUNT=hw.slot_acc_count,
                          GEMM_IN_ORDER="1'b1" if hw.mode == 'dynamic_inorder' else "1'b0")
        defines.update(ABUF_LOGIC_SIZE_TEST=hw.a_logic, BBUF_LOGIC_SIZE_TEST=hw.b_logic,
                       PACC_LOGIC_SIZE_TEST=hw.acc_logic)
    command = ['verilator', '--assert', '--top-module', f'top_{hw.top}',
               '+define+OOOGEMM_ABLATION', f'-I{HERE}', '--Mdir', str(build_dir(hw))]
    command += ['--lint-only'] if lint else ['--cc', '--exe', '--build', '--build-jobs', str(jobs),
                                           '--output-split', '20000', '--output-split-cfuncs', '20000', '--output-groups', '16']
    command += [f'-G{k}={v}' for k, v in parameters.items()]
    if not lint:
        command += ['-MAKEFLAGS', f'OPT_FAST={hw.optimization} OPT_SLOW=-O0',
                    '-CFLAGS', f'-g0 -DOOOGEMM_ABLATION -I{HERE} ' +
                    ' '.join(f'-D{k}={v}' for k, v in defines.items())]
    command += [str(p) for p in source_paths(hw) if not lint or p.suffix != '.cpp']
    return command


def build(hw: Hardware, jobs: int = 4, force: bool = False) -> Path:
    directory = build_dir(hw)
    directory.mkdir(parents=True, exist_ok=True)
    exe = directory/f'Vtop_{hw.top}'
    # On-demand builds are serialized even with --no-prebuild and several runs
    # sharing hardware. A failed build never leaves a reusable completion stamp.
    with (directory/'build.lock').open('w') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        stamp = directory/'complete.json'
        if force or not exe.exists() or not stamp.exists():
            stamp.unlink(missing_ok=True)
            with (directory/'build.log').open('w') as log:
                rc = subprocess.run(build_command(hw, jobs), stdout=log, stderr=subprocess.STDOUT).returncode
            if rc:
                raise RuntimeError(f'Verilator build failed ({rc}): {directory / "build.log"}')
            stamp.write_text(canonical(build_identity(hw))+'\n')
    return exe


def validate_stats(stats: dict, spec: dict) -> None:
    hw = Hardware(**spec['hardware'])
    m, n, k = spec['mnk']
    count = spec['count']
    cycles = stats['cycles']
    if not isinstance(cycles, int) or cycles <= 0:
        raise ValueError('invalid cycle count')
    for prefix, capacity in (('lane', hw.lane), ('mac', hw.lane*hw.width**2)):
        idle = stats[f'{prefix}_idle']
        if set(idle) != set(REASONS) or any(not isinstance(v, int) or v < 0 for v in idle.values()):
            raise ValueError('invalid reason counters')
        if stats[f'{prefix}_active'] + sum(idle.values()) != cycles*capacity:
            raise ValueError(f'{prefix} counters do not conserve cycles')
        for phase in stats['phases'].values():
            if phase[f'{prefix}_active'] + sum(phase[f'{prefix}_idle'].values()) != phase['cycles']*capacity:
                raise ValueError('phase counters do not conserve cycles')
        if sum(p[f'{prefix}_active'] for p in stats['phases'].values()) != stats[f'{prefix}_active']:
            raise ValueError('phase activity does not sum to the measurement window')
        if any(sum(p[f'{prefix}_idle'][r] for p in stats['phases'].values()) != idle[r] for r in REASONS):
            raise ValueError('phase reasons do not sum to the measurement window')
    if sum(p['cycles'] for p in stats['phases'].values()) != cycles:
        raise ValueError('phase durations do not conserve cycles')
    expected_lane = ((m+hw.width-1)//hw.width)*((n+hw.width-1)//hw.width)*((k+hw.subtile_k-1)//hw.subtile_k)*hw.subtile_k*count
    if stats['lane_active'] != expected_lane or stats['mac_active'] != expected_lane*hw.width**2:
        raise ValueError('missing or duplicate compute work')
    expected_stores = ((m+hw.width-1)//hw.width)*((n+hw.width-1)//hw.width)*(hw.width//hw.store_rows)*count
    if stats['store_beats'] != expected_stores or stats['requests'] != stats['responses']:
        raise ValueError('incomplete memory transactions')
    import math
    if any(not math.isfinite(stats[key]) or stats[key] < 0 for key in ('throughput', 'latency', 'input_bus_util', 'output_bus_util')):
        raise ValueError('invalid metrics')

