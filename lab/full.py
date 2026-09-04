#!/usr/bin/env python3
"""Build and run all lab experiment sweeps from one process.

The individual lab runners remain the source of truth for hardware defaults,
task generation, executable names, build directories, and result/log paths.
This wrapper only combines their build and run phases.
"""

from __future__ import annotations

import argparse
import importlib.util
import os
import shlex
import subprocess
import sys
import threading
import time
from concurrent.futures import ThreadPoolExecutor, as_completed
from dataclasses import dataclass
from pathlib import Path
from types import ModuleType
from typing import Any


LAB_DIR = Path(__file__).resolve().parent


@dataclass(frozen=True)
class Experiment:
    name: str
    runner_path: Path


@dataclass(frozen=True)
class WorkItem:
    experiment: Experiment
    module: ModuleType
    task: Any


EXPERIMENTS = (
    Experiment("static", LAB_DIR / "static/run_axis_sweeps.py"),
    Experiment("dynamic", LAB_DIR / "dynamic/run_axis_sweeps.py"),
    Experiment("rect_static", LAB_DIR / "rect_static/run_axis_sweeps.py"),
    Experiment("rect_dynamic", LAB_DIR / "rect_dynamic/run_axis_sweeps.py"),
    Experiment("static_staticmn", LAB_DIR / "static_staticmn/run_axis_sweeps.py"),
)


def env_flag(name: str, default: bool = False) -> bool:
    value = os.environ.get(name)
    if value is None:
        return default
    return value not in ("0", "false", "False", "no", "No", "")


def load_runner(experiment: Experiment) -> ModuleType:
    """Load a runner under a unique module name.

    Every experiment uses the same filename, so importing by a normal module
    name would incorrectly reuse the first module from sys.modules.
    """

    module_name = f"ooogemm_lab_runner_{experiment.name}"
    loader_spec = importlib.util.spec_from_file_location(
        module_name, experiment.runner_path
    )
    if loader_spec is None or loader_spec.loader is None:
        raise RuntimeError(f"cannot load runner: {experiment.runner_path}")
    module = importlib.util.module_from_spec(loader_spec)
    sys.modules[module_name] = module
    loader_spec.loader.exec_module(module)
    return module


def make_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description=(
            "Build and run all static, dynamic, rectangular, and static-MN "
            "GEMM experiment sweeps."
        )
    )
    parser.add_argument(
        "--jobs",
        type=int,
        default=int(os.environ.get("JOBS", "12")),
        help="maximum number of simulation subprocesses running in parallel",
    )
    parser.add_argument(
        "--count",
        type=int,
        default=int(os.environ.get("COUNT", "100")),
        help="GEMM command count passed to every experiment",
    )
    parser.add_argument(
        "--m-default",
        type=int,
        default=int(os.environ.get("M_DEFAULT", "16")),
    )
    parser.add_argument(
        "--n-default",
        type=int,
        default=int(os.environ.get("N_DEFAULT", "1024")),
    )
    parser.add_argument(
        "--k-default",
        type=int,
        default=int(os.environ.get("K_DEFAULT", "1024")),
    )
    parser.add_argument(
        "--m-values",
        default=os.environ.get("M_VALUES", "1 4 16 32 64 128 256 512"),
        help="space- or comma-separated M sweep values",
    )
    parser.add_argument(
        "--n-values",
        default=os.environ.get("N_VALUES", "32 64 128 256 512"),
        help="space- or comma-separated N sweep values",
    )
    parser.add_argument(
        "--k-values",
        default=os.environ.get("K_VALUES", "32 64 128 256 512"),
        help="space- or comma-separated K sweep values",
    )
    parser.add_argument(
        "--force",
        action="store_true",
        default=env_flag("FORCE"),
        help="run tasks even when their result file already exists",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        default=env_flag("DRY_RUN"),
        help="list build/run work without compiling or running simulations",
    )
    parser.add_argument(
        "--rebuild",
        action="store_true",
        default=env_flag("REBUILD"),
        help="force every required Verilator executable to be rebuilt",
    )
    parser.add_argument(
        "--no-prebuild",
        action="store_true",
        default=env_flag("NO_PREBUILD"),
        help=(
            "skip the explicit build phase; each child runner may then build "
            "on demand"
        ),
    )
    return parser


def runner_args(module: ModuleType, args: argparse.Namespace) -> argparse.Namespace:
    """Start with each runner's own defaults, then apply common full.py args."""

    result = module.make_parser().parse_args([])
    for name in (
        "jobs",
        "count",
        "m_default",
        "n_default",
        "k_default",
        "m_values",
        "n_values",
        "k_values",
        "force",
        "dry_run",
        "rebuild",
        "no_prebuild",
    ):
        setattr(result, name, getattr(args, name))
    return result


def collect_work(
    args: argparse.Namespace,
) -> tuple[list[WorkItem], dict[str, list[Any]], dict[str, ModuleType]]:
    """Generate all tasks and retain runner instances for the build phase."""

    work: list[WorkItem] = []
    all_tasks: dict[str, list[Any]] = {}
    modules: dict[str, ModuleType] = {}
    for experiment in EXPERIMENTS:
        module = load_runner(experiment)
        exp_args = runner_args(module, args)
        tasks = module.build_all_tasks(exp_args)
        all_tasks[experiment.name] = tasks
        modules[experiment.name] = module
        work.extend(WorkItem(experiment, module, task) for task in tasks)
    return work, all_tasks, modules


def item_label(item: WorkItem) -> str:
    return item.module.task_label(item.task)


def item_command(item: WorkItem) -> list[str]:
    return item.module.command_for_task(item.task)


def item_env(item: WorkItem, args: argparse.Namespace) -> dict[str, str]:
    exp_args = runner_args(item.module, args)
    return item.module.make_env(exp_args, item.task.hw)


def prepare_result_dirs(work: list[WorkItem]) -> None:
    for item in work:
        item.task.out_dir.mkdir(parents=True, exist_ok=True)
        item.task.log_file.parent.mkdir(parents=True, exist_ok=True)


def print_dry_run(
    all_tasks: dict[str, list[Any]], pending: list[WorkItem], print_lock: threading.Lock
) -> None:
    with print_lock:
        print("full: dry-run; no build or simulation subprocess will be started", flush=True)
        for experiment in EXPERIMENTS:
            tasks = all_tasks[experiment.name]
            hardware = sorted(
                {task.hw for task in tasks},
                key=lambda hw: repr(hw),
            )
            print(
                f"full: {experiment.name} tasks={len(tasks)} "
                f"unique_hardware={len(hardware)} "
                f"runner={experiment.runner_path}",
                flush=True,
            )
        print(f"full: pending={len(pending)}", flush=True)
        for index, item in enumerate(pending, start=1):
            print(
                f"full: run_plan order={index}/{len(pending)} "
                f"{item.experiment.name} {item_label(item)} "
                f"log={item.task.log_file}",
                flush=True,
            )
            print(shlex.join(item_command(item)), flush=True)


def prebuild(
    args: argparse.Namespace,
    all_tasks: dict[str, list[Any]],
    modules: dict[str, ModuleType],
    print_lock: threading.Lock,
) -> bool:
    """Build all experiment executables before any simulation is submitted."""

    if args.no_prebuild:
        with print_lock:
            print("full: explicit prebuild disabled", flush=True)
        return True

    failed = False
    for experiment in EXPERIMENTS:
        module = modules[experiment.name]
        exp_args = runner_args(module, args)
        # The existing runners historically skipped their prebuild helper when
        # jobs <= 1.  full.py owns the phase ordering, so force that helper to
        # execute even when the simulation pool has only one worker.
        exp_args.jobs = max(2, args.jobs)
        exp_args.dry_run = False
        exp_args.no_prebuild = False
        tasks = all_tasks[experiment.name]
        if not tasks:
            continue
        with print_lock:
            print(
                f"full: build_start experiment={experiment.name} "
                f"tasks={len(tasks)}",
                flush=True,
            )
        started = time.monotonic()
        try:
            ok = module.prebuild_hardware(exp_args, tasks, print_lock)
        except Exception as exc:
            ok = False
            with print_lock:
                print(
                    f"full: build_exception experiment={experiment.name} "
                    f"error={exc!r}",
                    file=sys.stderr,
                    flush=True,
                )
        elapsed = time.monotonic() - started
        with print_lock:
            status = "done" if ok else "failed"
            print(
                f"full: build_{status} experiment={experiment.name} "
                f"elapsed_sec={elapsed:.1f}",
                flush=True,
            )
        if not ok:
            failed = True
    return not failed


def run_one(
    item: WorkItem,
    index: int,
    total: int,
    args: argparse.Namespace,
    print_lock: threading.Lock,
    state: dict[str, int],
    state_lock: threading.Lock,
    active: set[subprocess.Popen[Any]],
    active_lock: threading.Lock,
) -> tuple[WorkItem, int]:
    task = item.task
    command = item_command(item)
    env = item_env(item, args)
    task.out_dir.mkdir(parents=True, exist_ok=True)
    task.log_file.parent.mkdir(parents=True, exist_ok=True)

    with state_lock:
        state["started"] += 1
        state["running"] += 1
        fields = (
            f"started={state['started']}/{total} "
            f"completed={state['completed']}/{total} "
            f"running={state['running']} failed={state['failed']}"
        )
    with print_lock:
        print(
            f"full: task_start order={index}/{total} {fields} "
            f"experiment={item.experiment.name} {item_label(item)} "
            f"log={task.log_file}",
            flush=True,
        )

    started = time.monotonic()
    rc = 1
    with task.log_file.open("w") as log:
        log.write(f"cmd={shlex.join(command)}\n")
        log.write(f"experiment={item.experiment.name}\n")
        log.write(f"output={task.out_file}\n")
        log.write(
            f"started={time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())}\n"
        )
        log.flush()
        try:
            proc = subprocess.Popen(command, stdout=log, stderr=subprocess.STDOUT, env=env)
        except OSError as exc:
            log.write(f"spawn_error={exc!r}\n")
        else:
            with active_lock:
                active.add(proc)
            try:
                rc = proc.wait()
            finally:
                with active_lock:
                    active.discard(proc)
        elapsed = time.monotonic() - started
        log.write(
            f"finished={time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())} "
            f"rc={rc} elapsed_sec={elapsed:.3f}\n"
        )

    with state_lock:
        state["running"] -= 1
        state["completed"] += 1
        if rc != 0:
            state["failed"] += 1
        fields = (
            f"started={state['started']}/{total} "
            f"completed={state['completed']}/{total} "
            f"running={state['running']} failed={state['failed']}"
        )
    with print_lock:
        status = "done" if rc == 0 else "failed"
        print(
            f"full: task_{status} order={index}/{total} {fields} "
            f"experiment={item.experiment.name} {item_label(item)} "
            f"rc={rc} elapsed_sec={elapsed:.1f}",
            flush=True,
        )
    return item, rc


def main() -> int:
    args = make_parser().parse_args()
    if args.jobs <= 0:
        print("full: --jobs must be positive", file=sys.stderr)
        return 2
    if args.count <= 0:
        print("full: --count must be positive", file=sys.stderr)
        return 2

    try:
        all_work, all_tasks, modules = collect_work(args)
    except Exception as exc:
        print(f"full: failed to generate tasks: {exc}", file=sys.stderr)
        return 1

    prepare_result_dirs(all_work)
    pending = [
        item
        for item in all_work
        if args.force or not item.task.out_file.exists()
    ]
    skipped = len(all_work) - len(pending)
    print(
        f"full: generated={len(all_work)} pending={len(pending)} "
        f"skipped_existing={skipped} jobs={args.jobs}",
        flush=True,
    )

    print_lock = threading.Lock()
    if args.dry_run:
        print_dry_run(all_tasks, pending, print_lock)
        return 0

    # Build every executable represented by the five experiment task sets,
    # including executables whose result files already exist.  This keeps the
    # build phase explicit and independent from result-file reuse.
    if not prebuild(args, all_tasks, modules, print_lock):
        print("full: prebuild failed; simulations were not started", file=sys.stderr)
        return 1

    if not pending:
        print("full: no pending simulations", flush=True)
        return 0

    state = {"started": 0, "completed": 0, "running": 0, "failed": 0}
    state_lock = threading.Lock()
    active: set[subprocess.Popen[Any]] = set()
    active_lock = threading.Lock()
    failures: list[tuple[WorkItem, int]] = []

    executor = ThreadPoolExecutor(
        max_workers=min(args.jobs, len(pending)),
        thread_name_prefix="ooogemm-full",
    )
    futures = [
        executor.submit(
            run_one,
            item,
            index,
            len(pending),
            args,
            print_lock,
            state,
            state_lock,
            active,
            active_lock,
        )
        for index, item in enumerate(pending, start=1)
    ]

    interrupted = False
    try:
        for future in as_completed(futures):
            item, rc = future.result()
            if rc != 0:
                failures.append((item, rc))
    except KeyboardInterrupt:
        interrupted = True
        with active_lock:
            children = list(active)
        print(
            f"full: interrupted; terminating {len(children)} child processes",
            file=sys.stderr,
            flush=True,
        )
        for proc in children:
            proc.terminate()
        for future in futures:
            future.cancel()
    finally:
        # Waiting here ensures no simulation worker or child process is left
        # behind when the wrapper exits.
        executor.shutdown(wait=True)

    if interrupted:
        return 130
    if failures:
        print(f"full: failures={len(failures)}", file=sys.stderr)
        for item, rc in failures:
            print(
                f"  experiment={item.experiment.name} rc={rc} "
                f"log={item.task.log_file} output={item.task.out_file}",
                file=sys.stderr,
            )
        return 1

    print("full: all pending simulations completed", flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
