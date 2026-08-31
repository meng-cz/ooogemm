#!/usr/bin/env python3
import argparse
import os
import queue
import subprocess
import sys
import threading
import time
from dataclasses import dataclass
from pathlib import Path


SCRIPT_DIR = Path(__file__).resolve().parent
ROOT_DIR = SCRIPT_DIR.parent.parent

# Self-contained experiment defaults.  Command-line options and environment
# variables remain available for server-specific overrides, but a checkout can
# run the complete default sweep without any external configuration.
DEFAULT_JOBS = 12
DEFAULT_COUNT = 100
DEFAULT_M_DEFAULT = 16
DEFAULT_N_DEFAULT = 1024
DEFAULT_K_DEFAULT = 1024
DEFAULT_M_VALUES = "1 4 16 32 64 128 256 512"
DEFAULT_N_VALUES = "32 64 128 256 512"
DEFAULT_K_VALUES = "32 64 128 256 512"
DEFAULT_HARDWARE_CONFIGS = (
    "1:128:24:32:96:128:1 "
    "4:64:24:32:96:128:2 "
    "16:32:24:32:96:128:4"
)
DEFAULT_DATA_ROOT = ROOT_DIR / "data/rect_dynamic"
DEFAULT_LOG_DIR = DEFAULT_DATA_ROOT / "log"


@dataclass(frozen=True)
class Hardware:
    lane: int
    width: int
    abuf_logic_size: int
    abuf_size: int
    pacc_logic_size: int
    bbuf_size: int
    pacc_num: int
    store_rows_per_cycle: int


@dataclass(frozen=True)
class Task:
    axis: str
    hw: Hardware
    m: int
    n: int
    k: int
    count: int
    out_dir: Path
    out_file: Path
    log_file: Path


@dataclass
class Progress:
    total: int
    started: int = 0
    completed: int = 0
    running: int = 0
    failed: int = 0


def env_flag(name: str, default: bool = False) -> bool:
    value = os.environ.get(name)
    if value is None:
        return default
    return value not in ("0", "false", "False", "no", "No", "")


def parse_int_list(value: str, default: list[int]) -> list[int]:
    if value is None or value.strip() == "":
        return default
    parts = value.replace(",", " ").split()
    return [int(part) for part in parts]


def parse_hardware_configs(value: str, default: list[Hardware]) -> list[Hardware]:
    if value is None or value.strip() == "":
        return default
    configs: list[Hardware] = []

    def default_store_rows(width: int) -> int:
        return {64: 1, 32: 2, 16: 4}.get(width, 1)

    for part in value.replace(",", " ").split():
        fields = part.split(":")
        if len(fields) == 2:
            lane, width = fields
            lane_i = int(lane)
            width_i = int(width)
            defaults = {
                1: (6, 8, 6, 8),
                4: (12, 16, 24, 32),
                16: (24, 32, 96, 128),
            }
            abuf_logic, abuf_size, pacc_logic, pacc_num = defaults.get(lane_i, (8, 16, 8, 16))
            configs.append(Hardware(
                lane_i, width_i, abuf_logic, abuf_size, pacc_logic, abuf_size, pacc_num,
                default_store_rows(width_i),
            ))
        elif len(fields) == 5:
            lane, width, abuf_logic, abuf_size, pacc_logic = fields
            width_i = int(width)
            configs.append(Hardware(
                int(lane), width_i, int(abuf_logic), int(abuf_size),
                int(pacc_logic), int(abuf_size), int(abuf_size),
                default_store_rows(width_i),
            ))
        elif len(fields) == 6:
            lane, width, abuf_logic, abuf_size, pacc_logic, pacc_num = fields
            configs.append(Hardware(
                int(lane), int(width), int(abuf_logic), int(abuf_size),
                int(pacc_logic), int(abuf_size), int(pacc_num),
                default_store_rows(int(width)),
            ))
        elif len(fields) == 7:
            lane, width, abuf_logic, abuf_size, pacc_logic, pacc_num, store_rows = fields
            configs.append(Hardware(
                int(lane), int(width), int(abuf_logic), int(abuf_size),
                int(pacc_logic), int(abuf_size), int(pacc_num), int(store_rows),
            ))
        else:
            raise ValueError(
                "hardware config must be lane:width, lane:width:abuf_logic:abuf_phys:"
                "pacc_logic:pacc_phys[:store_rows]"
            )
    for config in configs:
        if config.abuf_logic_size <= 0 or config.abuf_logic_size > config.abuf_size:
            raise ValueError("ABuf logical size must be in 1..ABuf physical size")
        if config.pacc_logic_size <= 0 or config.pacc_logic_size > config.pacc_num:
            raise ValueError("PACC logical size must be in 1..PACC physical size")
        if config.store_rows_per_cycle <= 0:
            raise ValueError("store_rows must be positive")
        if config.width % config.store_rows_per_cycle != 0:
            raise ValueError("hardware width must be divisible by store_rows")
    return configs


def hardware_tag(hw: Hardware) -> str:
    tag = f"L{hw.lane}_W{hw.width}_AB{hw.abuf_logic_size}_{hw.abuf_size}"
    if hw.bbuf_size != hw.abuf_size:
        tag += f"_BB{hw.bbuf_size}"
    return f"{tag}_ACC{hw.pacc_logic_size}_{hw.pacc_num}"


def result_filename(hw: Hardware, m: int, n: int, k: int, count: int) -> str:
    return f"{hardware_tag(hw)}_{m}X{n}X{k}_Cnt{count}.txt"


def log_filename(axis: str, hw: Hardware, m: int, n: int, k: int, count: int) -> str:
    return f"{axis}_{hardware_tag(hw)}_{m}X{n}X{k}_Cnt{count}.log"


def task_label(task: Task) -> str:
    return (
        f"{task.axis} {hardware_tag(task.hw)} "
        f"MNK={task.m}x{task.n}x{task.k} "
        f"STORE_ROWS_PER_CYCLE={task.hw.store_rows_per_cycle}"
    )


def progress_fields(progress: Progress) -> str:
    pending = progress.total - progress.started
    return (
        f"started={progress.started}/{progress.total} "
        f"completed={progress.completed}/{progress.total} "
        f"running={progress.running} pending={pending} failed={progress.failed}"
    )


def make_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Run dynamic GEMM axis-sweep experiments with a Python worker pool."
    )
    parser.add_argument("--jobs", type=int, default=int(os.environ.get("JOBS", str(DEFAULT_JOBS))))
    parser.add_argument("--count", type=int, default=int(os.environ.get("COUNT", str(DEFAULT_COUNT))))
    parser.add_argument("--m-default", type=int, default=int(os.environ.get("M_DEFAULT", str(DEFAULT_M_DEFAULT))))
    parser.add_argument("--n-default", type=int, default=int(os.environ.get("N_DEFAULT", str(DEFAULT_N_DEFAULT))))
    parser.add_argument("--k-default", type=int, default=int(os.environ.get("K_DEFAULT", str(DEFAULT_K_DEFAULT))))
    parser.add_argument("--m-values", default=os.environ.get("M_VALUES", DEFAULT_M_VALUES))
    parser.add_argument("--n-values", default=os.environ.get("N_VALUES", DEFAULT_N_VALUES))
    parser.add_argument("--k-values", default=os.environ.get("K_VALUES", DEFAULT_K_VALUES))
    parser.add_argument(
        "--hardware-configs",
        default=os.environ.get(
            "HARDWARE_CONFIGS",
            # lane:width:ABufLogical:ABufPhysical:PACCLogical:PACCPhysical:store_rows
            DEFAULT_HARDWARE_CONFIGS,
        ),
    )
    parser.add_argument("--data-root", type=Path, default=Path(os.environ.get("DATA_ROOT", DEFAULT_DATA_ROOT)))
    parser.add_argument("--log-dir", type=Path, default=Path(os.environ.get("LOG_DIR", DEFAULT_LOG_DIR)))
    parser.add_argument("--force", action="store_true", default=env_flag("FORCE", False))
    parser.add_argument("--dry-run", action="store_true", default=env_flag("DRY_RUN", False))
    parser.add_argument("--rebuild", action="store_true", default=env_flag("REBUILD", False))
    parser.add_argument("--no-prebuild", action="store_true", default=env_flag("NO_PREBUILD", False))
    return parser


def build_all_tasks(args: argparse.Namespace) -> list[Task]:
    m_values = parse_int_list(args.m_values, [int(v) for v in DEFAULT_M_VALUES.split()])
    n_values = parse_int_list(args.n_values, [int(v) for v in DEFAULT_N_VALUES.split()])
    k_values = parse_int_list(args.k_values, [int(v) for v in DEFAULT_K_VALUES.split()])
    hardware = parse_hardware_configs(
        args.hardware_configs,
        [
            Hardware(1, 128, 24, 32, 96, 32, 128, 1),
            Hardware(4, 64, 24, 32, 96, 32, 128, 2),
            Hardware(16, 32, 24, 32, 96, 32, 128, 4),
        ],
    )

    data_root = args.data_root.resolve()
    log_dir = args.log_dir.resolve()
    lab_dirs = {
        "labM": data_root / "labM",
        "labN": data_root / "labN",
        "labK": data_root / "labK",
    }

    tasks: list[Task] = []

    def add(axis: str, hw: Hardware, m: int, n: int, k: int) -> None:
        out_dir = lab_dirs[axis]
        out_file = out_dir / result_filename(hw, m, n, k, args.count)
        log_file = log_dir / log_filename(axis, hw, m, n, k, args.count)
        tasks.append(Task(axis, hw, m, n, k, args.count, out_dir, out_file, log_file))

    # Point-major order keeps the three hardware configurations interleaved.
    for m in m_values:
        for hw in hardware:
            add("labM", hw, m, args.n_default, args.k_default)

    for n in n_values:
        for hw in hardware:
            add("labN", hw, args.m_default, n, args.k_default)

    for k in k_values:
        for hw in hardware:
            add("labK", hw, args.m_default, args.n_default, k)

    return tasks


def command_for_task(task: Task) -> list[str]:
    return [
        str(SCRIPT_DIR / "dynamic.sh"),
        str(task.hw.lane),
        str(task.hw.width),
        str(task.m),
        str(task.n),
        str(task.k),
        str(task.count),
        str(task.out_dir),
    ]


def hardware_env(hw: Hardware) -> dict[str, str]:
    return {
        "ABUF_LOGIC_SIZE": str(hw.abuf_logic_size),
        "ABUF_SIZE": str(hw.abuf_size),
        "BBUF_SIZE": str(hw.bbuf_size),
        "BBUF_LOGIC_SIZE": str(hw.abuf_logic_size),
        "PACC_LOGIC_SIZE": str(hw.pacc_logic_size),
        "PACC_NUM": str(hw.pacc_num),
        "STORE_ROWS_PER_CYCLE": str(hw.store_rows_per_cycle),
    }


def make_env(args: argparse.Namespace, hw: Hardware | None = None) -> dict[str, str]:
    env = os.environ.copy()
    if args.rebuild:
        env["REBUILD"] = "1"
    if hw is not None:
        env.update(hardware_env(hw))
    return env


def prebuild_hardware(args: argparse.Namespace, tasks: list[Task], print_lock: threading.Lock) -> bool:
    if args.dry_run or args.no_prebuild or args.jobs <= 1 or not tasks:
        return True

    prebuild_dir = (args.data_root.resolve() / "prebuild")
    args.log_dir.mkdir(parents=True, exist_ok=True)
    prebuild_dir.mkdir(parents=True, exist_ok=True)

    hardware = sorted(
        {task.hw for task in tasks},
        key=lambda hw: (hw.lane, hw.width, hw.abuf_size, hw.bbuf_size, hw.pacc_num),
    )
    for hw in hardware:
        env = make_env(args, hw)
        env["BUILD_ONLY"] = "1"
        log_file = args.log_dir.resolve() / f"prebuild_{hardware_tag(hw)}.log"
        cmd = [
            str(SCRIPT_DIR / "dynamic.sh"),
            str(hw.lane),
            str(hw.width),
            "1",
            "1",
            str(tasks[0].k),
            "1",
            str(prebuild_dir),
        ]
        with print_lock:
            print(
                f"dynamic_lab: prebuild {hardware_tag(hw)} "
                f"log={log_file}",
                flush=True,
            )
        with log_file.open("w") as log:
            log.write(f"cmd={' '.join(cmd)}\n")
            log.write(
                f"hardware=ABUF_LOGIC_SIZE={hw.abuf_logic_size} "
                f"ABUF_SIZE={hw.abuf_size} "
                f"PACC_LOGIC_SIZE={hw.pacc_logic_size} PACC_NUM={hw.pacc_num}\n"
            )
            log.write(f"started={time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())}\n")
            log.flush()
            rc = subprocess.run(cmd, stdout=log, stderr=subprocess.STDOUT, env=env).returncode
            log.write(f"finished={time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())} rc={rc}\n")
        if rc != 0:
            with print_lock:
                print(
                    f"dynamic_lab: prebuild failed {hardware_tag(hw)} "
                    f"rc={rc} log={log_file}",
                    flush=True,
                )
            return False
    return True


def run_task(
    task: Task,
    index: int,
    total: int,
    args: argparse.Namespace,
    print_lock: threading.Lock,
    progress: Progress,
    progress_lock: threading.Lock,
    active_children: set[subprocess.Popen],
    child_lock: threading.Lock,
) -> int:
    cmd = command_for_task(task)
    env = make_env(args, task.hw)
    task.out_dir.mkdir(parents=True, exist_ok=True)
    task.log_file.parent.mkdir(parents=True, exist_ok=True)

    with progress_lock:
        progress.started += 1
        progress.running += 1
        fields = progress_fields(progress)
    with print_lock:
        print(
            f"dynamic_lab: task_start order={index}/{total} {fields} "
            f"{task_label(task)} log={task.log_file}",
            flush=True,
        )

    start = time.monotonic()
    with task.log_file.open("w") as log:
        log.write(f"cmd={' '.join(cmd)}\n")
        log.write(
            f"hardware=ABUF_LOGIC_SIZE={task.hw.abuf_logic_size} "
            f"ABUF_SIZE={task.hw.abuf_size} "
            f"PACC_LOGIC_SIZE={task.hw.pacc_logic_size} PACC_NUM={task.hw.pacc_num}\n"
        )
        log.write(f"output={task.out_file}\n")
        log.write(f"started={time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())}\n")
        log.flush()
        proc = subprocess.Popen(cmd, stdout=log, stderr=subprocess.STDOUT, env=env)
        with child_lock:
            active_children.add(proc)
        try:
            rc = proc.wait()
        finally:
            with child_lock:
                active_children.discard(proc)
        elapsed = time.monotonic() - start
        log.write(f"finished={time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())} rc={rc} elapsed_sec={elapsed:.3f}\n")

    with progress_lock:
        progress.running -= 1
        progress.completed += 1
        if rc != 0:
            progress.failed += 1
        fields = progress_fields(progress)
    with print_lock:
        status = "done" if rc == 0 else "failed"
        print(
            f"dynamic_lab: task_{status} order={index}/{total} {fields} "
            f"{task_label(task)} "
            f"rc={rc} elapsed_sec={elapsed:.1f}",
            flush=True,
        )
    return rc


def main() -> int:
    args = make_parser().parse_args()
    if args.jobs <= 0:
        print("dynamic_lab: --jobs must be positive", file=sys.stderr)
        return 2

    all_tasks = build_all_tasks(args)
    for task in all_tasks:
        task.out_dir.mkdir(parents=True, exist_ok=True)
    args.log_dir.mkdir(parents=True, exist_ok=True)

    pending = [task for task in all_tasks if args.force or not task.out_file.exists()]
    skipped = len(all_tasks) - len(pending)

    print(
        f"dynamic_lab: generated={len(all_tasks)} pending={len(pending)} "
        f"skipped_existing={skipped} jobs={args.jobs}",
        flush=True,
    )

    if args.dry_run:
        for task in pending:
            print(f"{task_label(task)}", flush=True)
            print(
                " ".join(command_for_task(task)) + f" > {task.log_file} 2>&1",
                flush=True,
            )
        return 0

    print_lock = threading.Lock()
    if not prebuild_hardware(args, pending, print_lock):
        return 1

    work_queue: queue.Queue[tuple[int, Task]] = queue.Queue()
    for index, task in enumerate(pending, start=1):
        work_queue.put((index, task))

    failures: list[tuple[Task, int]] = []
    failure_lock = threading.Lock()
    stop_event = threading.Event()
    progress = Progress(total=len(pending))
    progress_lock = threading.Lock()
    active_children: set[subprocess.Popen] = set()
    child_lock = threading.Lock()

    def worker() -> None:
        while not stop_event.is_set():
            try:
                index, task = work_queue.get_nowait()
            except queue.Empty:
                return
            try:
                if stop_event.is_set():
                    return
                rc = run_task(
                    task,
                    index,
                    len(pending),
                    args,
                    print_lock,
                    progress,
                    progress_lock,
                    active_children,
                    child_lock,
                )
                if rc != 0:
                    with failure_lock:
                        failures.append((task, rc))
            finally:
                work_queue.task_done()

    threads = []
    worker_count = min(args.jobs, len(pending))
    for i in range(worker_count):
        thread = threading.Thread(target=worker, name=f"dynamic-lab-worker-{i}", daemon=False)
        thread.start()
        threads.append(thread)

    try:
        for thread in threads:
            thread.join()
    except KeyboardInterrupt:
        stop_event.set()
        with child_lock:
            children = list(active_children)
        print(f"dynamic_lab: interrupted; terminating {len(children)} child processes", file=sys.stderr)
        for proc in children:
            proc.terminate()
        deadline = time.monotonic() + 5.0
        while time.monotonic() < deadline and any(proc.poll() is None for proc in children):
            time.sleep(0.1)
        for proc in children:
            if proc.poll() is None:
                proc.kill()
        for thread in threads:
            thread.join(timeout=1.0)
        return 130

    if failures:
        print(f"dynamic_lab: failures={len(failures)}", file=sys.stderr)
        for task, rc in failures:
            print(f"  rc={rc} log={task.log_file} output={task.out_file}", file=sys.stderr)
        return 1

    print("dynamic_lab: all pending tasks completed", flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
