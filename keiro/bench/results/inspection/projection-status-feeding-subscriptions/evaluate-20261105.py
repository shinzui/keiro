"""Audit the fixed cohort and the predeclared five-pair idle replication.

Run in the Nix shell with the 2026-11-05 evidence directory as the argument.
The original strict analyzer and its false precision result remain unchanged.
"""
import hashlib
import importlib.util
import json
import math
import random
import statistics
import sys
from pathlib import Path

root = Path(sys.argv[1])
parent = root.parent
spec = importlib.util.spec_from_file_location('fixed', parent / 'analyze-interference.py')
fixed = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fixed)
before = (root / 'writer/summary.json').read_bytes()
fixed.analyze(root / 'writer')
assert (root / 'writer/summary.json').read_bytes() == before
original = json.loads(before)
settings = None


def audit(path):
    global settings
    row = json.loads(path.read_text())
    raw = row['samples_wait_schedule_claim_resume_timer_us_writer_bytes']
    assert len(raw) == 2000 and all(len(v) == 6 for v in raw)
    durations = sorted(sum(v[:5]) for v in raw)
    for name, fraction in [('p95_us', .95), ('p99_us', .99)]:
        assert math.isclose(row[name], durations[int(len(raw) * fraction)], rel_tol=1e-12)
    assert math.isclose(row['writer_thread_allocated_bytes_per_operation'],
                        statistics.mean(v[5] for v in raw), rel_tol=1e-12)
    assert row['offered_ops_per_second'] == 100 and row['throughput'] >= 99
    assert math.isclose(row['throughput'], 2000 / row['elapsed_seconds'], rel_tol=1e-9)
    assert row['poll_failure'] == 0
    if row['mode'] == 'projection-poll':
        assert row['poll_success'] == 80
    if row['mode'] == 'projection-feed':
        assert row['poll_success'] >= 8
    assert row['resources_after_clients'] == dict(views=0, connections=0, wake_pump=False)
    assert all(row['settings'][k] == 'on' for k in
               ('fsync', 'synchronous_commit', 'full_page_writes', 'autovacuum'))
    if settings is None:
        settings = row['settings']
    assert settings == row['settings']
    return row


records = [audit(p) for p in (root / 'writer').rglob('*.json') if p.name != 'summary.json']
replication = [audit(p) for p in (root / 'idle-replication').rglob('*.json')]
assert len(records) == 40 and len(replication) == 10
metrics = ['throughput', 'p95_us', 'p99_us', 'writer_thread_allocated_bytes_per_operation']
reports = {}
for label, dirs in [('discovery', ['writer']), ('replication', ['idle-replication']),
                    ('combined', ['writer', 'idle-replication'])]:
    rng = random.Random(327)
    reports[label] = []
    for metric in metrics:
        ratios, a, b = [], [], []
        for directory in dirs:
            for pair in range(1, 6):
                values = [json.loads((root / directory / side / str(pair) /
                           'projection-idle/1-projection-idle.json').read_text())[metric]
                          for side in ('baseline', 'candidate')]
                x, y = values
                a.append(x)
                b.append(y)
                ratios.append(x / y if metric == 'throughput' else y / x)
        boot = sorted(statistics.median(rng.choices(ratios, k=len(ratios))) for _ in range(20000))
        lo, hi = boot[499], boot[19499]
        reports[label].append(dict(metric=metric, pairs=len(ratios), ratios=ratios,
                                   baseline_median=statistics.median(a), candidate_median=statistics.median(b),
                                   median_ratio=statistics.median(ratios), ci95=[lo, hi],
                                   supported_degradation=lo > 1))

regressions = [r for r in original['results']
               if r['status'] == 'regression' and r['comparison'] != 'same-source'
               and r['mode'] != 'idle']
regressions += [r for r in reports['combined'] if r['supported_degradation']]
sql = json.loads((root / 'sql/summary.json').read_text())
assert sql['passed'] and len(sql['shapes']) == 8
for entry in json.loads((parent / 'identity.json').read_text())['binaries'].values():
    assert hashlib.sha256(Path(entry['path']).read_bytes()).hexdigest() == entry['sha256']
result = dict(candidate_commit='00fafcd47798e87d0b9c03a71a0eb385ce058471',
              original_precision_diagnostic_passed=original['passed'],
              background_activity_is_not_a_gate=True,
              precision_gate_was_an_unapproved_implementer_addition=True,
              valid_trials=50, writer_operations=100000, all_load_and_cleanup_checks_passed=True,
              sql_passed=True, sql_maximum_ratio=max(r['paired_median_ratio'] for r in sql['shapes']),
              idle=reports, supported_candidate_degradation=regressions,
              measured_acceptance_passed=not regressions,
              qualification='Finite matched evidence; no claim of zero loss or 1% equivalence.')
(root / 'assessment.json').write_text(json.dumps(result, indent=2) + '\n')
print(json.dumps(result, indent=2))
sys.exit(0 if result['measured_acceptance_passed'] else 1)
