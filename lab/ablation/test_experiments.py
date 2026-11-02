"""Control-plane tests; no hardware builds or simulations are launched."""
import contextlib
import copy
import io
import json
from pathlib import Path
import sys
import tempfile
import unittest
from collections import Counter
from unittest.mock import patch, Mock

from lab import full
from lab.ablation import core, results, run_case, run_experiments as runner, summarize


def valid_metrics():
    lane_idle=dict.fromkeys(core.REASONS,0); lane_idle['control']=92
    mac_idle=dict.fromkeys(core.REASONS,0); mac_idle['control']=5888
    phase={'cycles':100,'lane_active':8,'mac_active':512,'lane_idle':lane_idle,'mac_idle':mac_idle}
    empty={'cycles':0,'lane_active':0,'mac_active':0,'lane_idle':dict.fromkeys(core.REASONS,0),'mac_idle':dict.fromkeys(core.REASONS,0)}
    return {'cycles':100,'lane_active':8,'mac_active':512,'lane_idle':lane_idle,'mac_idle':mac_idle,
            'phases':{'warmup':copy.deepcopy(empty),'steady':phase,'drain':copy.deepcopy(empty)},
            'requests':1,'responses':1,'store_beats':8,'throughput':10.0,'latency':.1,
            'input_bus_util':.01,'output_bus_util':.08,'whole_array_idle_cycles':90,
            'peak_outstanding':1,'reordered_responses':0,'output_hash':'123',
            'sampled_delay':{'count':1,'mean':4,'p50':4,'p95':4,'p99':4,'max':4},
            'observed_delay':{'count':1,'mean':4,'p50':4,'p95':4,'p99':4,'max':4},
            'blocker_cycles':dict.fromkeys(core.REASONS,0),'blocks':[{'m':1,'n':1,'count':1}]}


class ExperimentsTest(unittest.TestCase):
    def tasks(self,*extra):
        return runner.build_all_tasks(runner.make_parser().parse_args(list(extra)))

    def spec(self):
        task=next(t for t in self.tasks('--ablation-profile','smoke','--count','1')
                  if t.hw.mode=='dynamic' and (t.m,t.n,t.k)==(1,8,8) and t.distribution=='fixed')
        return task.spec

    def test_original_task_sets_and_selection(self):
        args=full.make_parser().parse_args(['--experiments','static,dynamic,rect_static,rect_dynamic,static_staticmn'])
        work,groups,_=full.collect_work(args)
        self.assertEqual(len(work),798)
        self.assertEqual([len(v) for v in groups.values()],[210,210,126,126,126])
        self.assertEqual(work[0].task.axis,'labM')
        self.assertEqual(work[0].task.m,512)
        self.assertEqual(work[-1].task.axis,'labM64NK')
        self.assertEqual(work[-1].task.m,1)
        self.assertTrue(all('ablation' not in str(w.task.out_file) for w in work))
        self.assertEqual(full.make_parser().parse_args(['-j','24']).jobs,24)

    def test_full_matrix_and_smoke_bound(self):
        full_tasks=self.tasks()
        self.assertEqual(len(full_tasks),298)
        self.assertEqual(len({t.hw for t in full_tasks}),53)
        self.assertEqual(Counter(t.hw.mode for t in full_tasks),
                         {'static':82,'dynamic':108,'dynamic_inorder':108})
        self.assertEqual(len({t.out_file for t in full_tasks}),len(full_tasks))
        self.assertEqual(len({core.digest(t.spec) for t in full_tasks}),len(full_tasks))
        self.assertEqual(len(self.tasks('--ablation-profile','smoke','--count','2')),40)
        with self.assertRaisesRegex(ValueError,'--count'): self.tasks('--ablation-profile','smoke')
        for task in full_tasks:
            self.assertEqual(task.hw.a_logic,task.hw.a//2) if task.hw.mode=='static' else self.assertLess(task.hw.a_logic,task.hw.a)
            expected={1:1,4:2,16:4}[task.hw.lane]
            self.assertEqual(task.hw.slot_acc_count,expected)
        with self.assertRaises(ValueError): self.tasks('--ablation-studies','nonexistent')

    def test_reduced_study_coverage_and_shared_baselines(self):
        tasks=self.tasks()
        baseline=[t for t in tasks if 'idle' in t.studies]
        focused=[t for t in tasks if 'latency' in t.studies and 'idle' not in t.studies]
        capacity=self.tasks('--ablation-studies','capacity')
        fixed=[t for t in capacity if t.distribution=='fixed']
        stress=[t for t in capacity if t.distribution=='longtail']
        self.assertEqual((len(baseline),len(focused),len(fixed),len(stress)),(54,126,94,30))
        self.assertEqual(sum('capacity' in t.studies for t in baseline),6)
        self.assertEqual(54+126+(94-6)+30,298)
        self.assertEqual({(t.hw.lane,t.hw.width) for t in baseline},{(1,64),(4,32),(16,16)})
        self.assertTrue(all((t.distribution,t.mean,t.seed)==('fixed',4,1) for t in baseline))
        self.assertEqual({(t.hw.lane,t.hw.width) for t in focused+capacity},{(4,32)})
        self.assertEqual({(t.m,t.n,t.k) for t in focused},
                         {(16,1024,1024),(256,256,256),(64,64,64)})
        self.assertEqual({(t.m,t.n,t.k) for t in capacity},{(16,1024,1024),(256,256,256)})
        for mode in core.MODES:
            for shape in ((16,1024,1024),(256,256,256),(64,64,64)):
                for mean in (32,128):
                    points={(t.distribution,t.seed) for t in focused
                            if t.hw.mode==mode and (t.m,t.n,t.k)==shape and t.mean==mean}
                    self.assertEqual(points,{('fixed',1),*(('uniform',s) for s in (1,2,3)),
                                             *(('longtail',s) for s in (1,2,3))})
        self.assertTrue(all((t.mean,t.seed)==(32,1) for t in stress))
        config=runner.read_config(runner.HERE/'defaults.json')
        entry=next(h for h in config['hardware'] if h['lane']==4)
        for mode in core.MODES:
            base=runner.base_hardware(entry,mode,config)
            hardware={t.hw for t in fixed if t.hw.mode==mode}
            self.assertEqual(len(hardware),9 if mode=='static' else 19)
            for field in ('a','b','acc'):
                for numerator,denominator in ((3,4),(3,2)):
                    self.assertIn(runner.changed(base,**{field:getattr(base,field)*numerator//denominator}),hardware)
                if mode!='static':
                    for numerator in (1,3):
                        self.assertIn(runner.changed(base,**{field+'_logic':getattr(base,field)*numerator//4}),hardware)
            if mode!='static':
                for fields in (('a','b'),('acc',)):
                    for pn,pd,ln,ld in ((3,4,1,4),(3,2,1,4),(3,2,3,4)):
                        values={f:getattr(base,f)*pn//pd for f in fields}
                        values.update({f+'_logic':getattr(base,f)*ln//ld for f in fields})
                        self.assertIn(runner.changed(base,**values),hardware)
            pressure={t.hw for t in stress if t.hw.mode==mode}
            expected={runner.changed(base,**{f:getattr(base,f)*3//4}) for f in ('a','b','acc')}
            if mode!='static':
                expected.update(runner.changed(base,**{f+'_logic':getattr(base,f)*3//4}) for f in ('a','b','acc'))
            self.assertEqual(pressure,expected)
        def policy_keys(mode):
            specs=[]
            for t in tasks:
                if t.hw.mode==mode:
                    spec=t.spec; spec['hardware'].pop('mode'); specs.append(core.canonical(spec))
            return set(specs)
        self.assertEqual(policy_keys('dynamic'),policy_keys('dynamic_inorder'))

    def test_full_budget_rejects_expansion_without_truncating(self):
        self.assertEqual(runner.MAX_FULL_TASKS,299)
        with patch.object(runner,'MAX_FULL_TASKS',298):
            self.assertEqual(len(self.tasks()),298)
        with patch.object(runner,'MAX_FULL_TASKS',297):
            with self.assertRaisesRegex(ValueError,'generates 298 tasks; limit is 297'):
                self.tasks()
        config=runner.read_config(runner.HERE/'defaults.json')
        config['capacity_lanes']=[1,4,16]
        with tempfile.TemporaryDirectory() as d:
            path=Path(d)/'expanded.json'; path.write_text(json.dumps(config))
            with self.assertRaisesRegex(ValueError,'limit is 299'):
                self.tasks('--ablation-config',str(path))
            config['capacity_lanes']=[99]; path.write_text(json.dumps(config))
            with self.assertRaisesRegex(ValueError,'capacity_lanes'):
                self.tasks('--ablation-config',str(path))

    def test_study_dedup_and_identity(self):
        tasks=self.tasks()
        base=next(t for t in tasks if set(t.studies)=={'idle','latency','capacity'})
        self.assertEqual(sum(t.spec==base.spec for t in tasks),1)
        filtered=self.tasks('--ablation-studies','idle')
        self.assertEqual(len(filtered),54)
        self.assertTrue(all('idle' in t.studies for t in filtered))
        spec=base.spec
        for key in ('seed','mean','distribution'):
            changed=copy.deepcopy(spec); changed['delay'][key]= 'uniform' if key=='distribution' else spec['delay'][key]+1
            self.assertNotEqual(core.digest(spec),core.digest(changed))
        changed=copy.deepcopy(spec); changed['trace']=not changed['trace']
        self.assertNotEqual(core.digest(spec),core.digest(changed))

    def test_dry_run_never_builds_runs_or_creates_directories(self):
        with tempfile.TemporaryDirectory() as d:
            destination=Path(d)/'absent'
            argv=['lab/full.py','--experiments','ablation','--ablation-profile','smoke','--count','2',
                  '--dry-run','--ablation-data-root',str(destination)]
            out=io.StringIO()
            with (patch.object(sys,'argv',argv), patch('subprocess.Popen',side_effect=AssertionError('spawned')),
                  patch('subprocess.run',side_effect=AssertionError('built')), contextlib.redirect_stdout(out)):
                self.assertEqual(full.main(),0)
            self.assertIn('generated=40 pending=40 skipped_existing=0',out.getvalue())
            self.assertFalse(destination.exists())

    def test_complete_requires_entire_valid_result(self):
        spec=self.spec(); metrics=valid_metrics()
        core.validate_stats(metrics,spec)
        with tempfile.TemporaryDirectory() as d:
            path=Path(d)/'result.json'
            self.assertFalse(results.complete(path,spec))
            path.write_text('{')
            self.assertFalse(results.complete(path,spec))
            result={'status':'complete','spec':spec,'metrics':metrics,
                    'queue_layout':results.queue_layout(core.Hardware(**spec['hardware']))}
            path.write_text(json.dumps(result))
            self.assertTrue(results.complete(path,spec))
            other=copy.deepcopy(spec); other['delay']['seed']+=1
            self.assertFalse(results.complete(path,other))
            for change in ('cycles','responses','mac_active'):
                invalid=copy.deepcopy(result); invalid['metrics'][change]+=1
                path.write_text(json.dumps(invalid))
                self.assertFalse(results.complete(path,spec))
            for missing in ('sampled_delay','blocker_cycles','output_hash','blocks'):
                invalid=copy.deepcopy(result); del invalid['metrics'][missing]
                path.write_text(json.dumps(invalid))
                self.assertFalse(results.complete(path,spec))

    def test_full_resume_and_force_use_validated_completion(self):
        with tempfile.TemporaryDirectory() as d:
            options=['--experiments','ablation','--ablation-profile','smoke','--count','1',
                     '--dry-run','--ablation-data-root',d]
            args=full.make_parser().parse_args(options)
            work,_,_=full.collect_work(args)
            task=work[0].task
            task.out_dir.mkdir(parents=True)
            task.out_file.write_text(json.dumps({'status':'complete','spec':task.spec,
                                                'metrics':valid_metrics(),
                                                'queue_layout':results.queue_layout(task.hw)}))
            for extra,expected in [([], 'pending=39 skipped_existing=1'),
                                   (['--force'], 'pending=40 skipped_existing=0')]:
                output=io.StringIO()
                with patch.object(sys,'argv',['lab/full.py',*options,*extra]), contextlib.redirect_stdout(output):
                    self.assertEqual(full.main(),0)
                self.assertIn(expected,output.getvalue())
            task.out_file.write_text('{')
            output=io.StringIO()
            with patch.object(sys,'argv',['lab/full.py',*options]), contextlib.redirect_stdout(output):
                self.assertEqual(full.main(),0)
            self.assertIn('pending=40 skipped_existing=0',output.getvalue())

    def test_failed_rerun_removes_completion_marker(self):
        with tempfile.TemporaryDirectory() as d:
            directory=Path(d); (directory/'result.json').write_text('old result')
            process=Mock(); process.wait.return_value=1
            with (patch.object(sys,'argv',['run_case.py','--spec',core.canonical(self.spec()),'--out-dir',d]),
                  patch.object(run_case,'build',return_value=Path('/tmp/unused-executable')),
                  patch.object(run_case.subprocess,'Popen',return_value=process),
                  patch.object(run_case.signal,'signal')):
                with self.assertRaisesRegex(RuntimeError,'simulation failed'): run_case.main()
            self.assertFalse((directory/'result.json').exists())

    def test_summary_pairs_policies_without_demanding_a_gain(self):
        spec=self.spec(); metrics=valid_metrics()
        runs=[]
        for mode,cycles in [('static',100),('dynamic',100),('dynamic_inorder',100)]:
            s=copy.deepcopy(spec); s['hardware']['mode']=mode
            runs.append({'status':'complete','spec':s,'studies':['idle'],'metrics':copy.deepcopy(metrics)})
        rows=summarize.flatten(runs)
        dynamic=next(r for r in rows if r['mode']=='dynamic')
        self.assertEqual(dynamic['speedup_static'],1)
        self.assertEqual(dynamic['speedup_gemm_inorder'],1)
        self.assertTrue(dynamic['static_logical_match'])
        self.assertTrue(dynamic['inorder_output_match'])
        self.assertEqual(len(summarize.aggregate(rows)),3)
        runs[0]['metrics']['output_hash']='124'
        changed=summarize.aggregate(summarize.flatten(runs))
        aggregate=next(r for r in changed if r['mode']=='dynamic')
        self.assertEqual(aggregate['speedup_static_mean'],'')
        self.assertEqual(aggregate['speedup_static_pairs'],0)
        self.assertEqual(aggregate['speedup_gemm_inorder_mean'],1)


if __name__=='__main__':
    unittest.main()
