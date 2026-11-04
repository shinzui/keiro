"""Reject missing workloads; retain every matched trial and active/idle ratio."""
import json
import math
import random
import statistics
import sys
from pathlib import Path


def analyze(root):
    data = {}
    settings = None
    for side in ('baseline', 'candidate'):
        for pair in range(1, 6):
            for mode in ('idle', 'poll', 'feed'):
                row = json.loads((root / side / str(pair) / f'projection-{mode}' / f'1-projection-{mode}.json').read_text())
                raw = row['samples_wait_schedule_claim_resume_timer_us_writer_bytes']
                assert len(raw) == 2000 and all(len(r) == 6 for r in raw)
                assert row['offered_ops_per_second'] == 100 and row['throughput'] >= 99
                assert math.isclose(row['throughput'], 2000 / row['elapsed_seconds'], rel_tol=1e-9)
                assert row['poll_failure'] == 0
                if mode == 'poll': assert row['poll_success'] == 80
                if mode == 'feed': assert row['poll_success'] >= 4
                assert row['resources_after_clients'] == dict(views=0, connections=0, wake_pump=False)
                assert all(row['settings'][k] == 'on' for k in ('fsync', 'synchronous_commit', 'full_page_writes', 'autovacuum'))
                if settings is None: settings = row['settings']
                assert row['settings'] == settings
                data[side, pair, mode] = row
    controls = {}
    for label in ('control-a', 'control-b'):
        controls[label] = [json.loads((root / label / str(p) / '1-projection-idle.json').read_text()) for p in range(1, 6)]
        for row in controls[label]:
            assert len(row['samples_wait_schedule_claim_resume_timer_us_writer_bytes']) == 2000
            assert row['throughput'] >= 99 and row['settings'] == settings
    results = []
    for mode in ('idle', 'poll', 'feed'):
        for metric in ('throughput', 'p95_us', 'p99_us', 'writer_thread_allocated_bytes_per_operation'):
            a = [data['baseline', p, mode][metric] for p in range(1, 6)]
            b = [data['candidate', p, mode][metric] for p in range(1, 6)]
            assert all(math.isfinite(x) and x > 0 for x in a + b)
            ratios = [x / y if metric == 'throughput' else y / x for x, y in zip(a, b)]
            results.append(dict(mode=mode, metric=metric, comparison='candidate/baseline', ratios=ratios,
                                baseline_median=statistics.median(a), candidate_median=statistics.median(b),
                                median_ratio=statistics.median(ratios)))
            if mode != 'idle':
                idle_ratios = [data['baseline', p, 'idle'][metric] / data['candidate', p, 'idle'][metric]
                               if metric == 'throughput' else
                               data['candidate', p, 'idle'][metric] / data['baseline', p, 'idle'][metric]
                               for p in range(1, 6)]
                interaction = [r / idle for r, idle in zip(ratios, idle_ratios)]
                results.append(dict(mode=mode, metric=metric, comparison='active/idle candidate versus baseline',
                                    ratios=interaction, median_ratio=statistics.median(interaction)))
    for metric in ('throughput', 'p95_us', 'p99_us', 'writer_thread_allocated_bytes_per_operation'):
        a, b = ([r[metric] for r in controls[label]] for label in ('control-a', 'control-b'))
        ratios = [x / y if metric == 'throughput' else y / x for x, y in zip(a, b)]
        results.append(dict(mode='idle', metric=metric, comparison='same-source', ratios=ratios,
                            median_ratio=statistics.median(ratios)))
    rng = random.Random(327)
    for row in results:
        boot = sorted(statistics.median(rng.choices(row['ratios'], k=5)) for _ in range(20000))
        lo, hi = boot[499], boot[19499]
        row['ci95'] = [lo, hi]
        row['status'] = 'regression' if lo > 1 else 'inconclusive' if hi >= 1.01 else 'passed'
        if row['comparison'] == 'same-source' and lo <= 1 / 1.01:
            row['status'] = 'inconclusive'
    report = dict(passed=all(r['status'] == 'passed' for r in results), seed=327, resamples=20000, results=results)
    (root / 'summary.json').write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps(report, indent=2))
    return report['passed']


if __name__ == '__main__':
    sys.exit(0 if analyze(Path(sys.argv[1])) else 1)
