#!/usr/bin/env python3
"""Serial paired workflow-count measurements and their failing analyzer."""
import hashlib
import json
import math
import os
from pathlib import Path
import statistics
import subprocess
import sys


METRICS = ['throughput', 'p95_us', 'writer_thread_allocated_bytes_per_operation']


def read(path):
    return json.loads(Path(path).read_text())


def write(path, value):
    Path(path).write_text(json.dumps(value, indent=2) + '\n')


def digest(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def changes(pairs):
    result = {}
    for metric in METRICS:
        values = [b[metric] / a[metric] - 1 for a, b in pairs]
        median = statistics.median(values)
        harm = -median if metric == 'throughput' else median
        # A consistent smaller loss is investigated too, not silently accepted
        # just because it falls below the existing 5% rejection ceiling.
        consistent = all((-v if metric == 'throughput' else v) > 0.01 for v in values)
        result[metric] = {'paired_changes': values, 'median_change': median,
                          'range': [min(values), max(values)],
                          'passed': harm <= 0.05 and not consistent}
    return result


def headroom(row, rate):
    waits = [s[0] for s in row['samples_wait_schedule_claim_resume_timer_us_writer_bytes']]
    tenth = max(1, len(waits) // 10)
    growth = statistics.fmean(waits[-tenth:]) - statistics.fmean(waits[:tenth])
    return row['throughput'] >= rate * 0.99 and growth <= 20000


def analyze(output):
    manifest = read(output / 'manifest.json')
    comparisons = {}
    for label, phase, baseline, candidate in [
        ('capacity', 'capacity', 'baseline-disabled', 'candidate-disabled'),
        ('unmounted', 'paced', 'baseline-disabled', 'candidate-disabled'),
        ('mounted-idle', 'paced', 'baseline-idle', 'candidate-idle'),
        ('counts-vs-idle', 'paced', 'baseline-idle', 'candidate-wf-counts'),
        ('counts-many-vs-idle', 'paced', 'baseline-idle', 'candidate-wf-counts-many'),
        ('counts-total', 'paced', 'baseline-disabled', 'candidate-wf-counts'),
        ('counts-many-total', 'paced', 'baseline-disabled', 'candidate-wf-counts-many'),
    ]:
        pairs = []
        for block in range(1, 6):
            rows = []
            for leg in [baseline, candidate]:
                mode = leg.split('-', 1)[1]
                row = read(output / phase / str(block) / leg / f'1-{mode}.json')
                assert row['workflow_rows'] == 1000000 and row['counts_workload'] is True
                assert row['measurement_seconds'] >= 20
                assert row['completed_operations'] > 0
                if phase == 'capacity':
                    assert row['offered_ops_per_second'] is None and row['elapsed_seconds'] >= 20
                else:
                    assert row['offered_ops_per_second'] == manifest['offered_rate']
                    assert headroom(row, manifest['offered_rate']), f'growing queue: {leg}'
                if mode.startswith('wf-counts'):
                    clients = 8 if mode.endswith('many') else 1
                    assert row['poll_success'] > 0
                    assert row['poll_success'] + row['poll_failure'] == clients * row['measurement_seconds']
                    if clients == 1:
                        assert row['poll_failure'] == 0
                rows.append(row)
            pairs.append(tuple(rows))
        comparisons[label] = changes(pairs)
    write(output / 'comparisons.json', comparisons)
    for label, metrics in comparisons.items():
        print(label, {key: round(value['median_change'] * 100, 3) for key, value in metrics.items()}, flush=True)
    passed = all(m['passed'] for metrics in comparisons.values() for m in metrics.values())
    print('WORKFLOW_COUNTS=' + ('PASSED' if passed else 'FAILED'), flush=True)
    return passed


def measure(baseline, candidate, output):
    assert not output.exists(), 'refusing to overwrite measurements'
    evidence = Path('keiro/bench/results/workflow-counts/binaries')
    for role, binary in [('baseline', baseline), ('candidate', candidate)]:
        assert digest(binary) == (evidence / f'{role}-sha256.txt').read_text().strip(), f'{role} hash differs'
    output.mkdir(parents=True)
    seconds = int(os.environ.get('KEIRO_INSPECTION_SECONDS', '20'))
    assert seconds >= 20
    environment = dict(os.environ, KEIRO_INSPECTION_WORKFLOW_ROWS='1000000', KEIRO_COUNTS_WORKLOAD='1', KEIRO_INSPECTION_SECONDS=str(seconds))
    assert 'KEIRO_INSPECTION_RETENTION_SECONDS' not in environment
    manifest = {'baseline': str(baseline), 'candidate': str(candidate),
                'baseline_sha256': digest(baseline), 'candidate_sha256': digest(candidate),
                'fixture_rows': 1000000, 'measurement_seconds': seconds, 'blocks': 5,
                'distribution': 'balanced seven classes; ~90% seed-common; rare n%997=0; other 31 names; timers=100000',
                'workload': 'schedule, crash retry/reset, suspend/resume, claim, named step, complete, release, schedule/claim/fire timer',
                'rts': ['-N2', '-T'], 'writer_pool_size': 1, 'inspection_admission': 4,
                'statement_timeout_ms': 2000, 'read_deadline_seconds': 5,
                'hardware': read_text('keiro/bench/results/workflow-counts/environment.txt'),
                'harness_sha256': digest('keiro-ops-http/bench/InspectionInterference.hs'),
                'clients_sha256': digest('keiro-ops-http/bench/InspectionClients.hs'),
                'controller_sha256': digest(__file__), 'legs': []}

    def run(phase, block, role, mode, rate):
        directory = output / phase / str(block) / f'{role}-{mode}'
        directory.parent.mkdir(parents=True, exist_ok=True)
        binary = baseline if role == 'baseline' else candidate
        command = [str(binary), str(directory), str(rate), '1', mode, '+RTS', '-N2', '-T', '-RTS']
        manifest['legs'].append({'phase': phase, 'block': block, 'role': role, 'mode': mode, 'command': command})
        write(output / 'manifest.json', manifest)
        with (directory.parent / f'{role}-{mode}.log').open('w') as log:
            subprocess.run(command, env=environment, check=True, stdout=log, stderr=subprocess.STDOUT)
        row = read(directory / f'1-{mode}.json')
        print(phase, block, role, mode, 'ops/s', round(row['throughput'], 2), 'p95_us', round(row['p95_us'], 2), 'polls', row['poll_success'], row['poll_failure'], flush=True)
        return row

    capacities = []
    for block in range(1, 6):
        roles = ['baseline', 'candidate'] if block % 2 else ['candidate', 'baseline']
        for role in roles:
            row = run('capacity', block, role, 'disabled', 'saturation')
            if role == 'baseline':
                capacities.append(row['throughput'])
    # A fixed 50% of the slowest baseline leaves explicit headroom (<75%).
    rate = min(1000, math.floor(min(capacities) * 0.5 / 10) * 10)
    assert rate > 0
    manifest['offered_rate'] = rate
    legs = [('baseline', 'disabled'), ('baseline', 'idle'), ('candidate', 'disabled'), ('candidate', 'idle'), ('candidate', 'wf-counts'), ('candidate', 'wf-counts-many')]
    for block in range(1, 6):
        for role, mode in (legs if block % 2 else list(reversed(legs))):
            row = run('paced', block, role, mode, rate)
            assert headroom(row, rate), 'fixed offered rate has insufficient scheduling headroom; retain cohort'
    write(output / 'manifest.json', manifest)
    return analyze(output)


def read_text(path):
    return Path(path).read_text()


def self_test():
    normal = {'throughput': 100, 'p95_us': 100, 'writer_thread_allocated_bytes_per_operation': 100}
    for degraded in [dict(normal, throughput=90), dict(normal, p95_us=110), dict(normal, writer_thread_allocated_bytes_per_operation=110), dict(normal, p95_us=102)]:
        assert not all(v['passed'] for v in changes([(normal, degraded)] * 5).values())
    assert all(v['passed'] for v in changes([(normal, normal)] * 5).values())
    print('PASS: degraded capacity, latency, allocation and consistent smaller loss are rejected')


if __name__ == '__main__':
    if sys.argv[1:] == ['--self-test']:
        self_test()
    elif len(sys.argv) == 5 and sys.argv[1] == '--measure':
        sys.exit(0 if measure(Path(sys.argv[2]).resolve(), Path(sys.argv[3]).resolve(), Path(sys.argv[4])) else 1)
    elif len(sys.argv) == 2:
        sys.exit(0 if analyze(Path(sys.argv[1])) else 1)
    else:
        sys.exit('expected OUTPUT_DIRECTORY, --self-test, or --measure BASELINE CANDIDATE OUTPUT_DIRECTORY')
