"""Retain the user's acceptance decision separately from the original controller."""
import hashlib
import json
from pathlib import Path
import subprocess

candidate = 'bc4799c33f953dada4685031020aa898591c23c6'
subprocess.run(['git', 'diff', '--quiet', candidate, '--', '.', ':!docs',
                ':!keiro/bench/results'], check=True)

root = Path('keiro/bench/results/pm-types')
analysis_path = root / 'matched-v2/analysis.json'
analysis = json.loads(analysis_path.read_text())
assert analysis['pairs'] == 5 and len(analysis['results']) == 32
accepted_allocation = ('many-polling', 'writer_thread_allocated_bytes_per_operation')
results = []
for item in analysis['results']:
    supported = item['ci95'][0] > 1
    decision = 'no-supported-regression'
    if supported:
        assert (item['comparison'], item['metric']) == accepted_allocation, item
        assert item['median'] == 1.0000878343498232, item
        decision = 'observed-allocation-overhead-accepted-by-user'
    results.append({**item, 'original_status': item['status'], 'status': 'accepted',
                    'acceptance_reason': decision})

files = sorted((root / 'matched-v2').glob('*/*/*.json'))
assert len(files) == 60
successful_polls = 0
for path in files:
    item = json.loads(path.read_text())
    samples = item['samples_wait_schedule_claim_resume_timer_us_writer_bytes']
    assert len(samples) == 1000 and all(len(row) == 6 for row in samples), path
    assert item['poll_failure'] == 0, path
    if item['mode'] in ('pm-types', 'pm-types-many'):
        assert item['poll_success'] == 80, path
        assert item['resources_after_clients'] == dict(views=0, connections=0, wake_pump=False)
    successful_polls += item['poll_success']
assert successful_polls == 800

retention = []
for family, mode in [('single', 'pm-types'), ('many', 'pm-types-many')]:
    path = root / f'retention-{family}-v2/1-{mode}.json'
    item = json.loads(path.read_text())
    assert item['poll_success'] == 240 and item['poll_failure'] == 0
    assert item['resources_after_clients'] == dict(views=0, connections=0, wake_pump=False)
    retention.append(dict(path=str(path), successful_polls=240, failed_polls=0,
                          lifecycle_after=item['lifecycle_after'],
                          resources_after_clients=item['resources_after_clients']))

gate = Path('keiro/bench/results/release-gates/20261026T215310Z-bc4799c3.log')
gate_text = gate.read_text()
assert '\nVERIFY_EXIT=0\n' in gate_text and '\nBENCH_EXIT=0\n' in gate_text
for name in ('producer-identity', 'outbox', 'inbox', 'command', 'projection', 'read-model'):
    assert f'\nGUARD({name})=0\n' in gate_text

predecessor = json.loads((root / 'matched-v1/analysis.json').read_text())
predecessor_timing_regressions = [item for item in predecessor['results']
                                if item['metric'] != 'writer_thread_allocated_bytes_per_operation'
                                and item['ci95'][0] > 1]
assert any(item['comparison'] == 'many-polling' and item['metric'] == 'p99_us'
           for item in predecessor_timing_regressions)

def sha256(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()

report = dict(
    status='accepted', candidate=candidate,
    plan='docs/plans/323-list-mounted-process-managers-without-runtime-performance-regressions.md',
    decision_date='2026-10-26',
    user_instructions=[
        "a small allocation overhead is fine it's only 0.009%",
        'for latency measurement we should also accept unless there is a regression',
    ],
    timing_policy='Reject statistically supported degradation (CI95 lower ratio > 1); retain uncertainty without a separate 1% resolution gate.',
    allocation_policy='Accept the observed final-cohort overhead; this decision establishes no general allowance for larger future increases.',
    original_analysis=dict(path=str(analysis_path), sha256=sha256(analysis_path),
                           status=analysis['status'], preserved=True),
    original_controller_policy_preserved=True,
    trials=60, successful_polls=800, failed_polls=0,
    raw_trial_sha256={str(path): sha256(path) for path in files},
    results=results, retention=retention,
    release_gate=dict(path=str(gate), sha256=sha256(gate), verify_exit=0, bench_exit=0),
    rejected_predecessor_timing_regressions=predecessor_timing_regressions,
    limitations='Intervals do not all exclude a 1% loss; acceptance does not prove exact equality or attribute the small allocation increase to a measurement artifact.',
)
destination = root / 'acceptance-review.json'
destination.write_text(json.dumps(report, indent=2) + '\n')
print(f'{destination}: accepted; 60 complete trials, 800 successful polls, no supported timing regression')
print('Rejected predecessor still has supported timing regressions under the revised policy')
