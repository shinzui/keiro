#!/usr/bin/env python3
"""Diagnostic comparison, not a replacement release acceptance gate."""
import csv
import datetime
import hashlib
import json
import os
from pathlib import Path
import statistics
import subprocess
import sys
import threading
import time

ROOT = Path(__file__).resolve().parents[5]
HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(ROOT / 'scripts'))
from release_workflow import workspace_lock

metadata = json.loads((HERE / 'comparison.json').read_text())
previous = Path(metadata['previous_worktree'])
binary_tail = 'b/keiro-bench/build/keiro-bench/keiro-bench'
binaries = {
    'previous': previous / 'dist-newstyle/build/aarch64-osx/ghc-9.12.4/keiro-0.23.0.0' / binary_tail,
    'candidate': Path(metadata['candidate_bench_path']),
}

def closure(plan):
    units = {p['id']: p for p in plan['install-plan']}
    pending = [p['id'] for p in units.values() if p['pkg-name'] == 'keiro' and p.get('component-name') == 'bench:keiro-bench']
    assert len(pending) == 1
    seen, external = set(), set()
    while pending:
        identity = pending.pop()
        if identity in seen:
            continue
        seen.add(identity)
        unit = units[identity]
        pending.extend(unit.get('depends', []) + unit.get('exe-depends', []))
        if unit.get('pkg-src', {}).get('type') != 'local':
            external.add(identity)
    return external

old_plan = json.loads((previous / 'dist-newstyle/cache/plan.json').read_text())
new_plan = json.loads((HERE / 'candidate-plan.json').read_text())
old_external, new_external = closure(old_plan), closure(new_plan)
assert old_external == new_external, {'previous_only': sorted(old_external-new_external), 'candidate_only': sorted(new_external-old_external)}
assert not subprocess.check_output(['git', 'diff', '--name-only'], cwd=previous, text=True).strip()
assert subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=previous, text=True).strip() == metadata['previous_commit']
metadata['external_unit_ids'] = sorted(old_external)
metadata['binary_sha256'] = {name: hashlib.sha256(path.read_bytes()).hexdigest() for name, path in binaries.items()}
metadata['same_benchmark_sources'] = {}
for relative in ['keiro/bench/Main.hs', 'keiro/bench/InboxDelegatedBench.hs', 'keiro/bench/ReadModelBench.hs', 'keiro/bench/BenchSetup.hs']:
    assert (ROOT / relative).read_bytes() == (previous / relative).read_bytes(), relative
    metadata['same_benchmark_sources'][relative] = hashlib.sha256((ROOT / relative).read_bytes()).hexdigest()
(HERE / 'verified-inputs.json').write_text(json.dumps(metadata, indent=2, sort_keys=True) + '\n')

groups = [
    ('command', '/command/&&/accepted-1/'),
    ('inbox', '/delegated-history-duplicate/||/delegated-batch-1000.all-duplicate.metrics-off/'),
    ('projection', 'projection'),
    ('read-model', 'read-model'),
]
done = threading.Event()
phase = None

def sample_load():
    with (HERE / 'comparison-process-load.jsonl').open('w') as out:
        while not done.is_set():
            raw = subprocess.check_output(['ps', '-axo', 'pid,ppid,etime,%cpu,comm'], text=True)
            records = []
            for line in raw.splitlines()[1:]:
                fields = line.strip().split(None, 4)
                if len(fields) != 5:
                    continue
                pid, ppid, elapsed, cpu, command = fields
                if float(cpu) >= 5 or any(word in command.lower() for word in ['ghc', 'cabal', 'keiro-bench']):
                    records.append(dict(pid=int(pid), ppid=int(ppid), elapsed=elapsed, cpu=float(cpu), executable=command))
            out.write(json.dumps(dict(time=datetime.datetime.now(datetime.timezone.utc).isoformat(), phase=phase, processes=records)) + '\n')
            out.flush()
            done.wait(5)

results = []
with workspace_lock(ROOT):
    monitor = threading.Thread(target=sample_load, daemon=True)
    monitor.start()
    try:
        for pair in range(1, 4):
            order = ['previous', 'candidate'] if pair % 2 else ['candidate', 'previous']
            for group, pattern in groups:
                for name in order:
                    phase = f'pair-{pair}-{group}-{name}'
                    log, output = HERE / (phase + '.log'), HERE / (phase + '.csv')
                    command = [str(binaries[name]), '-p', pattern, '-j1', '--time-mode', 'wall', '--hide-progress', '--stdev', '5', '--timeout', '10s', '--baseline', str(ROOT / f'keiro/bench/baseline-{group}.csv'), '--fail-if-slower', '25', '--csv', str(output), '+RTS', '-N2', '-RTS']
                    environment = dict(os.environ)
                    if group == 'projection':
                        environment['KEIRO_READ_MODEL_P95'] = '1'
                    print('RUN', phase, flush=True)
                    started = time.time()
                    with log.open('w') as handle:
                        handle.write(json.dumps(dict(command=command, started=started)) + '\n')
                        handle.flush()
                        result = subprocess.run(command, cwd=ROOT / 'keiro', env=environment, stdout=handle, stderr=subprocess.STDOUT)
                    measurements = {}
                    if output.exists():
                        with output.open() as handle:
                            measurements = {row['Name']: int(row['Mean (ps)']) for row in csv.DictReader(handle)}
                    results.append(dict(pair=pair, group=group, version=name, status=result.returncode, started=started, finished=time.time(), measurements_ps=measurements, log=log.name, csv=output.name))
                    (HERE / 'runs.json').write_text(json.dumps(results, indent=2, sort_keys=True) + '\n')
                    print('DONE', phase, 'status', result.returncode, 'measurements', len(measurements), flush=True)
    finally:
        done.set()
        monitor.join()

summary = {}
names = sorted(set().union(*(set(run['measurements_ps']) for run in results)))
for name in names:
    ratios = []
    for pair in range(1, 4):
        old = [run['measurements_ps'][name] for run in results if run['pair'] == pair and run['version'] == 'previous' and name in run['measurements_ps']]
        new = [run['measurements_ps'][name] for run in results if run['pair'] == pair and run['version'] == 'candidate' and name in run['measurements_ps']]
        if len(old) == len(new) == 1:
            ratios.append(new[0] / old[0])
    summary[name] = dict(candidate_over_previous=ratios, median_ratio=statistics.median(ratios) if ratios else None, complete_pairs=len(ratios))
(HERE / 'paired-summary.json').write_text(json.dumps(summary, indent=2, sort_keys=True) + '\n')
print('Saved paired diagnostic summary; release acceptance still requires release-gate.', flush=True)
