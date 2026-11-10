"""No EDA processes: synthetic subprocess tests, including SIGKILL recovery.

python3 -m unittest discover -s tools -p 'test_hierarchical_openroad.py' -v
"""
from __future__ import annotations

from collections import Counter
import fcntl
import json
import io
import os
from pathlib import Path
import signal
import sqlite3
import subprocess
import sys
import tempfile
import time
import unittest
from contextlib import redirect_stderr, redirect_stdout
from unittest.mock import patch

import run_hierarchical_openroad as h
from hierarchical_openroad_support import (FlowError, atomic_json, atomic_write, canonical,
    check_placements, digest, expected_pins, layout_plan, macro_name, validate_views, wrappers)


TEST_FILE = Path(__file__).resolve()
BIT = {"kind": "basicdtype", "name": "logic", "signed": False}


def journal(path, data):
    with Path(path).open("a") as stream:
        fcntl.flock(stream, fcntl.LOCK_EX)
        stream.write(canonical({"time": time.time(), **data}) + "\n")
        stream.flush()
        os.fsync(stream.fileno())


class FakeBackend:
    synthetic = True

    def __init__(self, work):
        self.work = Path(work).resolve()
        self.flow = self.work / "NOT_A_REAL_ORFS"
        self.env = dict(os.environ)
        self.identity = {"backend": "SIMULATED TEST BACKEND v1"}

    def command(self, job, phase, completed_outputs):
        # Fail immediately if a parent could start without a committed view.
        for child in job["children"].values():
            if "checksums" in child:
                if not h.snapshot_valid(child["checksums"]):
                    raise AssertionError("Unpublished child used by fake parent")
        description = job["inputs"] / "fake_job.json"
        atomic_json(description, {"task": job["task"].record, "kind": job["task"].kind,
                    "dependencies": dict(job["task"].dependencies), "period": job["period"],
                    "hold_slack_margin_ps": job["hold_slack_margin_ps"],
                    "hold_max_buffer_percent": job["hold_max_buffer_percent"],
                    "directory": str(job["directory"]), "work": str(self.work)})
        return [sys.executable, "-S", str(TEST_FILE), "_fake-stage", str(description), phase]


def fake_stage(description, phase):
    data = json.loads(Path(description).read_text())
    work, directory = Path(data["work"]), Path(data["directory"])
    control_path = work / "control.json"
    control = json.loads(control_path.read_text()) if control_path.exists() else {}
    task = h.Task(data["task"], data["kind"], Counter(data["dependencies"]), [])
    job = {"task": task, "run": directory / "run"}
    paths = h.result_paths(job)
    for path in paths.values():
        path.mkdir(parents=True, exist_ok=True)
    event = {"task": task.name, "phase": phase, "attempt": directory.name, "pid": os.getpid(),
             "hold_slack_margin_ps": data["hold_slack_margin_ps"],
             "hold_max_buffer_percent": data["hold_max_buffer_percent"]}
    journal(work / "journal.jsonl", {**event, "event": "start"})
    atomic_write(work / ("started-" + task.name), "SIMULATED TASK STARTED\n")
    wait_for = control.get("wait_for_task", {})
    if wait_for.get("task") == task.name and wait_for.get("phase") == phase:
        deadline = time.monotonic() + 10
        while not (work / ("started-" + wait_for["until"])).exists():
            if time.monotonic() >= deadline:
                print("SIMULATED SCHEDULER STALLED: ready parent did not start", flush=True)
                return 8
            time.sleep(.01)
    outputs = h.phase_outputs(job, phase)
    if (phase == control.get("buffer_cap_phase", "cts")
            and data["hold_max_buffer_percent"] < control.get("required_buffer_percent", 0)):
        print("[ERROR RSZ-0060] Max buffer count reached.", flush=True)
        return 6
    if (control.get("sleep_task") == task.name and control.get("sleep_phase") == phase
            and directory.name.startswith(control.get("sleep_attempt", ""))):
        marker = work / "sleep_consumed"
        if not marker.exists():
            atomic_write(outputs[0], "SIMULATED PARTIAL WRITE\n")
            atomic_write(marker, str(os.getpid()))
            while True:
                time.sleep(.1)
    if (control.get("fail_task") == task.name and control.get("fail_phase") == phase
            and directory.name.startswith(control.get("fail_attempt", ""))):
        marker = work / "failure_consumed"
        if not control.get("fail_once") or not marker.exists():
            atomic_write(marker, "failed\n")
            print("SIMULATED TOOL FAILURE", flush=True)
            return 7
    time.sleep(.015)
    for path in outputs:
        if not (control.get("missing_task") == task.name and control.get("missing_phase") == phase and path == outputs[-1]):
            atomic_write(path, "SIMULATED ARTIFACT " + task.name + " " + phase + "\n")
    if phase == "floorplan":
        atomic_write(job["run"] / "layout.tcl", "# SIMULATED LAYOUT\n")
        atomic_json(job["run"] / "layout.json", {"synthetic": True, "placements": []})
    if phase in ("route", "finish"):
        atomic_json(paths["logs"] / "5_2_route.json", {"detailedroute__route__drc_errors": control.get("drc_errors", 0)})
    if phase == "finish":
        actual = control.get("actual_period_ps", 900.0)
        slack = data["period"] - actual
        hold = control.get("hold_slack", 10)
        if "hold_required_margin_ps" in control:
            hold = data["hold_slack_margin_ps"] - control["hold_required_margin_ps"]
        atomic_json(paths["logs"] / "6_report.json", {
            "finish__timing__fmax": 1e12 / actual,
            "finish__timing__setup__ws": slack, "finish__timing__hold__ws": hold,
            "finish__timing__setup__tns": min(0, slack), "finish__timing__hold__tns": min(0, hold),
            "finish__design__instance__area__stdcell": 10.0,
            "finish__design__instance__area__macros": 100.0 * sum(task.dependencies.values()),
            "finish__design__core__area": 200.0 * (sum(task.dependencies.values()) + 1),
            "finish__design__die__area": 210.0 * (sum(task.dependencies.values()) + 1),
            "finish__timing__drv__max_slew": 2})
        atomic_json(job["run"] / "hierarchy_checks.json", {
            "macro_counts": {macro_name(n): count for n, count in task.dependencies.items()},
            "unrouted_nets": 0, "power_connected": True})
    if phase == "abstract":
        pins = sorted(expected_pins(task.record))
        lef = "# SIMULATED TEST VIEW\nMACRO " + task.hard + "\n SIZE 10 BY 10 ;\n"
        lef += "".join(" PIN " + pin + "\n END " + pin + "\n" for pin in pins + ["VDD", "VSS"])
        lef += "END " + task.hard + "\n"
        lib = '/* SIMULATED TEST VIEW */\nlibrary(fake) { cell("' + task.hard + '") {\n'
        lib += "".join(' pin("' + pin + '") { ' + ('clock : true;' if pin == "clk" else '') + ' }\n' for pin in pins)
        lib += "} }\n"
        atomic_write(outputs[0], lef)
        atomic_write(outputs[1], lib)
    journal(work / "journal.jsonl", {**event, "event": "end"})
    return 0


def make_fixture(root, extra_roots=0):
    root = Path(root)
    source = root / "fixture_src"
    source.mkdir()
    ports = [{"name": n, "direction": d, "type": BIT} for n, d in
             (("clk", "input"), ("rst_n", "input"), ("d", "input"), ("q", "output"))]
    # The artificial extra PE level stresses generic DAG depth in mock tests.
    specs = [
        ("ram_a", "sram2r1w", [], {"SIZE": 8, "WIDTH": 1}),
        ("ram_b", "sram1r1w", [], {"SIZE": 8, "WIDTH": 1}),
        ("pe_leaf_a", "pe", [("ram_a", 1)], {"SIZE": 8, "WIDTH": 1}),
        ("pe_leaf_b", "pe", [("ram_b", 1)], {"SIZE": 8, "WIDTH": 1}),
        ("pe__fixture", "pe", [("pe_leaf_a", 1)], {}),
        ("sa__fixture", "sa", [("pe__fixture", 1)], {"SUBTILE_M": 1, "SUBTILE_N": 1}),
        ("top_fixture", "top_static", [("sa__fixture", 1), ("pe_leaf_b", 2)], {"SUBTILE_M": 1, "SUBTILE_N": 1}),
    ]
    specs += [(f"pe_extra_{index}", "pe", [], {"SIZE": 8, "WIDTH": 1})
              for index in range(extra_roots)]
    modules = []
    for name, original, children, parameters in specs:
        file = name + ".sv"
        (source / file).write_text(f"// SIMULATED FIXTURE\nmodule {name}(input logic clk,rst_n,d,output logic q); assign q=d; endmodule\n")
        modules.append({"name": name, "original_module": original, "file": file, "ports": ports,
                        "children": [{"module": n, "count": c} for n, c in children],
                        "parameters": {n: {"value": v} for n, v in parameters.items()}})
    atomic_json(source / "manifest.json", {"modules": modules, "packages": []})
    return source / "manifest.json"


def coordinator(work, manifest):
    work = Path(work)
    control_path = work / "control.json"
    control = json.loads(control_path.read_text()) if control_path.exists() else {}
    config = h.load_config()
    config.update(control.get("config", {}))
    graph = h.Graph(manifest, expected=False)
    def checkpoint(event, payload):
        if (event == control.get("kill_event") and payload.get("task") == control.get("kill_task")
                and (not control.get("kill_phase") or payload.get("phase") == control.get("kill_phase"))
                and (not control.get("kill_mode") or payload.get("mode") == control["kill_mode"])
                and ("kill_index" not in control or payload.get("index") == control["kill_index"])):
            marker = work / "kill_consumed"
            if not marker.exists():
                atomic_write(marker, event)
                os.kill(os.getpid(), signal.SIGKILL)
    engine = h.Engine(graph, work, config, FakeBackend(work), checkpoint)
    try:
        return engine.run(retry_failed=control.get("retry_failed", False))
    except FlowError as exc:
        print(str(exc), flush=True)
        return 2
    finally:
        engine.close()


class PureFunctions(unittest.TestCase):
    def test_hold_buffer_budget_config(self):
        self.assertEqual(h.load_config()["hold_max_buffer_percent"], 100)
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / 'config.json'
            for value in (0, -1, 101, True, 100.5, "100", None):
                with self.subTest(value=value):
                    atomic_json(path, {"hold_max_buffer_percent": value})
                    with self.assertRaises(FlowError):
                        h.load_config(path)
            for value in (1, 20, 100):
                atomic_json(path, {"hold_max_buffer_percent": value})
                self.assertEqual(h.load_config(path)["hold_max_buffer_percent"], value)

    def test_sweep_cursors_are_durable_independent_and_fingerprint_scoped(self):
        with tempfile.TemporaryDirectory(prefix="SIMULATED-sweep-cursor-") as tmp:
            root = Path(tmp)
            graph = h.Graph(make_fixture(root), expected=False)
            work = root / "work"
            engine = h.Engine(graph, work, h.load_config(), FakeBackend(work))
            try:
                engine.prepare(False)
                for name, period in (("pe_leaf_a", 700), ("pe_leaf_b", 850)):
                    point = engine.sweep_point(graph.tasks[name], name + "-fp", index=2, period=period)
                    engine.save_sweep(graph.tasks[name], dict(point, phase="route"))
            finally:
                engine.close()
            engine = h.Engine(graph, work, h.load_config(), FakeBackend(work))
            try:
                with patch.object(subprocess, "Popen", side_effect=AssertionError("backend invoked")):
                    for name, period in (("pe_leaf_a", 700), ("pe_leaf_b", 850)):
                        point = engine.restore_sweep(graph.tasks[name], name + "-fp")
                        self.assertEqual((point["index"], point["period_ps"], point["phase"]), (2, period, "route"))
                    fresh = engine.restore_sweep(graph.tasks["pe_leaf_a"], "changed-fp")
                    self.assertEqual((fresh["index"], fresh["period_ps"]), (0, 1000))
            finally:
                engine.close()

    def test_hold_margin_config_and_publication_retry(self):
        with tempfile.TemporaryDirectory() as tmp:
            config = Path(tmp) / "config.json"
            for key, values in (("hold_slack_margin_ps", (-1, True, "5", float("nan"))),
                                ("hold_retry_margin_step_ps", (0, -1, True, "5", float("inf")))):
                for value in values:
                    with self.subTest(key=key, value=value):
                        config.write_text(json.dumps({key: value}))
                        with self.assertRaises(FlowError):
                            h.load_config(config)
        cfg = h.load_config()
        metrics = {"setup_ws_ps": 10, "setup_tns_ps": 0, "hold_ws_ps": -3,
                   "hold_tns_ps": -7, "effective_min_period_ps": 208, "child_period_limit_ps": 0}
        period, margin = h.publication_next(metrics, 224.9, 5, cfg)
        self.assertEqual((period, margin), (224.9, 10))
        # Setup-only repair changes period; hold-only repair changes margin.
        setup = dict(metrics, setup_ws_ps=-2, setup_tns_ps=-2, hold_ws_ps=1,
                     hold_tns_ps=0, effective_min_period_ps=230)
        period, margin = h.publication_next(setup, 224.9, 5, cfg)
        self.assertGreater(period, 224.9)
        self.assertEqual(margin, 5)
        both = dict(setup, hold_ws_ps=-12, hold_tns_ps=-12)
        self.assertEqual(h.publication_next(both, 224.9, 5, cfg), (period, 17))
        # A dependency's slower verified clock is respected even with good slack.
        limited = dict(metrics, hold_ws_ps=1, hold_tns_ps=0,
                       child_period_limit_ps=250, effective_min_period_ps=250)
        self.assertGreaterEqual(h.publication_next(limited, 224.9, 5, cfg)[0], 250)

    def test_worker_config_and_cli(self):
        with tempfile.TemporaryDirectory(prefix="SIMULATED-worker-cli-") as tmp:
            root = Path(tmp)
            config = root / "config.json"
            for value in (0, -1, True, 1.5):
                with self.subTest(invalid=value):
                    atomic_json(config, {"workers": value})
                    with self.assertRaises(FlowError):
                        h.load_config(config)
            atomic_json(config, {"workers": 4})
            self.assertEqual(h.load_config(config)["workers"], 4)
            for arguments, expected in (([], 4), (["-j", "3"], 3), (["-j1"], 1)):
                with self.subTest(arguments=arguments), \
                        patch.object(h, "load_environment", return_value={}), \
                        patch.object(h, "NativeBackend", return_value=FakeBackend(root)), \
                        patch.object(subprocess, "Popen", side_effect=AssertionError("backend invoked")), \
                        redirect_stdout(io.StringIO()) as output:
                    work = root / str(expected)
                    self.assertEqual(h.main(["--dry-run", "--work-dir", str(work),
                                             "--config", str(config), *arguments]), 0)
                    plan = json.loads((work / "dry_run/plan.json").read_text())
                    self.assertEqual(plan["workers"], expected)
                    self.assertIn(f"{expected} workers", output.getvalue())
            for value in ("0", "-2", "1.5"):
                with self.subTest(cli_invalid=value), redirect_stderr(io.StringIO()):
                    with self.assertRaises(SystemExit) as error:
                        h.main(["-j", value, "--dry-run"])
                    self.assertEqual(error.exception.code, 2)

    def test_ready_queue_releases_parents_without_layer_barrier(self):
        with tempfile.TemporaryDirectory() as tmp:
            graph = h.Graph(make_fixture(tmp), expected=False)
            tasks = graph.tasks
            schedule = h.TaskSchedule(tasks, {name: "pending" for name in tasks})
            self.assertEqual([schedule.pop_ready(), schedule.pop_ready()], ["pe_leaf_a", "pe_leaf_b"])
            schedule.complete("pe_leaf_a", "done")
            self.assertEqual(schedule.pop_ready(), "pe__fixture")
            schedule.complete("pe__fixture", "done")
            self.assertEqual(schedule.pop_ready(), "sa__fixture")
            schedule.complete("sa__fixture", "done")
            self.assertIsNone(schedule.pop_ready())  # Shared top still needs B.
            schedule.complete("pe_leaf_b", "done")
            self.assertEqual(schedule.pop_ready(), "top_fixture")
            self.assertIsNone(schedule.pop_ready())
            # Initial failures propagate transitively before anything starts.
            statuses = {name: "pending" for name in tasks}
            statuses["pe_leaf_a"] = "failed"
            failed = h.TaskSchedule(tasks, statuses)
            self.assertEqual({name for name, _ in failed.blocked},
                             {"pe__fixture", "sa__fixture", "top_fixture"})
            self.assertEqual(failed.pop_ready(), "pe_leaf_b")
            tasks["pe_leaf_a"].dependencies["top_fixture"] = 1
            with self.assertRaisesRegex(FlowError, "Cyclic"):
                h.TaskSchedule(tasks, statuses)

    def test_sweep_boundaries_direction_and_stagnation(self):
        cfg = h.load_config()
        for ratio in (1, 1.05, 1.1):
            self.assertIsNone(h.search_next({"effective_min_period_ps": ratio * 1000}, 1000, cfg))
        self.assertLess(h.search_next({"effective_min_period_ps": 800}, 1000, cfg), 1000)
        self.assertGreater(h.search_next({"effective_min_period_ps": 1400}, 1000, cfg), 1000)
        with self.assertRaisesRegex(FlowError, "stagnated"):
            h.search_next({"effective_min_period_ps": 800}, 1000, dict(cfg, period_quantum_ps=1000))
        base = {"setup_ws_ps": 0, "hold_ws_ps": 0, "setup_tns_ps": 0, "hold_tns_ps": 0,
                "target_period_ps": 1000, "child_period_limit_ps": 1000}
        self.assertTrue(h.timing_pass(base))
        self.assertFalse(h.timing_pass(dict(base, hold_ws_ps=-.01)))
        self.assertFalse(h.timing_pass(dict(base, child_period_limit_ps=1001)))

    def test_native_fingerprint_ignores_python_caches_not_source_changes(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            flow = root / "flow"
            for folder in ("scripts", "util", "platforms/asap7"):
                (flow / folder).mkdir(parents=True)
            (flow / "Makefile").write_text("# test flow\n")
            (flow / "scripts/variables.yaml").write_text("SKIP_DETAILED_ROUTE:\nFLOW_VARIANT:\n")
            source = flow / "scripts/real_source.py"
            source.write_text("# source version 1\n")
            for tool in ("openroad", "yosys", "klayout"):
                (root / tool).write_text("NOT EXECUTABLE: synthetic identity fixture\n")
            env = {"FLOW_HOME": str(flow), "OPENROAD_EXE": str(root / "openroad"),
                   "YOSYS_EXE": str(root / "yosys"), "KLAYOUT_CMD": str(root / "klayout"),
                   "SKIP_DETAILED_ROUTE": "1", "FLOW_VARIANT": "ambient"}
            with patch.object(subprocess, "Popen", side_effect=AssertionError("tool executed during fingerprinting")):
                before = h.NativeBackend(env)
                cache = flow / "scripts/__pycache__"
                cache.mkdir()
                (cache / "real_source.cpython-312.pyc").write_bytes(b"temporary cache")
                after = h.NativeBackend(env)
                self.assertEqual(before.identity, after.identity)
                source.write_text("# source version 2\n")
                self.assertNotEqual(after.identity, h.NativeBackend(env).identity)
            self.assertNotIn("SKIP_DETAILED_ROUTE", before.env)
            self.assertNotIn("FLOW_VARIANT", before.env)

    def test_markdown_uses_recorded_io_budget(self):
        row = {"module": "sample", "status": "pending", "synthetic": False, "metrics": None,
               "attempts": [], "artifacts": None, "error": None, "io_budget_fraction": .1}
        self.assertIn("10%", h.report_markdown(row))

    def test_real_dag_dry_run_without_backend_execution(self):
        graph = h.Graph(h.ROOT / "staticsrc/manifest.json")
        with tempfile.TemporaryDirectory() as tmp:
            engine = h.Engine(graph, tmp, h.load_config(), FakeBackend(tmp))
            try:
                with patch.object(subprocess, "Popen", side_effect=AssertionError("backend invoked")):
                    plan = engine.dry_run()
                self.assertEqual(Counter(t["kind"] for t in plan["tasks"]), {"pe": 3, "sa": 3, "top": 6})
                self.assertFalse(plan["backend_executed"])
                for task in plan["tasks"]:
                    text = (Path(task["inputs"]) / "config.mk").read_text()
                    self.assertIn("SYNTH_MOCK_LARGE_MEMORIES = 0", text)
                    self.assertIn("NUM_CORES = 1", text)
                    self.assertIn("HOLD_SLACK_MARGIN = 5.0", text)
                    self.assertIn('export PRE_CTS_TCL = ', text)
                    self.assertIn('export PRE_GLOBAL_ROUTE_TCL = ', text)
                    self.assertIn('set ::hr_hold_max_buffer_percent {100}', (Path(task['inputs']) / 'settings.tcl').read_text())
                    settings = (Path(task["inputs"]) / "job.json").read_text()
                    self.assertEqual(json.loads(settings)["hold_slack_margin_ps"], 5)
                    self.assertEqual(len(task["commands"]), 7)
                    model = graph.tasks[task['name']]
                    memories = [n for n in model.inline if graph.records[n]['original_module'] in ('sram1r1w', 'sram2r1w')]
                    if model.kind in ('pe', 'top'):
                        self.assertEqual(len(memories), 1)
                        self.assertIn(graph.records[memories[0]]['file'], text)
                    for memory in memories:
                        self.assertFalse((Path(task['inputs']) / (memory + '.blackbox.sv')).exists())
                        frozen = Path(task['inputs']) / 'rtl' / graph.records[memory]['file']
                        self.assertEqual(frozen.read_bytes(), (graph.source_root / graph.records[memory]['file']).read_bytes())
                    if task['kind'] == 'pe':
                        self.assertEqual(task['dependencies'], {})
                        self.assertNotIn('SYNTH_BLACKBOXES', text)
                    if task["kind"] == "top":
                        kinds = Counter(graph.tasks[n].kind for n in task["dependencies"])
                        self.assertEqual(kinds, {"sa": 1})
                covered = {name for task in graph.tasks.values() for name in task.inline
                           if graph.records[name]['original_module'] in ('sram1r1w', 'sram2r1w')}
                expected = {name for name, record in graph.records.items()
                            if record['original_module'] in ('sram1r1w', 'sram2r1w')}
                self.assertEqual(covered, expected)
                self.assertEqual(len(covered), 6)
            finally:
                engine.close()

    def test_packing_map_all_real_interfaces(self):
        graph = h.Graph(h.ROOT / "staticsrc/manifest.json")
        for task in graph.tasks.values():
            wrapper, adapter, stub, mapping = wrappers(task.record)
            self.assertIn("module " + task.hard, wrapper)
            self.assertIn("module " + task.name, adapter)
            self.assertIn("blackbox", stub)
            for name, port in mapping.items():
                self.assertEqual([b["flat_bit"] for b in port["bits"]], list(range(port["width"])))
                self.assertEqual(len({b["rtl"] for b in port["bits"]}), port["width"])
            if task.kind == "pe":
                self.assertEqual(mapping["left_a_i"]["bits"][0]["rtl"], "left_a_i[0][0]")

    def test_layout_4096_pes_centered_sa_and_inlined_pe_storage(self):
        cfg = h.load_config()
        macros = [{"name": f"u.gen_pe_row[{r}].gen_pe_col[{c}].u_macro", "master": "pe__test__hard", "width_um": 10, "height_um": 12}
                  for r in range(64) for c in range(64)]
        req = {"kind": "sa", "rows": 64, "cols": 64, "config": cfg, "site_width_um": .054,
               "site_height_um": .27, "standard_cell_area_um2": 10000, "macros": macros}
        result = layout_plan(req)
        check_placements(result["placements"], result["core"])
        positions = {p["name"]: p for p in result["placements"]}
        self.assertGreater(positions[macros[0]["name"]]["y"], positions[macros[-1]["name"]]["y"])
        top_macros = [{"name": "u.array.u_macro", "master": "sa__test__hard", "width_um": 30, "height_um": 30}]
        top = layout_plan(dict(req, kind="top", rows=2, cols=2, macros=top_macros))
        self.assertEqual(len(top["placements"]), 1)
        check_placements(top["placements"], top["core"])
        placed = top['placements'][0]
        self.assertLess(abs(placed['x'] + 15 - (top['core'][0] + top['core'][2]) / 2), .1)
        self.assertLess(abs(placed['y'] + 15 - (top['core'][1] + top['core'][3]) / 2), .3)
        pe = layout_plan(dict(req, kind='pe', macros=[], standard_cell_area_um2=2000))
        self.assertEqual(pe['placements'], [])
        self.assertGreaterEqual((pe['core'][2] - pe['core'][0]) * (pe['core'][3] - pe['core'][1]), 4000)
        with self.assertRaises(FlowError):
            layout_plan(dict(req, kind='pe', macros=top_macros))

    def test_legacy_sram_tasks_are_archived_without_removing_artifacts(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            graph = h.Graph(make_fixture(root), expected=False)
            work = root / 'work'
            engine = h.Engine(graph, work, h.load_config(), FakeBackend(work))
            try:
                artifact = work / 'old-sram.lef'
                artifact.write_text('SIMULATED LEGACY VIEW\n')
                legacy = {'name': 'ram_a', 'kind': 'sram', 'status': 'failed', 'progress': {'period_ps': 1000}}
                engine.state.put('tasks', 'ram_a', legacy)
                engine.prepare(False)
                self.assertIsNone(engine.state.get('tasks', 'ram_a'))
                self.assertEqual(engine.state.get('retired_tasks', 'ram_a'), legacy)
                self.assertTrue(artifact.exists())
                self.assertEqual(len(engine.state.all('tasks')), len(graph.tasks))
            finally:
                engine.close()

    def test_tcl_hooks_parse_and_sdc_budget(self):
        # Tcl parses procedure bodies without loading or invoking OpenROAD.
        result = subprocess.run(["tclsh"], input=f"source {{{h.HOOKS}}}\nputs [hr_json_string {{a\"b}}]\n", text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout.strip()), 'a"b')
        task = next(t for t in h.Graph(h.ROOT / "staticsrc/manifest.json").tasks.values() if t.kind == "pe")
        sdc = h.make_sdc(task, 1000, h.load_config())
        self.assertIn("-period 1000.000000", sdc)
        self.assertIn("-max 200.000000", sdc)
        self.assertIn("set_case_analysis 1", sdc)

    def test_reset_sdc_executes_with_tcl_list_ports(self):
        # Exercise generated Tcl, including reset exclusion, without defining
        # commercial-tool collection helpers that OpenSTA does not implement.
        prelude = """
set ::reset_case none
proc get_ports {name} {return [list $name]}
proc all_inputs {args} {return $::fixture_inputs}
proc all_outputs {} {return {q}}
proc create_clock {args} {}
proc set_case_analysis {value ports} {set ::reset_case $value}
proc set_input_delay {args} {
    if {[lindex $args end] ne {data_a data_b}} {error {incorrect data inputs}}
}
proc set_output_delay {args} {}
proc set_driving_cell {args} {
    if {[lindex $args end] ne {data_a data_b}} {error {incorrect driving ports}}
}
proc set_load {args} {}
"""
        graph = h.Graph(h.ROOT / "staticsrc/manifest.json")
        for task in graph.tasks.values():
            with self.subTest(module=task.name):
                reset = any(port["name"] == "rst_n" for port in task.record["ports"])
                ports = "data_a rst_n data_b" if reset else "data_a data_b"
                result = subprocess.run(["tclsh"], input=prelude + f'\nset ::fixture_inputs {{{ports}}}\n'
                                        + h.make_sdc(task, 1000, h.load_config())
                                        + '\nputs "RESET=$reset_case DATA=$data_inputs"\n',
                                        text=True, capture_output=True)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stderr, "")
                self.assertIn(f"RESET={'1' if reset else 'none'} DATA=data_a data_b", result.stdout)

    def test_hold_retry_configuration_applies_to_all_task_kinds(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            graph = h.Graph(make_fixture(root), expected=False)
            config = dict(h.load_config(), hold_slack_margin_ps=10)
            for task in graph.tasks.values():
                with self.subTest(module=task.name, kind=task.kind):
                    children = {child: {"artifacts": {kind: str(root / (child + '.' + kind))
                                                      for kind in ('lef', 'lib', 'gds')}}
                                for child in task.dependencies}
                    job = h.build_inputs(graph, task, root / task.name, 1000, config,
                                         FakeBackend(root), children, synthetic=True, dry=True)
                    text = (job['inputs'] / 'config.mk').read_text()
                    self.assertIn('export HOLD_SLACK_MARGIN = 10', text)
                    self.assertEqual(job['hold_slack_margin_ps'], 10)
                    metadata = json.loads((job['inputs'] / 'job.json').read_text())
                    self.assertEqual(metadata['hold_slack_margin_ps'], 10)
                    self.assertEqual(metadata['hold_max_buffer_percent'], 100)
                    self.assertEqual(job['hold_max_buffer_percent'], 100)
                    self.assertIn('export PRE_CTS_TCL = ', text)
                    self.assertIn('export PRE_GLOBAL_ROUTE_TCL = ', text)
                    settings = (job['inputs'] / 'settings.tcl').read_text()
                    encoded = settings.split('binary decode hex ', 1)[1].split(']', 1)[0]
                    self.assertEqual(json.loads(bytes.fromhex(encoded))['hold_slack_margin_ps'], 10)

    def test_orfs_helper_receives_hold_repair_margin(self):
        # Parse the actual emitted Makefile and execute the installed ORFS
        # helper with a recorded (nonphysical) repair_timing command.
        flow = Path(os.environ.get("FLOW_HOME", Path.home() / "openroad/OpenROAD-flow-scripts/flow"))
        helper = flow / 'scripts/util.tcl'
        if not helper.is_file():
            self.skipTest("Local ORFS timing helper is unavailable")
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            graph = h.Graph(make_fixture(root), expected=False)
            config = dict(h.load_config(), hold_slack_margin_ps=10)
            job = h.build_inputs(graph, graph.tasks['pe_leaf_a'], root / 'attempt', 1000,
                                 config, FakeBackend(root), {}, synthetic=True)
            makefile = (job['inputs'] / 'config.mk').read_text()
            margin = next(line.split(' = ', 1)[1] for line in makefile.splitlines()
                          if line.startswith('export HOLD_SLACK_MARGIN = '))
            prelude = f"""
set ::env(REPORTS_DIR) {{{root}}}
source {{{helper}}}
proc append_env_var {{var name option takes_value}} {{
    upvar 1 $var args
    if {{[info exists ::env($name)]}} {{lappend args $option $::env($name)}}
}}
proc repair_timing {{args}} {{puts "REPAIR_ARGS=$args"}}
set ::env(HOLD_SLACK_MARGIN) {margin}
source {{{job['inputs'] / 'timing_repair.tcl'}}}
repair_timing_helper -hold
source {{{job['inputs'] / 'timing_repair.tcl'}}}
repair_timing_helper
"""
            result = subprocess.run(['tclsh'], input=prelude, text=True, capture_output=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stderr, '')
            self.assertIn('-hold_margin 10', result.stdout)
            calls = [line for line in result.stdout.splitlines() if line.startswith('REPAIR_ARGS=')]
            self.assertEqual(len(calls), 2)
            for line in calls:
                self.assertIn('-max_buffer_percent 100', line)
                self.assertEqual(line.count('-max_buffer_percent'), 1)

    def test_runtime_floorplan_bridge_with_mocked_opendb(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmp = Path(tmp)
            request, layout, checks = tmp / "request.json", tmp / "layout.tcl", tmp / "checks.json"
            # Real Tcl -> Python layout bridge, but no OpenROAD/OpenDB process.
            script = f"""
source {{{h.HOOKS}}}
namespace eval ord {{}}
proc ord::get_db {{}} {{return db}}
proc ord::get_db_block {{}} {{return block}}
proc db {{method}} {{return lib}}
proc lib {{method arg}} {{return site}}
proc site {{method}} {{if {{$method == "getWidth"}} {{return 54}}; return 270}}
proc block {{method}} {{
  switch $method {{getDbUnitsPerMicron {{return 1000}} getInsts {{return {{}}}} getCoreArea {{return core}}}}
}}
proc core {{method}} {{switch $method {{xMin {{return 0}} yMin {{return 0}} xMax {{return 10000}} yMax {{return 10000}}}}}}
proc design_is_routed {{}} {{return 1}}
set ::env(PLACE_SITE) asap7sc7p5t
set hr_kind pe
set hr_rows 1
set hr_cols 1
set hr_config_json {{{canonical(h.load_config())}}}
set hr_layout_request {{{request}}}
set hr_layout_file {{{layout}}}
set hr_check_file {{{checks}}}
set hr_python {{{sys.executable}}}
set hr_runner {{{Path(h.__file__)}}}
set hr_expected [dict create]
hr_floorplan
hr_place
hr_check 1
puts OK
"""
            result = subprocess.run(["tclsh"], input=script, text=True, capture_output=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stderr, "")
            self.assertIn("OK", result.stdout)
            self.assertEqual(json.loads(request.read_text())["macros"], [])
            self.assertTrue(json.loads(checks.read_text())["power_connected"])
            self.assertGreater(json.loads(layout.with_suffix(".json").read_text())["core"][2], 0)

    def test_damaged_publication_is_reconstructed_without_backend_rerun(self):
        with tempfile.TemporaryDirectory(prefix="SIMULATED-cache-repair-") as tmp:
            root = Path(tmp)
            manifest = make_fixture(root)
            graph = h.Graph(manifest, expected=False)
            graph.tasks = {"pe_leaf_a": graph.tasks["pe_leaf_a"]}
            work = root / "work"
            engine = h.Engine(graph, work, h.load_config(), FakeBackend(work))
            try:
                self.assertEqual(engine.run(), 0)
                pub = engine.state.get("tasks", "pe_leaf_a")["published"]
            finally:
                engine.close()
            before = (work / "journal.jsonl").read_text()
            Path(pub["artifacts"]["lef"]).write_text("DAMAGED")
            publication = Path(pub["artifacts"]["lef"]).parent / "publication.json"
            publication.write_text("{incomplete")
            engine = h.Engine(graph, work, h.load_config(), FakeBackend(work))
            try:
                self.assertEqual(engine.run(), 0)
                recovered = engine.state.get("tasks", "pe_leaf_a")["published"]
                self.assertTrue(engine.published_valid(recovered))
                self.assertEqual(recovered["digest"], pub["digest"])
            finally:
                engine.close()
            self.assertEqual((work / "journal.jsonl").read_text(), before)
            self.assertTrue(list(publication.parent.parent.glob(".*.corrupt-*")))


class SubprocessRecovery(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="SIMULATED-hard-macro-")
        self.root = Path(self.tmp.name)
        self.manifest = make_fixture(self.root)
        self.work = self.root / "work"
        self.work.mkdir()

    def tearDown(self):
        self.kill_old_backends()
        self.tmp.cleanup()

    def control(self, **values):
        atomic_json(self.work / "control.json", values)

    def launch(self):
        return subprocess.Popen([sys.executable, "-S", str(TEST_FILE), "_fake-coordinator", str(self.work), str(self.manifest)],
                                stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, start_new_session=True)

    def finish(self, process, expected=0):
        output, _ = process.communicate(timeout=60)
        self.assertEqual(process.returncode, expected, output[-6000:])
        return output

    def states(self):
        db = sqlite3.connect(self.work / "state.sqlite3")
        try:
            return {r["name"]: r for (text,) in db.execute("SELECT data FROM tasks") for r in [json.loads(text)]}
        finally:
            db.close()

    def journal(self):
        path = self.work / "journal.jsonl"
        return [json.loads(s) for s in path.read_text().splitlines()] if path.exists() else []

    def kill_old_backends(self):
        path = self.work / "state.sqlite3"
        if not path.exists():
            return
        db = sqlite3.connect(path)
        try:
            for (text,) in db.execute("SELECT data FROM stages"):
                r = json.loads(text)
                if r["status"] == "running" and r.get("pgid"):
                    try:
                        os.killpg(r["pgid"], signal.SIGKILL)
                    except ProcessLookupError:
                        pass
        finally:
            db.close()
        time.sleep(.05)

    def assert_complete(self):
        self.assertTrue(all(r["status"] == "done" for r in self.states().values()))
        summary = json.loads((self.work / "reports/summary.json").read_text())
        self.assertTrue(summary["synthetic"])
        self.assertTrue(all(t["metrics"]["validated_frequency_hz"] > 0 for t in summary["tasks"]))
        top = self.states()["top_fixture"]["published"]["metrics"]
        self.assertEqual(top["hierarchical_standard_cell_area_um2"], 60)
        self.assertGreater(top["child_period_limit_ps"], 900)
        db = sqlite3.connect(self.work / "state.sqlite3")
        try:
            self.assertEqual(db.execute("PRAGMA integrity_check").fetchone()[0], "ok")
            self.assertEqual(db.execute("PRAGMA journal_mode").fetchone()[0], "wal")
        finally:
            db.close()

    def test_two_workers_completion_and_checkpoint_reuse(self):
        self.finish(self.launch())
        self.assert_complete()
        active, peak = set(), 0
        for entry in sorted(self.journal(), key=lambda e: e["time"]):
            if entry["event"] == "start":
                active.add(entry["pid"])
                peak = max(peak, len(active))
            else:
                active.discard(entry["pid"])
        self.assertEqual(peak, 2)
        starts = sum(e["event"] == "start" for e in self.journal())
        self.control(config={"workers": 1})
        self.finish(self.launch())
        self.assertEqual(sum(e["event"] == "start" for e in self.journal()), starts)
        # Changing only this PE's RTL invalidates its dependent chain, not B.
        target = self.manifest.parent / "pe_leaf_a.sv"
        target.write_text(target.read_text() + "// input change\n")
        before = Counter(e["task"] for e in self.journal() if e["event"] == "start")
        self.finish(self.launch())
        after = Counter(e["task"] for e in self.journal() if e["event"] == "start")
        self.assertEqual(before["pe_leaf_b"], after["pe_leaf_b"])
        for task in ("pe_leaf_a", "pe__fixture", "sa__fixture", "top_fixture"):
            self.assertGreater(after[task], before[task])

    def test_ready_parent_starts_while_unrelated_pe_is_still_running(self):
        # B cannot finish its first stage until PE starts. A batch/layer barrier
        # would stall; a work-conserving scheduler must release PE after A.
        self.control(wait_for_task={"task": "pe_leaf_b", "phase": "synth", "until": "pe__fixture"})
        self.finish(self.launch())
        self.assert_complete()
        events = self.journal()
        pe_start = next(e["time"] for e in events if e["task"] == "pe__fixture" and e["event"] == "start")
        b_first_end = next(e["time"] for e in events if e["task"] == "pe_leaf_b" and e["event"] == "end")
        self.assertLess(pe_start, b_first_end)

    def test_configurable_worker_concurrency(self):
        fixtures = self.root / "extra"
        fixtures.mkdir()
        self.manifest = make_fixture(fixtures, extra_roots=2)
        for workers in (1, 3):
            with self.subTest(workers=workers):
                self.work = self.root / f"workers-{workers}"
                self.work.mkdir()
                self.control(config={"workers": workers})
                self.finish(self.launch())
                self.assert_complete()
                active, peak = set(), 0
                for entry in sorted(self.journal(), key=lambda e: e["time"]):
                    if entry["event"] == "start":
                        active.add(entry["pid"])
                        peak = max(peak, len(active))
                    else:
                        active.discard(entry["pid"])
                self.assertEqual(peak, workers)

    def test_error_propagation_retry_and_missing_artifact(self):
        self.control(fail_task="pe_leaf_a", fail_phase="place", fail_once=True)
        self.finish(self.launch(), 1)
        states = self.states()
        self.assertEqual(states["pe_leaf_a"]["status"], "failed")
        self.assertEqual(states["pe_leaf_a"]["error"]["exit_code"], 7)
        self.assertEqual(states["pe__fixture"]["status"], "blocked")
        self.assertEqual(states["pe_leaf_b"]["status"], "done")
        self.control(retry_failed=True)
        self.finish(self.launch())
        self.assert_complete()
        published = self.states()["pe_leaf_a"]["published"]
        Path(published["artifacts"]["lef"]).write_text("CORRUPTED")
        # Also damage a completed stage to exercise missing-artifact detection
        # on a required rebuild, not just reconstruction of a publication copy.
        db = sqlite3.connect(self.work / "state.sqlite3")
        try:
            stages = [json.loads(t) for t, in db.execute("SELECT data FROM stages")]
        finally:
            db.close()
        original = next(s for s in stages if s["task"] == "pe_leaf_a" and s["phase"] == "synth" and "publish-00" in s["key"])
        Path(next(iter(original["artifacts"]))).unlink()
        self.control(missing_task="pe_leaf_a", missing_phase="synth")
        self.finish(self.launch(), 1)
        self.assertEqual(self.states()["pe_leaf_a"]["error"]["category"], "missing_artifact")

    def test_search_limit_and_publication_hold_failure(self):
        self.control(config={"max_search_iterations": 1})
        self.finish(self.launch(), 1)
        self.assertEqual(self.states()["pe_leaf_a"]["error"]["category"], "nonconvergent")
        self.control(hold_slack=-1)
        self.finish(self.launch(), 1)
        self.assertEqual(self.states()["pe_leaf_a"]["error"]["category"], "timing")
        failure = self.states()["pe_leaf_a"]["error"]
        self.assertEqual(failure["hold_ws_ps"], -1)
        self.assertEqual(failure["hold_slack_margin_ps"], 15)
        self.assertNotIn("published", self.states()["pe_leaf_a"])

    def test_adaptive_hold_repair_and_restart_reuses_correct_attempt(self):
        # Keep this recovery fixture to one PE with inlined SRAM. Its simulated hold timing
        # requires >=8 ps of repair margin, independent of clock period.
        manifest = json.loads(self.manifest.read_text())
        manifest["modules"] = [m for m in manifest["modules"] if m["name"] in ("pe_leaf_a", "ram_a")]
        atomic_json(self.manifest, manifest)
        self.control(hold_required_margin_ps=8, fail_task="pe_leaf_a", fail_phase="place",
                     fail_attempt="publish-01", fail_once=True)
        self.finish(self.launch(), 1)
        self.assertEqual(self.states()["pe_leaf_a"]["error"]["category"], "tool")
        db = sqlite3.connect(self.work / "state.sqlite3")
        try:
            searches_before = db.execute("SELECT COUNT(*) FROM events WHERE kind='search_result'").fetchone()[0]
        finally:
            db.close()
        saved = self.states()["pe_leaf_a"]["progress"]
        self.assertEqual((saved["mode"], saved["index"], saved["phase"], saved["hold_slack_margin_ps"]),
                         ("publish", 1, "place", 10))
        self.control(hold_required_margin_ps=8, retry_failed=True)
        self.finish(self.launch())
        state = self.states()["pe_leaf_a"]
        self.assertEqual(state["status"], "done")
        self.assertEqual(state["published"]["metrics"]["hold_slack_margin_ps"], 10)
        self.assertEqual(state["published"]["metrics"]["hold_ws_ps"], 2)
        db = sqlite3.connect(self.work / "state.sqlite3")
        try:
            self.assertEqual(db.execute("SELECT COUNT(*) FROM events WHERE kind='search_result'").fetchone()[0], searches_before)
            attempts = sorted([json.loads(s) for s, in db.execute("SELECT data FROM attempts")
                               if json.loads(s)["mode"] == "publish"], key=lambda a: a["index"])
        finally:
            db.close()
        self.assertEqual([a["hold_slack_margin_ps"] for a in attempts], [5, 10])
        self.assertEqual([a["timing_pass"] for a in attempts], [False, True])
        self.assertEqual(attempts[0]["period_ps"], attempts[1]["period_ps"])
        for attempt in attempts:
            text = (Path(attempt["directory"]) / "inputs/config.mk").read_text()
            self.assertIn(f'HOLD_SLACK_MARGIN = {attempt["hold_slack_margin_ps"]}', text)
        starts = [e for e in self.journal() if e["event"] == "start"
                  and e["attempt"].startswith("publish-01")]
        self.assertEqual(sum(e["phase"] == "synth" for e in starts), 1)
        self.assertEqual(sum(e["phase"] == "place" for e in starts), 2)
        self.assertTrue(all(e["hold_slack_margin_ps"] == 10 for e in starts))

    def test_resume_latest_search_point_after_power_loss_and_legacy_state(self):
        manifest = json.loads(self.manifest.read_text())
        manifest["modules"] = [m for m in manifest["modules"] if m["name"] in ("pe_leaf_a", "ram_a")]
        atomic_json(self.manifest, manifest)
        for phase, legacy in (("inputs", False), ("route", False), ("route", True)):
            with self.subTest(phase=phase, legacy=legacy):
                self.work = self.root / f"cursor-{phase}-{legacy}"
                self.work.mkdir()
                self.control(kill_event="sweep_checkpoint", kill_task="pe_leaf_a",
                             kill_mode="search", kill_index=1, kill_phase=phase)
                process = self.launch()
                process.wait(timeout=30)
                self.assertEqual(process.returncode, -signal.SIGKILL)
                self.kill_old_backends()
                process.communicate(timeout=5)
                point = self.states()["pe_leaf_a"]["progress"]
                self.assertEqual((point["mode"], point["index"], point["period_ps"], point["phase"]),
                                 ("search", 1, 857.1, phase))
                with redirect_stdout(io.StringIO()) as output:
                    self.assertEqual(h.main(["--status", "--work-dir", str(self.work)]), 0)
                self.assertIn("857.1", output.getvalue())
                self.assertIn("phase= " + phase, output.getvalue())
                db = sqlite3.connect(self.work / "state.sqlite3")
                try:
                    last_event = db.execute("SELECT MAX(id) FROM events").fetchone()[0]
                    if legacy:
                        item = self.states()["pe_leaf_a"]
                        item.pop("progress")
                        with db:
                            db.execute("UPDATE tasks SET data=? WHERE name='pe_leaf_a'", (canonical(item),))
                finally:
                    db.close()
                self.control()
                self.finish(self.launch())
                self.assertEqual(self.states()["pe_leaf_a"]["status"], "done")
                db = sqlite3.connect(self.work / "state.sqlite3")
                try:
                    resumed = [json.loads(data) for data, in db.execute(
                        "SELECT data FROM events WHERE id>? AND kind='stage_reused'", (last_event,))]
                    self.assertTrue(all('/search-00-' not in e["attempt"] for e in resumed))
                    self.assertEqual(db.execute("SELECT COUNT(*) FROM events WHERE kind='search_result'").fetchone()[0], 2)
                    self.assertEqual(db.execute("PRAGMA integrity_check").fetchone()[0], 'ok')
                finally:
                    db.close()

    def test_hold_buffer_cap_escalation_cts_route_and_restart(self):
        manifest = json.loads(self.manifest.read_text())
        manifest['modules'] = [m for m in manifest['modules'] if m['name'] in ('pe_leaf_a', 'ram_a')]
        atomic_json(self.manifest, manifest)
        for phase in ('cts', 'route'):
            with self.subTest(phase=phase):
                self.work = self.root / ('buffer-budget-' + phase)
                self.work.mkdir()
                controls = {'config': {'hold_max_buffer_percent': 20},
                            'required_buffer_percent': 80, 'buffer_cap_phase': phase,
                            'actual_period_ps': 1000}
                if phase == 'cts':
                    self.control(**controls, kill_event='hold_buffer_budget_retry', kill_task='pe_leaf_a')
                    process = self.launch()
                    process.wait(timeout=30)
                    self.assertEqual(process.returncode, -signal.SIGKILL)
                    self.kill_old_backends()
                    process.communicate(timeout=5)
                    point = self.states()['pe_leaf_a']['progress']
                    self.assertEqual((point['index'], point['period_ps'], point['hold_max_buffer_percent']), (0, 1000, 100))
                self.control(**controls)
                self.finish(self.launch())
                state = self.states()['pe_leaf_a']
                self.assertEqual(state['status'], 'done')
                self.assertEqual(state['published']['metrics']['hold_max_buffer_percent'], 100)
                events = [e for e in self.journal() if e['event'] == 'start' and e['attempt'].startswith('search-00')]
                retries = [e for e in events if e['phase'] == phase]
                self.assertEqual([e['hold_max_buffer_percent'] for e in retries], [20, 100])
                self.assertEqual(sum(e['phase'] == 'synth' for e in events), 1)
                if phase == 'route':
                    self.assertEqual(sum(e['phase'] == 'cts' for e in events), 1)
                db = sqlite3.connect(self.work / 'state.sqlite3')
                try:
                    changes = [json.loads(s) for s, in db.execute("SELECT data FROM events WHERE kind='hold_buffer_budget_retry'")]
                    self.assertEqual(len(changes), 1)
                    self.assertTrue(Path(changes[0]['previous_log']).is_file())
                    self.assertEqual(db.execute('PRAGMA integrity_check').fetchone()[0], 'ok')
                finally:
                    db.close()

    def test_hold_buffer_cap_at_max_is_bounded_failure(self):
        manifest = json.loads(self.manifest.read_text())
        manifest['modules'] = [m for m in manifest['modules'] if m['name'] in ('pe_leaf_a', 'ram_a')]
        atomic_json(self.manifest, manifest)
        self.control(required_buffer_percent=101, actual_period_ps=1000)
        self.finish(self.launch(), 1)
        failure = self.states()['pe_leaf_a']
        self.assertEqual(failure['error']['category'], 'hold_buffer_limit')
        self.assertEqual(failure['error']['hold_max_buffer_percent'], 100)
        self.assertEqual(sum(e['phase'] == 'cts' and e['event'] == 'start' for e in self.journal()), 1)
        self.assertNotIn('published', failure)

    def test_power_loss_during_stage_busy_lock_and_partial_rejection(self):
        self.control(sleep_task="pe_leaf_a", sleep_phase="floorplan")
        process = self.launch()
        deadline = time.monotonic() + 15
        while not (self.work / "sleep_consumed").exists() and time.monotonic() < deadline:
            time.sleep(.02)
        self.assertTrue((self.work / "sleep_consumed").exists())
        os.kill(process.pid, signal.SIGKILL)
        process.wait(timeout=5)
        # A backend still holds the inherited flock even after coordinator death.
        blocked = self.launch()
        output = self.finish(blocked, 2)
        self.assertIn("Workspace busy", output)
        self.kill_old_backends()
        process.communicate(timeout=5)
        self.finish(self.launch())
        self.assert_complete()
        events = [e for e in self.journal() if e["event"] == "start" and e["task"] == "pe_leaf_a" and e["attempt"].startswith("search-00")]
        counts = Counter(e["phase"] for e in events)
        self.assertEqual(counts["synth"], 1)
        self.assertEqual(counts["floorplan"], 2)

    def test_sigint_stops_workers_and_resumes(self):
        self.control(sleep_task="pe_leaf_a", sleep_phase="floorplan")
        process = self.launch()
        deadline = time.monotonic() + 15
        while not (self.work / "sleep_consumed").exists() and time.monotonic() < deadline:
            time.sleep(.02)
        self.assertTrue((self.work / "sleep_consumed").exists())
        os.kill(process.pid, signal.SIGINT)
        self.finish(process, 130)
        self.assertEqual(self.states()["pe_leaf_a"]["status"], "interrupted")
        self.finish(self.launch())
        self.assert_complete()

    def test_power_loss_before_stage_commit(self):
        self.recover_kill("stage_verified", "synth", expected_synth=2)

    def test_power_loss_after_stage_commit(self):
        self.recover_kill("stage_committed", "synth", expected_synth=1)

    def test_power_loss_before_publication_rename(self):
        self.recover_kill("publication_staged", None, expected_synth=1)

    def test_power_loss_after_publication_rename(self):
        self.recover_kill("publication_renamed", None, expected_synth=1)

    def recover_kill(self, event, phase, expected_synth):
        self.control(kill_event=event, kill_task="pe_leaf_a", kill_phase=phase)
        process = self.launch()
        # Another worker may survive and hold the pipe/lock; wait for the killed
        # coordinator, then emulate power loss for its remaining process groups.
        process.wait(timeout=30)
        self.assertEqual(process.returncode, -signal.SIGKILL)
        self.kill_old_backends()
        process.communicate(timeout=5)
        self.finish(self.launch())
        self.assert_complete()
        events = [e for e in self.journal() if e["event"] == "start" and e["task"] == "pe_leaf_a"
                  and e["phase"] == "synth" and e["attempt"].startswith("search-00")]
        self.assertEqual(len(events), expected_synth)
        directories = [p for p in (self.work / "published/pe_leaf_a").iterdir() if not p.name.startswith(".")]
        self.assertEqual(len(directories), 1)
        self.assertEqual(len(list(directories[0].glob("publication.json"))), 1)


if __name__ == "__main__":
    if len(sys.argv) > 1 and sys.argv[1] == "_fake-stage":
        sys.exit(fake_stage(sys.argv[2], sys.argv[3]))
    if len(sys.argv) > 1 and sys.argv[1] == "_fake-coordinator":
        sys.exit(coordinator(sys.argv[2], sys.argv[3]))
    unittest.main()
