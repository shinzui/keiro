import contextlib
import importlib.util
import io
import json
import tempfile
from pathlib import Path
spec=importlib.util.spec_from_file_location('analysis','scripts/analyze-projection-feeding-subscriptions.py');mod=importlib.util.module_from_spec(spec);spec.loader.exec_module(mod)
settings={k:'on' for k in ['fsync','synchronous_commit','full_page_writes','autovacuum']}
base=dict(samples_wait_schedule_claim_resume_timer_us_writer_bytes=[[0]*6]*2000,offered_ops_per_second=100,throughput=100,elapsed_seconds=20,p95_us=1000,p99_us=2000,writer_thread_allocated_bytes_per_operation=100000,poll_failure=0,poll_success=0,settings=settings,resources_after_clients=dict(views=0,connections=0,wake_pump=False))
checks={}
with tempfile.TemporaryDirectory(prefix='keiro-plan327-runtime-controls-') as d:
 root=Path(d)
 for label in ['control-a','control-b']:
  for pair in range(1,6):
   p=root/label/str(pair)/'1-projection-idle.json';p.parent.mkdir(parents=True);p.write_text(json.dumps(base))
 for side in ['baseline','candidate']:
  for pair in range(1,6):
   for mode in ['idle','poll','feed']:
    row=dict(base,poll_success={'idle':0,'poll':80,'feed':4}[mode]);p=root/side/str(pair)/f'projection-{mode}'/f'1-projection-{mode}.json';p.parent.mkdir(parents=True);p.write_text(json.dumps(row))
 with contextlib.redirect_stdout(io.StringIO()):assert mod.analyze(root)
 checks['equal complete synthetic cohort']='passed'
 for pair in range(1,6):
  p=root/'candidate'/str(pair)/'projection-poll'/'1-projection-poll.json';row=json.loads(p.read_text());row['p99_us']*=1.02;p.write_text(json.dumps(row))
 with contextlib.redirect_stdout(io.StringIO()):assert not mod.analyze(root)
 report=json.loads((root/'summary.json').read_text());assert any(r['status']=='regression' for r in report['results']);checks['reproducible 2% writer p99 regression']='refused'
 p=root/'candidate'/'1'/'projection-poll'/'1-projection-poll.json';row=json.loads(p.read_text());row['poll_success']=79;p.write_text(json.dumps(row))
 try:
  with contextlib.redirect_stdout(io.StringIO()):mod.analyze(root)
 except AssertionError:checks['lost polling load']='refused'
 else:raise AssertionError('lost load accepted')
print(json.dumps(checks,indent=2))
