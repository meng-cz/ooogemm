#!/usr/bin/env python3
"""Build fixed ASAP7 PE -> SA -> Top hard macros with inlined SRAM RTL and durable restart.

--dry-run writes inputs and a dependency/command plan, never starts a backend.
Without --dry-run, execution is real and automatically resumes this workspace.
The tests inject a synthetic backend; there is no synthetic production CLI mode.
"""
from __future__ import annotations

import argparse
from collections import Counter, deque
from concurrent.futures import FIRST_COMPLETED, ThreadPoolExecutor, wait
from dataclasses import dataclass
import csv
import fcntl
import heapq
import io
import json
import logging
import math
import os
from pathlib import Path
import re
import shlex
import shutil
import signal
import sqlite3
import subprocess
import sys
import threading
import time

from hierarchical_openroad_support import (
    FlowError, atomic_json, atomic_write, canonical, digest, emit_layout,
    file_digest, macro_name, require, sync_directory, tcl_word, validate_views, wrappers,
)


ROOT = Path(__file__).resolve().parents[1]
DEFAULT_CONFIG = Path(__file__).with_name("hierarchical_openroad.json")
HOOKS = Path(__file__).with_name("hierarchical_openroad_hooks.tcl")
PHASES = ("synth", "floorplan", "place", "cts", "route", "finish", "abstract")
MAJOR = dict(zip(PHASES, (1, 2, 3, 4, 5, 6, 7)))
KINDS = {"pe": "pe", "sa": "sa", "top_static": "top", "top_dynamic": "top"}
LOG = logging.getLogger("hierarchical_openroad")


def load_config(path=DEFAULT_CONFIG):
    default = json.loads(DEFAULT_CONFIG.read_text())
    if Path(path).resolve() != DEFAULT_CONFIG.resolve():
        supplied = json.loads(Path(path).read_text())
        require(not (set(supplied) - set(default)), "Unknown configuration fields: " + ", ".join(set(supplied) - set(default)))
        default.update(supplied)
    require((default["platform"], default["corner"], default["vt"]) == ("asap7", "BC", "RVT"), "Only ASAP7 BC/RVT is supported")
    require(default["initial_period_ps"] == 1000, "Every module must start at 1000 ps (1 GHz)")
    require(0 < default["ratio_min"] <= default["ratio_target"] <= default["ratio_max"], "Invalid convergence interval")
    for key in ("workers", "openroad_threads", "max_search_iterations", "max_publication_iterations", "memory_max_bits"):
        require(isinstance(default[key], int) and not isinstance(default[key], bool), f"{key} must be an integer")
    for key in ("workers", "openroad_threads", "period_quantum_ps", "max_search_iterations", "max_publication_iterations", "memory_max_bits"):
        require(default[key] > 0, f"{key} must be positive")
    require(0 < default["standard_cell_utilization"] <= 1 and 0 <= default["io_budget_fraction"] < .5,
            "Invalid utilization/I/O budget")
    require(default["macro_channel_um"] >= 0 and default["macro_halo_um"] >= 0
            and default["core_margin_um"] > 0 and default["publication_margin"] > 0,
            "Invalid physical/publication margins")
    require(default["stage_timeout_seconds"] >= 0 and default["terminate_grace_seconds"] > 0, "Invalid timeout/grace interval")
    for key in ("hold_slack_margin_ps", "hold_retry_margin_step_ps"):
        require(isinstance(default[key], (int, float)) and not isinstance(default[key], bool)
                and math.isfinite(default[key]), f"{key} must be a finite number")
    require(default["hold_slack_margin_ps"] >= 0 and default["hold_retry_margin_step_ps"] > 0,
            "Hold repair margin must be nonnegative and retry increment must be positive")
    require(type(default["hold_max_buffer_percent"]) is int and 1 <= default["hold_max_buffer_percent"] <= 100,
            "hold_max_buffer_percent must be an integer in 1..100; 0 is not unlimited")
    require(all(not isinstance(v, (float, int)) or math.isfinite(v) for v in default.values()), "Nonfinite configuration")
    return default


@dataclass
class Task:
    record: dict
    kind: str
    dependencies: Counter
    inline: list[str]

    @property
    def name(self):
        return self.record["name"]

    @property
    def hard(self):
        return macro_name(self.name)


class Graph:
    def __init__(self, manifest, expected=True):
        self.path = Path(manifest).resolve()
        self.source_root = self.path.parent
        self.manifest = json.loads(self.path.read_text())
        self.records = {m["name"]: m for m in self.manifest["modules"]}
        self.tasks = {}
        selected = {n for n, r in self.records.items() if r["original_module"] in KINDS}
        for name in sorted(selected):
            deps, inline, active = Counter(), set(), set()
            def visit(node, count=1):
                require(node not in active, f"Module cycle: {node}")
                if node in selected and node != name:
                    deps[node] += count
                    return
                active.add(node)
                inline.add(node)
                for child in self.records[node]["children"]:
                    visit(child["module"], count * child["count"])
                active.remove(node)
            visit(name)
            self.tasks[name] = Task(self.records[name], KINDS[self.records[name]["original_module"]], deps, sorted(inline))
        if expected:
            require(Counter(t.kind for t in self.tasks.values()) == {"pe": 3, "sa": 3, "top": 6},
                    "Expected three PEs, three SAs and six root top_ modules; SRAM RTL is inlined")
            for task in self.tasks.values():
                expected_children = {"pe": set(), "sa": {"pe"}, "top": {"sa"}}[task.kind]
                require({self.tasks[name].kind for name in task.dependencies} == expected_children,
                        f"Unexpected hard-macro dependencies for {task.name}")
        require(len(self.records) == len(self.manifest["modules"]), "Duplicate manifest module")
        for record in self.records.values():
            require((self.source_root / record["file"]).is_file(), f"Missing RTL: {record['file']}")
        self.packages = [self.source_root / p["file"] for p in self.manifest["packages"]]
        self._own_inputs = {}

    def own_inputs(self, task):
        if task.name not in self._own_inputs:
            package_paths = {p["name"]: self.source_root / p["file"] for p in self.manifest["packages"]}
            def references(path):
                source = re.sub(r'//[^\n]*|/\*.*?\*/|"(?:\\.|[^"\\])*"', ' ', path.read_text(), flags=re.S)
                return set(re.findall(r"\b([A-Za-z_]\w*)\s*::", source)) & set(package_paths)
            modules = [self.source_root / self.records[n]["file"] for n in task.inline]
            needed = set().union(*(references(p) for p in modules))
            while True:
                closure = needed | set().union(*(references(package_paths[n]) for n in needed))
                if closure == needed:
                    break
                needed = closure
            self._own_inputs[task.name] = [p for p in self.packages if p in {package_paths[n] for n in needed}] + modules
        return self._own_inputs[task.name]

    def descendants(self, names):
        result = set(names)
        while True:
            expanded = result | {n for n, t in self.tasks.items() if set(t.dependencies) & result}
            if expanded == result:
                return result
            result = expanded


class TaskSchedule:
    """Coordinator-owned DAG state; completions release only their dependents."""

    def __init__(self, tasks, statuses):
        self.tasks, self.statuses = tasks, dict(statuses)
        self.dependents = {name: set() for name in tasks}
        for name, task in tasks.items():
            for child in task.dependencies:
                require(child in tasks, f"Unknown task dependency: {name} -> {child}")
                self.dependents[child].add(name)
        # Check the whole DAG before any backend is submitted, including nodes
        # already completed in the database.
        degree = {name: len(task.dependencies) for name, task in tasks.items()}
        roots = deque(name for name, count in degree.items() if not count)
        visited = 0
        while roots:
            visited += 1
            for parent in self.dependents[roots.popleft()]:
                degree[parent] -= 1
                if degree[parent] == 0:
                    roots.append(parent)
        require(visited == len(tasks), "Cyclic task dependencies")
        self.remaining = {name: {child for child in task.dependencies if statuses[child] != "done"}
                          for name, task in tasks.items()}
        self.blocked = []
        for name in sorted(tasks):
            if self.statuses[name] in ("failed", "blocked"):
                self._block_dependents(name)
        self.ready = []
        for name in sorted(tasks):
            if self.statuses[name] == "pending" and not self.remaining[name]:
                self._enqueue(name)

    def _enqueue(self, name):
        priority = {"pe": 0, "sa": 1, "top": 2}
        heapq.heappush(self.ready, (priority[self.tasks[name].kind], name))

    def _block_dependents(self, name):
        failed = deque([name])
        while failed:
            for parent in sorted(self.dependents[failed.popleft()]):
                if self.statuses[parent] != "pending":
                    continue
                self.statuses[parent] = "blocked"
                children = sorted(child for child in self.tasks[parent].dependencies
                                  if self.statuses[child] in ("failed", "blocked"))
                self.blocked.append((parent, children))
                failed.append(parent)

    def pop_ready(self):
        while self.ready:
            _, name = heapq.heappop(self.ready)
            if self.statuses[name] == "pending":
                self.statuses[name] = "running"
                return name
        return None

    def complete(self, name, status):
        self.statuses[name] = status
        if status == "done":
            for parent in sorted(self.dependents[name]):
                self.remaining[parent].discard(name)
                if self.statuses[parent] == "pending" and not self.remaining[parent]:
                    self._enqueue(parent)
        elif status in ("failed", "blocked"):
            self._block_dependents(name)


class State:
    """One connection guarded for worker threads; all state commits are durable."""
    def __init__(self, path, synthetic):
        self.lock = threading.RLock()
        self.db = sqlite3.connect(path, check_same_thread=False)
        self.db.execute("PRAGMA journal_mode=WAL")
        self.db.execute("PRAGMA synchronous=FULL")
        self.db.executescript("""
          CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
          CREATE TABLE IF NOT EXISTS tasks (name TEXT PRIMARY KEY, data TEXT NOT NULL);
          CREATE TABLE IF NOT EXISTS stages (key TEXT PRIMARY KEY, data TEXT NOT NULL);
          CREATE TABLE IF NOT EXISTS attempts (key TEXT PRIMARY KEY, data TEXT NOT NULL);
          CREATE TABLE IF NOT EXISTS retired_tasks (key TEXT PRIMARY KEY, data TEXT NOT NULL);
          CREATE TABLE IF NOT EXISTS events (id INTEGER PRIMARY KEY, time REAL, task TEXT, kind TEXT, data TEXT);
        """)
        with self.db:
            old = dict(self.db.execute("SELECT key,value FROM meta"))
            require(old.get("schema", "1") == "1", "Unsupported state schema")
            require(old.get("synthetic", str(bool(synthetic))) == str(bool(synthetic)), "Cannot mix synthetic and real workspaces")
            self.db.execute("INSERT OR REPLACE INTO meta VALUES ('schema','1')")
            self.db.execute("INSERT OR REPLACE INTO meta VALUES ('synthetic',?)", (str(bool(synthetic)),))

    def get(self, table, key):
        with self.lock:
            column = "name" if table == "tasks" else "key"
            row = self.db.execute(f"SELECT data FROM {table} WHERE {column}=?", (key,)).fetchone()
            return json.loads(row[0]) if row else None

    def put(self, table, key, value):
        with self.lock, self.db:
            self.db.execute(f"INSERT OR REPLACE INTO {table} VALUES (?,?)", (key, canonical(value)))

    def all(self, table):
        with self.lock:
            return [json.loads(r[0]) for r in self.db.execute(f"SELECT data FROM {table}")]

    def event(self, task, kind, data):
        with self.lock, self.db:
            self.db.execute("INSERT INTO events(time,task,kind,data) VALUES (?,?,?,?)", (time.time(), task, kind, canonical(data)))

    def retire_missing_tasks(self, active_names):
        with self.lock, self.db:
            for name, data in self.db.execute("SELECT name,data FROM tasks").fetchall():
                if name not in active_names:
                    self.db.execute("INSERT OR REPLACE INTO retired_tasks VALUES (?,?)", (name, data))
                    self.db.execute("DELETE FROM tasks WHERE name=?", (name,))

    def close(self):
        self.db.close()


class WorkspaceLock:
    def __init__(self, path):
        self.path, self.fd = Path(path), None

    def __enter__(self):
        self.path.parent.mkdir(parents=True, exist_ok=True)
        self.fd = os.open(self.path, os.O_RDWR | os.O_CREAT, 0o600)
        try:
            fcntl.flock(self.fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            owner = os.read(self.fd, 4096).decode(errors="replace")
            os.close(self.fd)
            self.fd = None
            raise FlowError(f"Workspace busy; coordinator/backend still holds lock: {owner}", "busy")
        os.ftruncate(self.fd, 0)
        os.write(self.fd, canonical({"coordinator_pid": os.getpid(), "started": time.time()}).encode())
        os.fsync(self.fd)
        return self

    def __exit__(self, *_):
        # Close, do not LOCK_UN: a still-running child inherits this flock.
        if self.fd is not None:
            os.close(self.fd)
            self.fd = None


def load_environment():
    completed = subprocess.run(["bash", "-c", 'source "$1" >/dev/null && env -0', "bash", str(ROOT / "openroadenv.sh")],
                               capture_output=True, check=True)
    return dict(item.decode().split("=", 1) for item in completed.stdout.split(b"\0") if item)


class NativeBackend:
    synthetic = False

    def __init__(self, environment):
        self.env = dict(environment)
        self.flow = Path(self.env["FLOW_HOME"])
        # Flow knobs come from the recorded configuration, not unrecorded shell
        # exports (e.g. SKIP_DETAILED_ROUTE or a different FLOW_VARIANT).
        yaml = self.flow / "scripts/variables.yaml"
        tool_variables = {"OPENROAD_EXE", "YOSYS_EXE", "KLAYOUT_CMD", "PYTHON_EXE", "FLOW_HOME"}
        for key in re.findall(r"^([A-Z][A-Z0-9_]*):", yaml.read_text(), re.M):
            if key not in tool_variables:
                self.env.pop(key, None)
        files = {Path(self.env[n]) for n in ("OPENROAD_EXE", "YOSYS_EXE", "KLAYOUT_CMD")}
        for tool in ("make", "python3"):
            executable = (self.env.get("PYTHON_EXE") if tool == "python3" else None) or shutil.which(tool, path=self.env.get("PATH"))
            require(executable, f"Missing runtime tool: {tool}")
            files.add(Path(executable))
        files.update(p for folder in (self.flow / "scripts", self.flow / "util", self.flow / "platforms/asap7")
                     for p in folder.rglob("*") if p.is_file() and "__pycache__" not in p.parts
                     and p.suffix not in (".pyc", ".pyo") and ".pytest_cache" not in p.parts)
        files.add(self.flow / "Makefile")
        # Read-only hashing: dry run never invokes OpenROAD, Yosys or KLayout.
        self.identity = {"backend": "native", "files": {str(p): file_digest(p) for p in sorted(files)},
                         "environment": {k: self.env.get(k) for k in sorted(tool_variables | {"LD_LIBRARY_PATH"})}}

    def command(self, job, phase, completed_outputs):
        return ["make", "--no-print-directory", "-f", str(self.flow / "Makefile"),
                "FLOW_HOME=" + str(self.flow), "WORK_HOME=" + str(job["run"]),
                "DESIGN_CONFIG=" + str(job["inputs"] / "config.mk"),
                *["--assume-old=" + str(p) for p in completed_outputs],
                "generate_abstract" if phase == "abstract" else phase]


def result_paths(job):
    suffix = Path("asap7") / job["task"].hard / "base"
    return {"results": job["run"] / "results" / suffix,
            "logs": job["run"] / "logs" / suffix,
            "reports": job["run"] / "reports" / suffix}


def phase_outputs(job, phase):
    p = result_paths(job)
    if phase in ("synth", "floorplan", "place", "cts", "route"):
        stem = {"synth": "1_synth", "floorplan": "2_floorplan", "place": "3_place", "cts": "4_cts", "route": "5_route"}[phase]
        return [p["results"] / (stem + ext) for ext in (".odb", ".sdc")]
    if phase == "finish":
        return [p["results"] / ("6_final" + ext) for ext in (".odb", ".sdc", ".v", ".gds", ".spef")] + [
            p["logs"] / "6_report.json", p["logs"] / "5_2_route.json",
            p["reports"] / "6_finish.rpt", job["run"] / "hierarchy_checks.json"]
    return [p["results"] / (job["task"].hard + ".lef"), p["results"] / (job["task"].hard + "_typ.lib")]


def snapshot(paths):
    result = {}
    for p in paths:
        require(p.is_file() and p.stat().st_size > 0, f"Missing/empty stage artifact: {p}", category="missing_artifact")
        result[str(p)] = file_digest(p)
    return result


def snapshot_valid(artifacts):
    try:
        return bool(artifacts) and all(Path(p).is_file() and file_digest(p) == checksum for p, checksum in artifacts.items())
    except OSError:
        return False


def clean_partial(job, phase):
    major = MAJOR[phase]
    if phase == "abstract":
        for p in phase_outputs(job, phase):
            p.unlink(missing_ok=True)
        return
    for directory in result_paths(job).values():
        if directory.exists():
            for path in directory.iterdir():
                if path.name[:1].isdigit() and int(path.name[0]) >= major and path.is_file():
                    path.unlink()
    for p in phase_outputs(job, "abstract"):
        p.unlink(missing_ok=True)
    objects = job["run"] / "objects/asap7" / job["task"].hard / "base"
    if major == 1 and objects.exists():
        shutil.rmtree(objects)
    elif major <= 6 and objects.exists():
        for path in objects.glob("klayout*"):
            if path.is_file():
                path.unlink()
    if major <= 2:
        for name in ("layout.tcl", "layout.json", "layout_request.json"):
            (job["run"] / name).unlink(missing_ok=True)
    (job["run"] / "hierarchy_checks.json").unlink(missing_ok=True)


def finite_number(value, name, positive=False):
    require(isinstance(value, (int, float)) and not isinstance(value, bool) and math.isfinite(value)
            and (not positive or value > 0), f"Missing/nonfinite metric: {name}", category="invalid_metrics")
    return float(value)


def read_metrics(job, children):
    p = result_paths(job)
    try:
        metrics = json.loads((p["logs"] / "6_report.json").read_text())
        route = json.loads((p["logs"] / "5_2_route.json").read_text())
        hierarchy = json.loads((job["run"] / "hierarchy_checks.json").read_text())
    except (ValueError, OSError) as exc:
        raise FlowError(f"Cannot read extracted timing/routing metrics: {exc}", "invalid_metrics") from exc
    expected = {macro_name(k): v for k, v in job["task"].dependencies.items()}
    require(hierarchy.get("macro_counts") == expected, "Macro counts do not match RTL hierarchy")
    require(hierarchy.get("power_connected") is True, "Macro supplies not connected")
    result = {"target_period_ps": job["period"], "synthetic": job["synthetic"],
              "hold_slack_margin_ps": job["hold_slack_margin_ps"],
              "hold_max_buffer_percent": job["hold_max_buffer_percent"]}
    result["sta_min_period_ps"] = 1e12 / finite_number(metrics.get("finish__timing__fmax"), "fmax", True)
    for label, key in (("setup_ws_ps", "setup__ws"), ("hold_ws_ps", "hold__ws"),
                       ("setup_tns_ps", "setup__tns"), ("hold_tns_ps", "hold__tns")):
        result[label] = finite_number(metrics.get("finish__timing__" + key), key)
    for label, key in (("standard_cell_area_um2", "instance__area__stdcell"),
                       ("macro_area_um2", "instance__area__macros"), ("core_area_um2", "core__area"), ("die_area_um2", "die__area")):
        result[label] = finite_number(metrics.get("finish__design__" + key), key)
        require(result[label] >= 0, f"Negative area: {label}")
    result["drc_errors"] = finite_number(route.get("detailedroute__route__drc_errors"), "DRC count")
    result["unrouted_nets"] = finite_number(hierarchy.get("unrouted_nets"), "unrouted nets")
    require(result["drc_errors"] == 0 and result["unrouted_nets"] == 0, "Physical routing did not complete cleanly", category="routing")
    cap = max((c["metrics"]["validated_period_ps"] for c in children.values()), default=0)
    result["child_period_limit_ps"] = cap
    result["effective_min_period_ps"] = max(result["sta_min_period_ps"], cap)
    result["limiting_children"] = [n for n, c in children.items() if c["metrics"]["validated_period_ps"] == cap and cap >= result["sta_min_period_ps"]]
    result["ratio"] = result["effective_min_period_ps"] / job["period"]
    result["electrical"] = {k: v for k, v in metrics.items() if "__drv__" in k}
    result["hierarchical_standard_cell_area_um2"] = result["standard_cell_area_um2"] + sum(
        count * children[name]["metrics"]["hierarchical_standard_cell_area_um2"] for name, count in job["task"].dependencies.items())
    return result


def quantize(period, config):
    q = config["period_quantum_ps"]
    return round(max(q, round(period / q) * q), 9)


def search_next(metrics, period, config):
    ratio = metrics["effective_min_period_ps"] / period
    if config["ratio_min"] <= ratio <= config["ratio_max"]:
        return None
    result = quantize(metrics["effective_min_period_ps"] / config["ratio_target"], config)
    require(abs(result - period) > config["period_quantum_ps"] / 2, "Frequency search stagnated", category="nonconvergent")
    return result


def timing_pass(metrics):
    return (metrics["setup_ws_ps"] >= 0 and metrics["hold_ws_ps"] >= 0
            and metrics["setup_tns_ps"] == 0 and metrics["hold_tns_ps"] == 0
            and metrics["target_period_ps"] >= metrics["child_period_limit_ps"])


def sweep_key(name, fingerprint, mode, index, period):
    return f"{name}/{fingerprint}/{mode}-{index:02d}-{period:.9f}ps"


def publication_next(metrics, period, hold_margin, config):
    """Back off setup by period; repair hold by increasing the buffer margin."""
    if (metrics["setup_ws_ps"] < 0 or metrics["setup_tns_ps"] != 0
            or period < metrics["child_period_limit_ps"]):
        period = max(quantize(metrics["effective_min_period_ps"] * (1 + config["publication_margin"]), config),
                     quantize(period * (1 + config["publication_margin"]), config))
    if metrics["hold_ws_ps"] < 0 or metrics["hold_tns_ps"] != 0:
        hold_margin = round(hold_margin + max(config["hold_retry_margin_step_ps"], -metrics["hold_ws_ps"]), 9)
    return period, hold_margin


def make_sdc(task, period, config):
    reset = any(p["name"] == "rst_n" for p in task.record["ports"])
    budget = period * config["io_budget_fraction"]
    return (f"# ASAP7 time unit is ps. I/O max delays use {config['io_budget_fraction']:.0%} of the target.\n"
            f"create_clock -name core_clock -period {period:.6f} [get_ports clk]\n"
            "set data_inputs [all_inputs -no_clocks]\n" +
            ("set_case_analysis 1 [get_ports rst_n]\n"
             "set data_inputs [lsearch -all -inline -not -exact $data_inputs [lindex [get_ports rst_n] 0]]\n" if reset else "") +
            f"set_input_delay -max {budget:.6f} -clock core_clock $data_inputs\n"
            "set_input_delay -min 0 -clock core_clock $data_inputs\n"
            f"set_output_delay -max {budget:.6f} -clock core_clock [all_outputs]\n"
            "set_output_delay -min 0 -clock core_clock [all_outputs]\n"
            "# ASAP7 RVT ABC_DRIVER_CELL / ABC_LOAD_IN_FF defaults.\n"
            "set_driving_cell -lib_cell BUFx2_ASAP7_75t_R -pin Y $data_inputs\n"
            "set_load 3.898 [all_outputs]\n")


def build_inputs(graph, task, directory, period, config, backend, children, synthetic=False, dry=False, source_snapshots=None):
    directory = Path(directory)
    inputs, run = directory / "inputs", directory / "run"
    inputs.mkdir(parents=True, exist_ok=True)
    run.mkdir(parents=True, exist_ok=True)
    job = {"task": task, "directory": directory, "inputs": inputs, "run": run,
           "period": period, "synthetic": synthetic, "children": children,
           "hold_slack_margin_ps": config["hold_slack_margin_ps"],
           "hold_max_buffer_percent": config["hold_max_buffer_percent"]}
    wrapper, _, _, mapping = wrappers(task.record)
    atomic_write(inputs / "wrapper.sv", wrapper)
    atomic_json(inputs / "port_map.json", {"module": task.name, "hard_module": task.hard, "ports": mapping})
    sources = []
    for path in graph.own_inputs(task):
        frozen = inputs / "rtl" / path.relative_to(graph.source_root)
        content = source_snapshots[path] if source_snapshots is not None else path.read_bytes()
        atomic_write(frozen, content.decode("utf-8"))
        sources.append(frozen)
    sources.append(inputs / "wrapper.sv")
    for name in sorted(task.dependencies):
        _, adapter, stub, _ = wrappers(graph.records[name])
        atomic_write(inputs / (name + ".adapter.sv"), adapter)
        atomic_write(inputs / (name + ".blackbox.sv"), stub)
        sources.extend([inputs / (name + ".adapter.sv"), inputs / (name + ".blackbox.sv")])
        if not dry:
            validate_views(graph.records[name], children[name]["artifacts"]["lef"], children[name]["artifacts"]["lib"])
    atomic_write(inputs / "constraint.sdc", make_sdc(task, period, config))
    values = task.record["parameters"]
    rows = values.get("SUBTILE_M", {"value": 1})["value"]
    cols = values.get("SUBTILE_N", {"value": 1})["value"]
    settings = {"hr_kind": task.kind, "hr_rows": rows, "hr_cols": cols,
                "hr_layout_request": run / "layout_request.json", "hr_layout_file": run / "layout.tcl",
                "hr_check_file": run / "hierarchy_checks.json", "hr_python": sys.executable,
                "hr_hold_max_buffer_percent": config["hold_max_buffer_percent"],
                "hr_runner": Path(__file__).resolve()}
    text = "".join(f"set ::{key} {tcl_word(value)}\n" for key, value in settings.items())
    text += f"set ::hr_config_json [binary decode hex {canonical(config).encode().hex()}]\n"
    text += "set ::hr_expected [dict create " + " ".join(f"{tcl_word(macro_name(n))} {count}" for n, count in sorted(task.dependencies.items())) + "]\n"
    atomic_write(inputs / "settings.tcl", text)
    for filename, call in (("floorplan.tcl", "hr_floorplan"), ("macro_place.tcl", "hr_place"),
                           ("check_place.tcl", "hr_check 0"), ("check_final.tcl", "hr_check 1"),
                           ("timing_repair.tcl", "hr_configure_timing_repair")):
        atomic_write(inputs / filename, f"source {tcl_word(inputs / 'settings.tcl')}\nsource {tcl_word(HOOKS)}\n{call}\n")
    io_constraints = "# Native default I/O placement.\n"
    if task.kind == "pe":
        io_constraints = "\n".join([
            "set_io_pin_constraint -group -pin_names {left_*} -region left:*",
            "set_io_pin_constraint -group -pin_names {right_*} -region right:*",
            "set_io_pin_constraint -group -pin_names {top_b_i*} -region top:*",
            "set_io_pin_constraint -group -pin_names {bottom_b_o* getacc*} -region bottom:*", ""])
    atomic_write(inputs / "io.tcl", io_constraints)
    flow = backend.flow
    defs = {
        "PLATFORM": "asap7", "CORNER": "BC", "ASAP7_USE_VT": "RVT", "DESIGN_NAME": task.hard,
        "FLOW_VARIANT": "base", "SYNTH_HDL_FRONTEND": "slang", "SYNTH_USE_SYN": 0,
        "NUM_CORES": config["openroad_threads"], "BLOCKS": "", "CORNERS": "",
        "HOLD_SLACK_MARGIN": config["hold_slack_margin_ps"],
        "SKIP_DETAILED_ROUTE": 0, "SKIP_REPORT_METRICS": 0, "AUTO_MEMORIES": 0,
        "VERILOG_FILES": " ".join(map(str, sources)), "SDC_FILE": inputs / "constraint.sdc",
        "CORE_UTILIZATION": 50, "CORE_MARGIN": config["core_margin_um"],
        "SYNTH_MEMORY_MAX_BITS": config["memory_max_bits"], "SYNTH_MOCK_LARGE_MEMORIES": 0,
        "MACRO_PLACE_HALO": f"{config['macro_halo_um']} {config['macro_halo_um']}",
        "MACRO_ROWS_HALO_X": config["macro_halo_um"], "MACRO_ROWS_HALO_Y": config["macro_halo_um"],
        "PRE_FLOORPLAN_TCL": inputs / "floorplan.tcl", "MACRO_PLACEMENT_TCL": inputs / "macro_place.tcl",
        "POST_MACRO_PLACE_TCL": inputs / "check_place.tcl", "POST_FINAL_REPORT_TCL": inputs / "check_final.tcl",
        "PRE_IO_PLACEMENT_TCL": inputs / "io.tcl",
        "PRE_CTS_TCL": inputs / "timing_repair.tcl", "PRE_GLOBAL_ROUTE_TCL": inputs / "timing_repair.tcl",
    }
    if task.dependencies:
        defs["SYNTH_BLACKBOXES"] = " ".join(macro_name(n) for n in sorted(task.dependencies))
        for variable, artifact in (("ADDITIONAL_LEFS", "lef"), ("ADDITIONAL_LIBS", "lib"), ("ADDITIONAL_GDS", "gds")):
            defs[variable] = " ".join(str(children[n]["artifacts"][artifact]) for n in sorted(task.dependencies))
        defs["PDN_TCL"] = flow / "platforms/asap7/openRoad/pdn/BLOCKS_grid_strategy.tcl"
    for value in defs.values():
        require(not any(c in str(value) for c in "\n\r#$"), "Unsupported Makefile path/value")
    atomic_write(inputs / "config.mk", "# Generated; do not edit.\n" + "".join(f"export {key} = {value}\n" for key, value in defs.items()))
    atomic_json(inputs / "job.json", {"module": task.name, "hard_module": task.hard, "kind": task.kind,
                "period_ps": period, "synthetic": synthetic, "dependencies": dict(task.dependencies),
                "hold_slack_margin_ps": config["hold_slack_margin_ps"],
                "hold_max_buffer_percent": config["hold_max_buffer_percent"],
                "inlined_sram_modules": [name for name in task.inline
                                         if graph.records[name]["original_module"] in ("sram1r1w", "sram2r1w")],
                "geometry": "resolved from actual OpenDB masters at floorplan time", "sources": list(map(str, sources))})
    return job


class Engine:
    def __init__(self, graph, work, config, backend, checkpoint=None):
        self.graph, self.work, self.config, self.backend = graph, Path(work).resolve(), config, backend
        # Stable dependency-order IDs identify concurrent tasks and survive
        # restart without confusing a task's index with its completion count.
        ordering = TaskSchedule(graph.tasks, {name: "pending" for name in graph.tasks})
        self.task_numbers = {}
        while (name := ordering.pop_ready()) is not None:
            self.task_numbers[name] = len(self.task_numbers) + 1
            ordering.complete(name, "done")
        self.work.mkdir(parents=True, exist_ok=True)
        self.state = State(self.work / "state.sqlite3", backend.synthetic)
        self.stop = threading.Event()
        self.checkpoint = checkpoint or (lambda event, payload: None)
        self.workspace_lock = None
        self.process_lock = threading.Lock()
        self.processes = set()
        implementation = {p.name: file_digest(p) for p in (Path(__file__), HOOKS, Path(__file__).with_name("hierarchical_openroad_support.py"))}
        paths = {p for task in graph.tasks.values() for p in graph.own_inputs(task)}
        self.source_snapshots = {p: p.read_bytes() for p in paths}
        def signature(record):
            # Reverse usage counts are not inputs to this module's hardware.
            return {k: record[k] for k in ("name", "original_module", "parameters", "ports", "children")}
        hardware_config = {key: value for key, value in config.items() if key != "workers"}
        self.base = {t.name: digest([hardware_config, backend.identity, implementation,
                     [signature(graph.records[n]) for n in t.inline], dict(t.dependencies),
                     {str(p.relative_to(graph.source_root)): digest(self.source_snapshots[p].hex()) for p in graph.own_inputs(t)}])
                     for t in graph.tasks.values()}

    def close(self):
        self.state.close()

    def task_label(self, name):
        return f"[任务 {self.task_numbers[name]}/{len(self.task_numbers)}] {name}"

    def notify(self, event, **payload):
        self.state.event(payload.get("task", ""), event, payload)
        self.checkpoint(event, payload)

    def sweep_point(self, task, fp, mode="search", index=0, period=None, hold_margin=None, search_metrics=None,
                    hold_max_buffer_percent=None):
        period = self.config["initial_period_ps"] if period is None else period
        return {"fingerprint": fp, "mode": mode, "index": index, "period_ps": period,
                "hold_slack_margin_ps": self.config["hold_slack_margin_ps"] if hold_margin is None else hold_margin,
                "hold_max_buffer_percent": (self.config["hold_max_buffer_percent"] if hold_max_buffer_percent is None
                                            else hold_max_buffer_percent),
                "search_metrics": search_metrics, "phase": "inputs",
                "attempt_key": sweep_key(task.name, fp, mode, index, period)}

    def advance_sweep(self, task, point, metrics):
        index, period, fp = point["index"], point["period_ps"], point["fingerprint"]
        budget = point["hold_max_buffer_percent"]
        if point["mode"] == "search":
            next_period = search_next(metrics, period, self.config)
            if next_period is None:
                return self.sweep_point(task, fp, "publish", period=quantize(
                    metrics["effective_min_period_ps"] * (1 + self.config["publication_margin"]), self.config),
                    search_metrics=metrics, hold_max_buffer_percent=budget)
            require(index + 1 < self.config["max_search_iterations"],
                    "Frequency search reached iteration limit", category="nonconvergent")
            return self.sweep_point(task, fp, index=index + 1, period=next_period, hold_max_buffer_percent=budget)
        if timing_pass(metrics):
            return None  # Stay at this point until abstract export and publication commit.
        require(index + 1 < self.config["max_publication_iterations"],
                "Publication timing did not pass setup/hold", category="timing",
                period_ps=period, hold_slack_margin_ps=point["hold_slack_margin_ps"],
                hold_max_buffer_percent=budget,
                **{key: metrics[key] for key in ("setup_ws_ps", "setup_tns_ps", "hold_ws_ps", "hold_tns_ps")})
        next_period, margin = publication_next(metrics, period, point["hold_slack_margin_ps"], self.config)
        return self.sweep_point(task, fp, "publish", index + 1, next_period, margin, point["search_metrics"], budget)

    def restore_sweep(self, task, fp):
        point = self.state.get("tasks", task.name).get("progress")
        if isinstance(point, dict) and point.get("fingerprint") == fp:
            point.setdefault("hold_max_buffer_percent", self.config["hold_max_buffer_percent"])
            mode, index, period, margin = (point.get(key) for key in
                                           ("mode", "index", "period_ps", "hold_slack_margin_ps"))
            valid = (mode in ("search", "publish") and isinstance(index, int) and not isinstance(index, bool)
                     and 0 <= index < self.config["max_search_iterations" if mode == "search" else "max_publication_iterations"]
                     and isinstance(period, (int, float)) and not isinstance(period, bool) and math.isfinite(period) and period > 0
                     and isinstance(margin, (int, float)) and not isinstance(margin, bool) and math.isfinite(margin) and margin >= 0)
            valid = (valid and type(point["hold_max_buffer_percent"]) is int
                     and 1 <= point["hold_max_buffer_percent"] <= 100)
            if (valid and point.get("attempt_key") == sweep_key(task.name, fp, mode, index, period)
                    and point.get("phase") in ("inputs", *PHASES, "publish")
                    and (mode == "search" or isinstance(point.get("search_metrics"), dict))):
                return point
        # Legacy state has attempts but no cursor. Follow its recorded trajectory
        # using metrics only; do not replay earlier attempts or invoke any tools.
        def recorded_phase(point, attempt):
            if attempt:
                for phase in PHASES if point["mode"] == "publish" else PHASES[:-1]:
                    stage = self.state.get("stages", point["attempt_key"] + "/" + phase)
                    if not stage or stage["status"] != "done":
                        return dict(point, phase=phase)
                return dict(point, phase="publish" if point["mode"] == "publish" else "finish")
            return point
        point = self.sweep_point(task, fp)
        while True:
            attempt = self.state.get("attempts", point["attempt_key"])
            if attempt and "hold_max_buffer_percent" in attempt:
                point["hold_max_buffer_percent"] = attempt["hold_max_buffer_percent"]
            if not attempt or attempt["status"] != "done" or not attempt.get("metrics"):
                return recorded_phase(point, attempt)
            try:
                following = self.advance_sweep(task, point, attempt["metrics"])
            except (FlowError, KeyError, TypeError, ValueError):
                return recorded_phase(point, attempt)  # Revalidate the last point, including exhausted searches.
            if following is None:
                return recorded_phase(point, attempt)
            point = following

    def save_sweep(self, task, point):
        current = self.state.get("tasks", task.name)
        current["progress"] = dict(point)
        self.state.put("tasks", task.name, current)
        self.notify("sweep_checkpoint", task=task.name, mode=point["mode"], index=point["index"],
                    period_ps=point["period_ps"], hold_slack_margin_ps=point["hold_slack_margin_ps"],
                    hold_max_buffer_percent=point["hold_max_buffer_percent"], phase=point["phase"])

    def mark_sweep_phase(self, job, phase):
        current = self.state.get("tasks", job["task"].name)
        point = current.get("progress") if current else None
        if point and point.get("attempt_key") == job.get("attempt_key"):
            self.save_sweep(job["task"], dict(point, phase=phase))

    def dry_run(self):
        tasks = []
        for task in self.graph.tasks.values():
            children = {n: {"artifacts": {kind: str(self.work / "UNRESOLVED_PUBLISHED" / n / ("model." + kind))
                                         for kind in ("lef", "lib", "gds")}} for n in task.dependencies}
            job = build_inputs(self.graph, task, self.work / "dry_run" / task.name,
                               self.config["initial_period_ps"], self.config, self.backend, children,
                               self.backend.synthetic, dry=True, source_snapshots=self.source_snapshots)
            tasks.append({"name": task.name, "kind": task.kind, "dependencies": dict(task.dependencies),
                          "geometry": "runtime-only; no guessed macro dimensions",
                          "inputs": str(job["inputs"]), "commands": {p: self.backend.command(job, p, []) for p in PHASES}})
        plan = {"dry_run": True, "backend_executed": False, "workers": self.config["workers"],
                "task_model": "pe_sa_top_inline_sram",
                "config": self.config, "tasks": tasks, "backend_identity": self.backend.identity}
        atomic_json(self.work / "dry_run/plan.json", plan)
        return plan

    def prepare(self, retry_failed):
        self.state.retire_missing_tasks(self.graph.tasks)
        changed = set()
        for name, task in self.graph.tasks.items():
            old = self.state.get("tasks", name)
            if not old or old.get("base") != self.base[name]:
                changed.add(name)
            elif old["status"] == "done" and not self.published_valid(old.get("published")):
                changed.add(name)
            elif old["status"] in ("running", "interrupted") or (retry_failed and old["status"] in ("failed", "blocked")):
                old["status"] = "pending"
                self.state.put("tasks", name, old)
        for name, task in self.graph.tasks.items():
            old = self.state.get("tasks", name)
            if old and old["status"] == "done":
                recorded = old["published"].get("children", {})
                for child in task.dependencies:
                    current = self.state.get("tasks", child)
                    if (not current or current["status"] != "done"
                            or recorded.get(child) != current.get("published", {}).get("digest")):
                        changed.add(name)
                        break
        for name in self.graph.descendants(changed):
            self.state.put("tasks", name, {"name": name, "kind": self.graph.tasks[name].kind,
                                          "base": self.base[name], "status": "pending"})

    def published_valid(self, published):
        return bool(published) and published.get("synthetic") == self.backend.synthetic and snapshot_valid(published.get("checksums"))

    def execute_stage(self, job, phase, key, completed_outputs):
        try:
            self.mark_sweep_phase(job, phase)
            return self._execute_stage(job, phase, key, completed_outputs)
        except Exception as exc:
            stage = self.state.get("stages", key)
            details = {"task": job["task"].name, "phase": phase, "period_ps": job["period"],
                       "attempt": str(job["directory"]), "log": str(job["directory"] / (phase + ".log")),
                       **getattr(exc, "details", {})}
            if stage:
                details.setdefault("command", stage.get("command"))
                stage.update(status="interrupted" if self.stop.is_set() else "failed",
                             error={**error_record(exc), **details})
                self.state.put("stages", key, stage)
            raise FlowError(str(exc), getattr(exc, "category", "validation"), **details) from exc

    def _execute_stage(self, job, phase, key, completed_outputs):
        old = self.state.get("stages", key)
        if old and old["status"] == "done" and snapshot_valid(old.get("artifacts")):
            self.notify("stage_reused", task=job["task"].name, phase=phase, attempt=str(job["directory"]))
            LOG.info("%s %s @ %.1f ps: checkpoint reused", self.task_label(job["task"].name), phase, job["period"])
            return list(map(Path, old["artifacts"]))
        require(not self.stop.is_set(), "Execution interrupted", category="interrupted")
        clean_partial(job, phase)
        command = self.backend.command(job, phase, completed_outputs)
        log_path = job["directory"] / (phase + ".log")
        record = {"key": key, "task": job["task"].name, "phase": phase, "status": "running",
                  "command": command, "log": str(log_path), "attempt": str(job["directory"]), "started": time.time(),
                  "hold_max_buffer_percent": job["hold_max_buffer_percent"]}
        self.state.put("stages", key, record)
        env = dict(self.backend.env)
        env.update(NUM_CORES=str(self.config["openroad_threads"]), OMP_NUM_THREADS="1", OPENBLAS_NUM_THREADS="1")
        started = time.monotonic()
        with log_path.open("w") as output:
            output.write("TASK: " + self.task_label(job["task"].name) + "\n")
            output.write("COMMAND: " + shlex.join(command) + "\n")
            output.flush()
            process = subprocess.Popen(command, cwd=job["run"], env=env, stdout=output, stderr=subprocess.STDOUT,
                                       start_new_session=True, pass_fds=(self.workspace_lock.fd,))
            record.update(pid=process.pid, pgid=process.pid)
            self.state.put("stages", key, record)
            with self.process_lock:
                self.processes.add(process)
            self.notify("stage_started", task=job["task"].name, phase=phase, pid=process.pid)
            LOG.info("%s %s @ %.1f ps: pid %s; %s", self.task_label(job["task"].name), phase, job["period"], process.pid, log_path)
            try:
                while process.poll() is None:
                    timeout = self.config["stage_timeout_seconds"]
                    if self.stop.is_set() or (timeout and time.monotonic() - started > timeout):
                        self.terminate(process)
                        raise FlowError("Stage interrupted" if self.stop.is_set() else "Stage timed out",
                                        "interrupted" if self.stop.is_set() else "timeout")
                    time.sleep(.05)
                tail = log_path.read_text(errors="replace")[-6000:] if process.returncode else ""
                buffer_limit = (phase in ("cts", "route") and "RSZ-0060" in tail and "Max buffer count reached" in tail)
                require(process.returncode == 0, f"Backend exited {process.returncode}: {log_path}",
                        category="hold_buffer_limit" if buffer_limit else "tool",
                        exit_code=process.returncode, command=command, log=str(log_path), phase=phase,
                        hold_max_buffer_percent=job["hold_max_buffer_percent"], tail=tail)
            finally:
                with self.process_lock:
                    self.processes.discard(process)
        artifacts = snapshot(phase_outputs(job, phase))
        if phase == "floorplan":
            artifacts.update(snapshot([job["run"] / "layout.tcl", job["run"] / "layout.json"]))
        if phase == "abstract":
            validate_views(job["task"].record, *phase_outputs(job, phase))
        self.notify("stage_verified", task=job["task"].name, phase=phase)
        record.update(status="done", artifacts=artifacts, elapsed_seconds=time.monotonic() - started)
        self.state.put("stages", key, record)
        self.notify("stage_committed", task=job["task"].name, phase=phase)
        LOG.info("%s %s: verified and committed", self.task_label(job["task"].name), phase)
        return list(map(Path, artifacts))

    def terminate(self, process):
        if process.poll() is not None:
            return
        try:
            os.killpg(process.pid, signal.SIGTERM)
            process.wait(timeout=self.config["terminate_grace_seconds"])
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGKILL)
            process.wait()
        except ProcessLookupError:
            pass

    def attempt(self, task, fp, mode, index, period, children, *, hold_margin=None, hold_max_buffer_percent=None):
        attempt_key = sweep_key(task.name, fp, mode, index, period)
        directory = self.work / "attempts" / attempt_key
        attempt_config = dict(self.config)
        if hold_margin is not None:
            attempt_config["hold_slack_margin_ps"] = hold_margin
        if hold_max_buffer_percent is not None:
            attempt_config["hold_max_buffer_percent"] = hold_max_buffer_percent
        job = build_inputs(self.graph, task, directory, period, attempt_config, self.backend, children,
                           self.backend.synthetic, source_snapshots=self.source_snapshots)
        job["attempt_key"] = attempt_key
        record = {"key": attempt_key, "task": task.name, "fingerprint": fp, "mode": mode,
                  "index": index, "period_ps": period, "directory": str(directory), "status": "running",
                  "hold_slack_margin_ps": job["hold_slack_margin_ps"],
                  "hold_max_buffer_percent": job["hold_max_buffer_percent"]}
        self.state.put("attempts", attempt_key, record)
        completed = []
        try:
            # Search points finish with extracted timing; abstract export is
            # only necessary for the final, passing publication implementation.
            for phase in PHASES[:-1]:
                completed += self.execute_stage(job, phase, attempt_key + "/" + phase, completed)
            metrics = read_metrics(job, children)
            record.update(status="done", metrics=metrics, timing_pass=timing_pass(metrics))
            self.state.put("attempts", attempt_key, record)
            return job, metrics, completed
        except BaseException as exc:
            if isinstance(exc, Exception):
                error = {**error_record(exc), "task": task.name, "mode": mode,
                         "period_ps": period, "phase": phase, "attempt": str(directory),
                         "log": str(directory / (phase + ".log"))}
                stage_key = attempt_key + "/" + phase
                stage = self.state.get("stages", stage_key)
                if stage:
                    error.setdefault("command", stage.get("command"))
                    stage.update(status="interrupted" if self.stop.is_set() else "failed", error=error)
                    self.state.put("stages", stage_key, stage)
                if isinstance(exc, FlowError):
                    exc.details.update(error)
                record.update(status="interrupted" if self.stop.is_set() else "failed", error=error)
                self.state.put("attempts", attempt_key, record)
            if isinstance(exc, Exception):
                raise FlowError(str(exc), error["category"],
                                **{k: v for k, v in error.items() if k not in ("category", "message")}) from exc
            raise

    def publish(self, job, fp, metrics, search_metrics, children):
        paths = result_paths(job)
        task = job["task"]
        source_files = {
            "lef": paths["results"] / (task.hard + ".lef"), "lib": paths["results"] / (task.hard + "_typ.lib"),
            **{key: paths["results"] / ("6_final" + suffix) for key, suffix in
               (("gds", ".gds"), ("netlist", ".v"), ("odb", ".odb"), ("spef", ".spef"), ("sdc", ".sdc"))},
            "timing_report": paths["reports"] / "6_finish.rpt", "final_metrics": paths["logs"] / "6_report.json",
            "route_metrics": paths["logs"] / "5_2_route.json", "port_map": job["inputs"] / "port_map.json",
            "hierarchy_checks": job["run"] / "hierarchy_checks.json", "layout": job["run"] / "layout.json",
        }
        hashes = {name: file_digest(path) for name, path in source_files.items()}
        publication_id = digest([fp, metrics, hashes])
        destination = self.work / "published" / task.name / publication_id
        staging = destination.with_name("." + publication_id + ".tmp")
        published_metrics = dict(metrics, validated_period_ps=job["period"],
                                 validated_frequency_hz=1e12 / job["period"],
                                 estimated_frequency_hz=1e12 / metrics["effective_min_period_ps"],
                                 search_convergence_ratio=search_metrics["ratio"])
        artifacts = {name: str(destination / path.name) for name, path in source_files.items()}
        metadata = {"module": task.name, "kind": task.kind, "fingerprint": fp, "digest": publication_id,
                    "synthetic": self.backend.synthetic, "metrics": published_metrics,
                    "search_metrics": search_metrics, "children": {n: c["digest"] for n, c in children.items()},
                    "artifacts": artifacts, "artifact_hashes": hashes}
        if destination.exists():
            try:
                metadata_matches = json.loads((destination / "publication.json").read_text()) == metadata
            except (OSError, ValueError):
                metadata_matches = False
            files_match = all((destination / path.name).is_file() and
                              file_digest(destination / path.name) == hashes[name] for name, path in source_files.items())
            if not metadata_matches or not files_match:
                # Reconstruct a damaged cache from verified stage checkpoints;
                # retain the damaged files for diagnosis, never trust new hashes.
                quarantine = destination.with_name("." + publication_id + ".corrupt-" + str(time.time_ns()))
                os.rename(destination, quarantine)
                sync_directory(destination.parent)
                self.notify("publication_cache_repaired", task=task.name, quarantined=str(quarantine))
        if not destination.exists():
            if staging.exists():
                shutil.rmtree(staging)
            staging.mkdir(parents=True)
            for name, path in source_files.items():
                target = staging / path.name
                shutil.copyfile(path, target)
                with target.open("rb") as f:
                    os.fsync(f.fileno())
                require(file_digest(target) == hashes[name], f"Publication copy mismatch: {name}")
            atomic_json(staging / "publication.json", metadata)
            sync_directory(staging)
            self.notify("publication_staged", task=task.name)
            os.rename(staging, destination)
            sync_directory(destination.parent)
        else:
            require(json.loads((destination / "publication.json").read_text()) == metadata,
                    "Existing publication does not match recovered attempt")
        metadata["checksums"] = snapshot([Path(p) for p in artifacts.values()] + [destination / "publication.json"])
        self.notify("publication_renamed", task=task.name)
        old = self.state.get("tasks", task.name)
        old.update(status="done", published=metadata, fingerprint=fp, error=None)
        self.state.put("tasks", task.name, old)
        self.notify("publication_committed", task=task.name, digest=publication_id)
        return metadata

    def run_task(self, task):
        try:
            children = {n: self.state.get("tasks", n)["published"] for n in task.dependencies}
            for child in children.values():
                require(self.published_valid(child), "Invalid/unpublished child macro")
            fp = digest([self.base[task.name], {n: c["digest"] for n, c in children.items()}])
            current = self.state.get("tasks", task.name)
            current.update(status="running", fingerprint=fp, error=None)
            self.state.put("tasks", task.name, current)
            point = self.restore_sweep(task, fp)
            LOG.info("%s: continuing %s iteration %d @ %.1f ps; stage %s; hold margin %.3f ps; hold buffer budget %d%%",
                     self.task_label(task.name), point["mode"], point["index"] + 1,
                     point["period_ps"], point["phase"], point["hold_slack_margin_ps"], point["hold_max_buffer_percent"])
            self.save_sweep(task, point)
            while True:
                mode, index, period = point["mode"], point["index"], point["period_ps"]
                try:
                    job, metrics, completed = self.attempt(task, fp, mode, index, period, children,
                                                          hold_margin=point["hold_slack_margin_ps"],
                                                          hold_max_buffer_percent=point["hold_max_buffer_percent"])
                except FlowError as exc:
                    if exc.category != "hold_buffer_limit" or point["hold_max_buffer_percent"] >= 100 or self.stop.is_set():
                        raise
                    # A looser budget accepts earlier completed stages. Retry
                    # only the failed stage at this same period, never a faster
                    # period or a different task. Preserve the failed tool log.
                    old_log = Path(exc.details["log"])
                    archived = old_log.with_name(old_log.stem + f'.buffer-cap-{point["hold_max_buffer_percent"]}.log')
                    shutil.copyfile(old_log, archived)
                    following = dict(point, hold_max_buffer_percent=100, phase=exc.details["phase"])
                    self.save_sweep(task, following)
                    self.notify("hold_buffer_budget_retry", task=task.name, mode=mode, index=index,
                                period_ps=period, previous_percent=point["hold_max_buffer_percent"],
                                next_percent=100, phase=exc.details["phase"], previous_log=str(archived))
                    LOG.warning("%s: hold buffer cap reached at %.1f ps in %s; increasing %d%% -> 100%% and retrying",
                                self.task_label(task.name), period, exc.details["phase"], point["hold_max_buffer_percent"])
                    point = following
                    continue
                if mode == "search":
                    self.notify("search_result", task=task.name, period=period, ratio=metrics["ratio"])
                    LOG.info("%s search %s: target %.1f ps, effective %.3f ps, ratio %.5f",
                             self.task_label(task.name), index, period, metrics["effective_min_period_ps"], metrics["ratio"])
                elif timing_pass(metrics):
                    self.execute_stage(job, "abstract", job["attempt_key"] + "/abstract", completed)
                    self.mark_sweep_phase(job, "publish")
                    return self.publish(job, fp, metrics, point["search_metrics"], children)
                following = self.advance_sweep(task, point, metrics)
                # Commit the next chosen constraint before any interruption or
                # process can leave this point without a durable resume cursor.
                self.save_sweep(task, following)
                if mode == "publish":
                    self.notify("publication_retry", task=task.name, period_ps=period,
                                hold_slack_margin_ps=point["hold_slack_margin_ps"], next_period_ps=following["period_ps"],
                                next_hold_slack_margin_ps=following["hold_slack_margin_ps"],
                                setup_ws_ps=metrics["setup_ws_ps"], hold_ws_ps=metrics["hold_ws_ps"])
                    LOG.warning("%s publication %s failed setup/hold: %.3f/%.3f ps; "
                                "retry at %.1f ps with hold repair margin %.3f ps", self.task_label(task.name), index,
                                metrics["setup_ws_ps"], metrics["hold_ws_ps"], following["period_ps"], following["hold_slack_margin_ps"])
                point = following
        except Exception as exc:
            record = self.state.get("tasks", task.name)
            record.update(status="interrupted" if self.stop.is_set() else "failed", error=error_record(exc))
            self.state.put("tasks", task.name, record)
            self.notify("task_failed", task=task.name, error=record["error"])
            LOG.error("%s: %s", self.task_label(task.name), exc)
            return None

    def run(self, retry_failed=False):
        with WorkspaceLock(self.work / "workspace.lock") as lock:
            self.workspace_lock = lock
            atomic_json(self.work / "run_metadata.json", {"synthetic": self.backend.synthetic,
                        "task_model": "pe_sa_top_inline_sram", "task_count": len(self.graph.tasks),
                        "configuration": self.config, "backend_identity": self.backend.identity,
                        "source_manifest": str(self.graph.path), "source_manifest_sha256": file_digest(self.graph.path)})
            self.prepare(retry_failed)
            schedule = TaskSchedule(self.graph.tasks, {n: self.state.get("tasks", n)["status"]
                                                      for n in self.graph.tasks})
            previous = {}
            if threading.current_thread() is threading.main_thread():
                for signum in (signal.SIGINT, signal.SIGTERM):
                    previous[signum] = signal.signal(signum, lambda *_: self.stop.set())
            try:
                with ThreadPoolExecutor(max_workers=self.config["workers"], thread_name_prefix="hard-macro") as pool:
                    futures = {}
                    reports_dirty = False
                    while True:
                        for name, failed in schedule.blocked:
                            record = self.state.get("tasks", name)
                            record.update(status="blocked", error={"category": "dependency", "children": failed})
                            self.state.put("tasks", name, record)
                        schedule.blocked.clear()
                        if not self.stop.is_set():
                            while len(futures) < self.config["workers"]:
                                name = schedule.pop_ready()
                                if name is None:
                                    break
                                record = self.state.get("tasks", name)
                                record["status"] = "running"
                                self.state.put("tasks", name, record)
                                LOG.info("%s: scheduled (%s); active tasks %d/%d", self.task_label(name),
                                         self.graph.tasks[name].kind, len(futures) + 1, self.config["workers"])
                                futures[pool.submit(self.run_task, self.graph.tasks[name])] = name
                        # Refill free workers before the potentially expensive
                        # report pass. No layer/batch barrier is introduced.
                        if reports_dirty:
                            self.reports()
                            reports_dirty = False
                        if not futures:
                            pending = [n for n, status in schedule.statuses.items() if status == "pending"]
                            require(not pending or self.stop.is_set(), "No runnable tasks: cyclic or invalid dependencies")
                            break
                        done, _ = wait(futures, timeout=.1, return_when=FIRST_COMPLETED)
                        for future in done:
                            name = futures.pop(future)
                            future.result()
                            status = self.state.get("tasks", name)["status"]
                            schedule.complete(name, status)
                            LOG.info("%s: %s", self.task_label(name), status)
                            reports_dirty = True
                self.reports()
                return 0 if all(self.state.get("tasks", n)["status"] == "done" for n in self.graph.tasks) else (130 if self.stop.is_set() else 1)
            finally:
                for signum, handler in previous.items():
                    signal.signal(signum, handler)

    def reports(self):
        rows = []
        for name, task in self.graph.tasks.items():
            state = self.state.get("tasks", name) or {"status": "not_started"}
            pub = state.get("published") if state["status"] == "done" else None
            row = {"module": name, "kind": task.kind, "status": state["status"], "synthetic": self.backend.synthetic,
                   "io_budget_fraction": self.config["io_budget_fraction"],
                   "progress": state.get("progress"),
                   "error": state.get("error"), "metrics": pub["metrics"] if pub else None,
                   "artifacts": pub["artifacts"] if pub else None, "children": pub["children"] if pub else None,
                   "attempts": [a for a in self.state.all("attempts") if a["task"] == name and a["fingerprint"] == state.get("fingerprint")]}
            rows.append(row)
            atomic_json(self.work / "reports" / (name + ".json"), row)
        atomic_json(self.work / "reports/summary.json", {"synthetic": self.backend.synthetic,
                    "task_model": "pe_sa_top_inline_sram", "task_count": len(rows),
                    "configuration": self.config, "backend_identity_digest": digest(self.backend.identity), "tasks": rows})
        fields = ("module", "kind", "status", "synthetic", "target_period_ps", "sta_min_period_ps", "effective_min_period_ps",
                  "validated_frequency_hz", "estimated_frequency_hz", "setup_ws_ps", "hold_ws_ps", "setup_tns_ps", "hold_tns_ps",
                  "hold_slack_margin_ps",
                  "hold_max_buffer_percent",
                  "standard_cell_area_um2", "macro_area_um2", "core_area_um2", "die_area_um2", "hierarchical_standard_cell_area_um2")
        buffer = io.StringIO()
        writer = csv.DictWriter(buffer, fieldnames=fields, lineterminator="\n")
        writer.writeheader()
        md = ["# " + ("SIMULATED TEST DATA — " if self.backend.synthetic else "") + "Hierarchical OpenROAD results", "",
              "| Module | State | Validated GHz | Estimated GHz | Stdcell μm² (recursive) |", "| --- | --- | ---: | ---: | ---: |"]
        for row in rows:
            flat = {**(row["metrics"] or {}), **{k: row[k] for k in ("module", "kind", "status", "synthetic")}}
            writer.writerow({k: flat.get(k) for k in fields})
            m = row["metrics"]
            md.append(f"| `{row['module']}` | {row['status']} | " +
                      (f"{m['validated_frequency_hz']/1e9:.6f} | {m['estimated_frequency_hz']/1e9:.6f} | {m['hierarchical_standard_cell_area_um2']:.3f} |" if m else "— | — | — |"))
            atomic_write(self.work / "reports" / (row["module"] + ".md"), report_markdown(row))
        atomic_write(self.work / "reports/summary.csv", buffer.getvalue())
        atomic_write(self.work / "reports/summary.md", "\n".join(md) + "\n")


def error_record(exc):
    return {"category": getattr(exc, "category", "internal"), "message": str(exc),
            **getattr(exc, "details", {})}


def report_markdown(row):
    lines = ["# " + row["module"], "", *( ["**SIMULATED TEST DATA**", ""] if row["synthetic"] else []),
             f"State: **{row['status']}**", "",
             f"ASAP7 BC/RVT; data I/O maximum delays: {row.get('io_budget_fraction', .2):.0%} of the target cycle.", ""]
    if row["metrics"]:
        lines += ["| Metric | Value |", "| --- | ---: |"]
        for name, key, scale in (
            ("Validated operating frequency (GHz)", "validated_frequency_hz", 1e-9),
            ("Published implementation limit estimate (GHz)", "estimated_frequency_hz", 1e-9),
            ("Validated cycle (ps)", "validated_period_ps", 1),
            ("STA minimum cycle (ps)", "sta_min_period_ps", 1),
            ("Effective minimum cycle including children (ps)", "effective_min_period_ps", 1),
            ("Child cycle limit (ps)", "child_period_limit_ps", 1),
            ("Setup worst slack (ps)", "setup_ws_ps", 1), ("Hold worst slack (ps)", "hold_ws_ps", 1),
            ("Setup TNS (ps)", "setup_tns_ps", 1), ("Hold TNS (ps)", "hold_tns_ps", 1),
            ("Local standard-cell area (μm²)", "standard_cell_area_um2", 1),
            ("Direct macro footprint (μm²)", "macro_area_um2", 1),
            ("Recursive standard-cell area (μm²)", "hierarchical_standard_cell_area_um2", 1),
            ("Core area (μm²)", "core_area_um2", 1), ("Die area (μm²)", "die_area_um2", 1),
            ("Detailed routing DRC errors", "drc_errors", 1)):
            lines.append(f"| {name} | {row['metrics'][key] * scale:.6f} |")
        lines += ["", "Electrical violations are reported separately; see the JSON metrics. This is not foundry signoff.", ""]
    if row["attempts"]:
        lines += ["## Frequency history", "", "| Mode/index | Target ps | Effective min ps | Ratio | Hold repair margin ps | Hold buffer budget % | Timing pass | State |",
                  "| --- | ---: | ---: | ---: | ---: | ---: | --- | --- |"]
        for attempt in sorted(row["attempts"], key=lambda a: (a["mode"] == "publish", a["index"])):
            metrics = attempt.get("metrics")
            timing = f"{metrics['effective_min_period_ps']:.3f} | {metrics['ratio']:.5f}" if metrics else "— | —"
            hold_margin = attempt.get("hold_slack_margin_ps", "—")
            buffer_budget = attempt.get("hold_max_buffer_percent", "—")
            passed = attempt.get("timing_pass", "—")
            lines.append(f"| {attempt['mode']}/{attempt['index']} | {attempt['period_ps']:.3f} | {timing} | {hold_margin} | {buffer_budget} | {passed} | {attempt['status']} |")
    if row["artifacts"]:
        lines += ["", "## Artifacts", ""]
        lines += [f"- [{name}](<{path}>)" for name, path in sorted(row["artifacts"].items())]
    if row["error"]:
        lines += ["", "## Error", "", "```json", json.dumps(row["error"], indent=2), "```"]
    return "\n".join(lines) + "\n"


def positive_workers(value):
    try:
        number = int(value)
    except ValueError:
        raise argparse.ArgumentTypeError("worker count must be a positive integer")
    if number <= 0:
        raise argparse.ArgumentTypeError("worker count must be a positive integer")
    return number


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--status", action="store_true")
    parser.add_argument("--retry-failed", action="store_true")
    parser.add_argument("--config", type=Path, default=DEFAULT_CONFIG)
    parser.add_argument("-j", "--workers", type=positive_workers, metavar="N",
                        help="concurrent module tasks (default: workers in config, normally 2)")
    parser.add_argument("--work-dir", type=Path, default=ROOT / "build/hierarchical_openroad")
    parser.add_argument("--layout-file", nargs=2, metavar=("REQUEST_JSON", "OUTPUT_TCL"), help=argparse.SUPPRESS)
    args = parser.parse_args(argv)
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
    engine = None
    try:
        if args.layout_file:
            emit_layout(*args.layout_file)
            return 0
        if args.status:
            path = args.work_dir / "state.sqlite3"
            if not path.exists():
                print("No execution state; dry run does not start tasks.")
                return 0
            db = sqlite3.connect(f"file:{path.resolve()}?mode=ro", uri=True)
            try:
                rows = list(db.execute("SELECT data FROM tasks ORDER BY name"))
                if not rows:
                    print("No execution tasks; only dry-run metadata exists.")
                legacy_sram = 0
                for (data,) in rows:
                    item = json.loads(data)
                    if item.get("kind") == "sram":
                        legacy_sram += 1
                        continue
                    print(item["status"], item["name"], canonical(item.get("error")))
                    point = item.get("progress")
                    if point:
                        print("  checkpoint", point["mode"], "iteration=", point["index"] + 1,
                              "period_ps=", point["period_ps"], "phase=", point["phase"],
                              "hold_margin_ps=", point["hold_slack_margin_ps"],
                              "hold_buffer_percent=", point.get("hold_max_buffer_percent", "default"))
                if legacy_sram:
                    print(f"{legacy_sram} legacy standalone SRAM tasks excluded; archived on the next run.")
                for (data,) in db.execute("SELECT data FROM stages"):
                    stage = json.loads(data)
                    if stage["status"] == "running":
                        print("backend", stage["task"], stage["phase"], "pid=", stage.get("pid"), "log=", stage.get("log"))
            finally:
                db.close()
            return 0
        for path in (ROOT, args.work_dir.resolve()):
            require(not any(c.isspace() or c in "#$" for c in str(path)), "Makefile workspace paths cannot contain whitespace, # or $")
        config = load_config(args.config)
        if args.workers is not None:
            config["workers"] = args.workers
        graph = Graph(ROOT / "staticsrc/manifest.json")
        backend = NativeBackend(load_environment())
        engine = Engine(graph, args.work_dir, config, backend)
        if args.dry_run:
            with WorkspaceLock(engine.work / "workspace.lock"):
                plan = engine.dry_run()
            print(f"DRY RUN: {len(plan['tasks'])} tasks, {plan['workers']} workers, no backend executed. {engine.work / 'dry_run/plan.json'}")
            return 0
        return engine.run(args.retry_failed)
    except (FlowError, OSError, ValueError, subprocess.SubprocessError, sqlite3.Error) as exc:
        LOG.error("%s", exc)
        return 2
    finally:
        if engine:
            engine.close()


if __name__ == "__main__":
    sys.exit(main())
