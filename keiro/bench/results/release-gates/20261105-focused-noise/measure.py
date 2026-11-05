#!/usr/bin/env python3
"""Fixed diagnostic ABBA/BAAB blocks with within-version repeat controls."""
import csv
import datetime
import hashlib
import json
import math
import os
from pathlib import Path
import statistics
import subprocess
import sys
import threading
import time

ROOT = Path(__file__).resolve().parents[5]
HERE = Path(__file__).resolve().parent
PRIOR = HERE.parent / '20261105-benchmark-investigation'
sys.path.insert(0, str(ROOT / 'scripts'))
from release_workflow import workspace_lock, source_identity

inputs = json.loads((PRIOR / 'verified-inputs.json').read_text())
previous = Path(inputs['previous_worktree'])
binaries = {
    'A': previous / 'dist-newstyle/build/aarch64-osx/ghc-9.12.4/keiro-0.23.0.0/b/keiro-bench/build/keiro-bench/keiro-bench',
    'B': Path(inputs['candidate_bench_path']),
}
for label, name in [('A', 'previous'), ('B', 'candidate')]:
    assert hashlib.sha256(binaries[label].read_bytes()).hexdigest() == inputs['binary_sha256'][name]
cases = {
    'lookup': 'All.read-model-lifecycle.serving-binding.legacy-three',
    'inbox': 'All.inbox.downstream.delegated-history-duplicate.events-10',
}
schedule = []
for block in range(1, 9):
    order = 'ABBA' if block % 2 else 'BAAB'
    for case in (['lookup', 'inbox'] if block % 2 else ['inbox', 'lookup']):
        for position, label in enumerate(order, 1):
            schedule.append(dict(block=block, case=case, position=position, label=label))
plan = dict(
    purpose='Investigate the two observed small slowdowns; diagnostic only.',
    labels={'A': 'exact released 0.23.0.0', 'B': 'unchanged 0.24.0.0 candidate'},
    blocks_per_case=8, schedule=schedule, cases=cases,
    binary_sha256=inputs['binary_sha256'], external_unit_ids=inputs['external_unit_ids'],
    source_identity=source_identity(ROOT),
    options=['-j1', '--time-mode', 'wall', '--hide-progress', '--stdev', '5', '--timeout', '10s', '+RTS', '-N2', '-RTS'],
    analysis='Per block compare geometric means of two B and two A observations. Also retain A2/A1 and B2/B1 controls. Retain all results; incomplete blocks are inconclusive, without retries. These are descriptive measurements under the user-requested concurrent work, not quiet-machine release acceptance.',
)
if (HERE / 'plan.json').exists():
    raise RuntimeError('Refusing to overwrite a previous cohort')
(HERE / 'plan.json').write_text(json.dumps(plan, indent=2, sort_keys=True) + '\n')
done = threading.Event()
phase = None

def monitor():
    with (HERE / 'process-load.jsonl').open('w') as out:
        while not done.is_set():
            records = []
            raw = subprocess.check_output(['ps', '-axo', 'pid,ppid,etime,%cpu,comm'], text=True)
            for line in raw.splitlines()[1:]:
                fields = line.strip().split(None, 4)
                if len(fields) != 5:
                    continue
                pid, ppid, elapsed, cpu, executable = fields
                if float(cpu) >= 5 or any(word in executable.lower() for word in ['cabal', 'ghc', 'keiro-bench']):
                    records.append(dict(pid=int(pid), ppid=int(ppid), elapsed=elapsed, cpu=float(cpu), executable=executable))
            out.write(json.dumps(dict(time=datetime.datetime.now(datetime.timezone.utc).isoformat(), phase=phase, processes=records)) + '\n')
            out.flush()
            done.wait(2)

results = []
with workspace_lock(ROOT):
    worker = threading.Thread(target=monitor, daemon=True)
    worker.start()
    try:
        for item in schedule:
            phase = f"block-{item['block']}-{item['case']}-{item['position']}-{item['label']}"
            log, output = HERE / (phase + '.log'), HERE / (phase + '.csv')
            command = [str(binaries[item['label']]), '-p', '$0 == "' + cases[item['case']] + '"', '-j1', '--time-mode', 'wall', '--hide-progress', '--stdev', '5', '--timeout', '10s', '--csv', str(output), '+RTS', '-N2', '-RTS']
            print('RUN', phase, flush=True)
            started = time.time()
            with log.open('w') as handle:
                handle.write(json.dumps(dict(command=command, started=started)) + '\n')
                handle.flush()
                process = subprocess.run(command, cwd=ROOT / 'keiro', env=dict(os.environ), stdout=handle, stderr=subprocess.STDOUT)
            row = dict(item, started=started, finished=time.time(), status=process.returncode, log=log.name, csv=output.name)
            if output.exists():
                with output.open() as handle:
                    values = list(csv.DictReader(handle))
                if len(values) == 1 and values[0]['Name'] == cases[item['case']]:
                    row.update(mean_ps=int(values[0]['Mean (ps)']), double_stdev_ps=int(values[0]['2*Stdev (ps)']))
            results.append(row)
            (HERE / 'runs.json').write_text(json.dumps(results, indent=2, sort_keys=True) + '\n')
            print('DONE', phase, 'status', row['status'], 'mean_us', row.get('mean_ps', 0) / 1e6, flush=True)
    finally:
        done.set()
        worker.join()
    assert source_identity(ROOT) == plan['source_identity']
    for label, name in [('A', 'previous'), ('B', 'candidate')]:
        assert hashlib.sha256(binaries[label].read_bytes()).hexdigest() == inputs['binary_sha256'][name]

summary = {}
for case in cases:
    blocks = []
    for block in range(1, 9):
        rows = [r for r in results if r['case'] == case and r['block'] == block]
        complete = len(rows) == 4 and all(r['status'] == 0 and r.get('mean_ps', 0) > 0 for r in rows)
        value = dict(block=block, complete=complete)
        if complete:
            a = [r['mean_ps'] for r in rows if r['label'] == 'A']
            b = [r['mean_ps'] for r in rows if r['label'] == 'B']
            value.update(candidate_over_previous=math.sqrt((b[0] / a[0]) * (b[1] / a[1])), previous_repeat_ratio=a[1] / a[0], candidate_repeat_ratio=b[1] / b[0], previous_us=[v / 1e6 for v in a], candidate_us=[v / 1e6 for v in b])
        blocks.append(value)
    completed = [b for b in blocks if b['complete']]
    ratios = [b['candidate_over_previous'] for b in completed]
    repeats = [max(b[k], 1 / b[k]) for b in completed for k in ['previous_repeat_ratio', 'candidate_repeat_ratio']]
    summary[case] = dict(blocks=blocks, complete_blocks=len(completed), candidate_over_previous_median=statistics.median(ratios) if ratios else None, candidate_over_previous_range=[min(ratios), max(ratios)] if ratios else None, same_version_absolute_repeat_ratio_median=statistics.median(repeats) if repeats else None, same_version_absolute_repeat_ratio_max=max(repeats) if repeats else None)
(HERE / 'summary.json').write_text(json.dumps(summary, indent=2, sort_keys=True) + '\n')
print('Fixed cohort complete; all raw outcomes retained.', flush=True)
