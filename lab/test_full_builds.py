"""Prebuild scheduling tests with fake builders; never run a compiler."""
import contextlib
import io
from pathlib import Path
import sys
import tempfile
import threading
import unittest
from unittest.mock import Mock, patch

from lab import full
from lab.ablation import core, run_experiments as ablation


class ParallelBuildTest(unittest.TestCase):
    def setUp(self):
        self.args = full.make_parser().parse_args(['-j', '24', '--force'])
        self.work, self.tasks, self.modules = full.collect_work(self.args)

    def test_global_build_dedup_and_parallelism(self):
        builds = full.collect_build_work(self.args, self.tasks, self.modules)
        self.assertEqual(len(builds), 72)
        self.assertEqual(len({(i.experiment.name, i.task.hw) for i in builds}), 72)
        self.assertEqual(sum(i.experiment.name == 'ablation' for i in builds), 53)
        for jobs, expected in ((1,1),(3,1),(4,1),(7,1),(8,2),(24,6),(25,6),(1000,72)):
            self.args.jobs = jobs
            self.assertEqual(full.build_workers(self.args, builds), expected)
        self.assertEqual(full.build_workers(self.args, []), 0)

    def test_real_thread_pool_overlaps_experiments_and_never_exceeds_six(self):
        state = {'active':0, 'peak':0}
        mutex = threading.Lock()
        barrier = threading.Barrier(6, timeout=5)
        calls = []
        def builder(name):
            def fake(args, tasks, print_lock):
                self.assertEqual(len(tasks), 1)
                self.assertEqual(args.build_jobs, 4)
                self.assertFalse(args.dry_run)
                self.assertFalse(args.no_prebuild)
                with mutex:
                    calls.append((name, tasks[0].hw, args))
                    ordinal = len(calls)
                    state['active'] += 1
                    state['peak'] = max(state['peak'], state['active'])
                try:
                    if ordinal <= 6:
                        barrier.wait()
                    return True
                finally:
                    with mutex:
                        state['active'] -= 1
            return fake
        with contextlib.ExitStack() as stack:
            for name, module in self.modules.items():
                stack.enter_context(patch.object(module, 'prebuild_hardware', side_effect=builder(name)))
            stack.enter_context(patch('subprocess.run', side_effect=AssertionError('compiler started')))
            stack.enter_context(patch('subprocess.Popen', side_effect=AssertionError('process started')))
            stack.enter_context(contextlib.redirect_stdout(io.StringIO()))
            self.assertTrue(full.prebuild(self.args, self.tasks, self.modules, threading.Lock()))
        self.assertEqual(state, {'active':0, 'peak':6})
        self.assertEqual(len(calls), 72)
        self.assertEqual(len({(name, hw) for name, hw, args in calls}), 72)
        self.assertGreater(len({name for name, hw, args in calls[:6]}), 1)
        self.assertEqual(len({id(args) for name, hw, args in calls}), 72)

    def test_only_ablation_hardware_with_missing_results_is_built(self):
        args = full.make_parser().parse_args(['--experiments', 'ablation'])
        work, tasks, modules = full.collect_work(args)
        module = modules['ablation']
        target = tasks['ablation'][0].hw
        pending = next(t for t in reversed(tasks['ablation']) if t.hw == target)
        with patch.object(module, 'task_complete', side_effect=lambda task: task != pending):
            builds = full.collect_build_work(args, tasks, modules)
            self.assertEqual(len(builds), 1)
            self.assertEqual(builds[0].task, pending)
            args.force = True
            self.assertEqual(len(full.collect_build_work(args, tasks, modules)), 53)
        args.no_prebuild = True
        self.assertEqual(full.collect_build_work(args, tasks, modules), [])
        with patch.object(module, 'prebuild_hardware', side_effect=AssertionError('build started')):
            with contextlib.redirect_stdout(io.StringIO()):
                self.assertTrue(full.prebuild(args, tasks, modules, threading.Lock()))

    def test_failed_parallel_build_prevents_simulations(self):
        argv = ['lab/full.py', '--experiments', 'static', '-j', '24', '--force']
        args = full.make_parser().parse_args(argv[1:])
        work, tasks, modules = full.collect_work(args)
        with (patch.object(sys, 'argv', argv),
              patch.object(full, 'collect_work', return_value=(work,tasks,modules)),
              patch.object(full, 'prepare_result_dirs'),
              patch.object(modules['static'], 'prebuild_hardware', side_effect=RuntimeError('build failed')) as builder,
              patch.object(full, 'run_one', side_effect=AssertionError('simulation started')) as simulation,
              contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO())):
            self.assertEqual(full.main(), 1)
        self.assertEqual(builder.call_count, 5)
        simulation.assert_not_called()

    def test_single_worker_still_executes_prebuild(self):
        self.args.jobs = 1
        with (patch.object(self.modules['static'], 'prebuild_hardware', return_value=True) as builder,
              contextlib.redirect_stdout(io.StringIO())):
            self.assertTrue(full.prebuild(self.args, {'static':self.tasks['static']},
                                          {'static':self.modules['static']}, threading.Lock()))
        self.assertEqual(builder.call_count, 5)
        for call in builder.call_args_list:
            self.assertEqual(call.args[0].build_jobs, 4)
            self.assertGreaterEqual(call.args[0].jobs, 2)

    def test_legacy_builders_pass_four_compiler_workers(self):
        with tempfile.TemporaryDirectory() as d:
            for name, module in self.modules.items():
                if name == 'ablation':
                    continue
                args = full.runner_args(module, self.args)
                args.build_jobs = 4
                args.data_root = Path(d)/name
                args.log_dir = args.data_root/'log'
                with (patch.object(module.subprocess, 'run', return_value=Mock(returncode=0)) as run,
                      contextlib.redirect_stdout(io.StringIO())):
                    self.assertTrue(module.prebuild_hardware(args, self.tasks[name][:1], threading.Lock()))
                self.assertEqual(run.call_count, 1)
                self.assertEqual(run.call_args.kwargs['env']['BUILD_ONLY'], '1')
                self.assertEqual(run.call_args.kwargs['env']['VERILATOR_JOBS'], '4')

    def test_ablation_builds_default_to_four_workers(self):
        hw = next(t.hw for t in self.tasks['ablation'])
        command = core.build_command(hw)
        self.assertEqual(command[command.index('--build-jobs')+1], '4')
        self.assertEqual(ablation.read_config(ablation.HERE/'defaults.json')['build_jobs'], 4)
        identity = core.build_identity(hw)
        with tempfile.TemporaryDirectory() as d:
            with (patch.object(core, 'build_dir', return_value=Path(d)),
                  patch.object(core, 'build_identity', return_value=identity),
                  patch.object(core, 'build_command', return_value=['unused-compiler']) as make_command,
                  patch.object(core.subprocess, 'run', return_value=Mock(returncode=0))):
                core.build(hw)
            make_command.assert_called_once_with(hw, 4)
        args = ablation.make_parser().parse_args(['--force'])
        args.build_jobs = 4
        config = ablation.read_config(args.ablation_config)
        config['build_jobs'] = 2
        with (patch.object(ablation, 'read_config', return_value=config),
              patch.object(ablation, 'build') as build,
              contextlib.redirect_stdout(io.StringIO())):
            self.assertTrue(ablation.prebuild_hardware(args, self.tasks['ablation'][:1], threading.Lock()))
        self.assertEqual(build.call_args.args[1], 4)

    def test_rebuild_is_applied_once_before_simulation(self):
        item = next(i for i in self.work if i.experiment.name == 'static')
        self.args.rebuild = True
        with patch.dict('os.environ', {'REBUILD':'1'}):
            self.assertEqual(full.item_env(item, self.args)['REBUILD'], '0')
            self.args.no_prebuild = True
            self.assertEqual(full.item_env(item, self.args)['REBUILD'], '1')


if __name__ == '__main__':
    unittest.main()
