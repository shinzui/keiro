import json
import statistics
from pathlib import Path

root = Path('keiro/bench/results/producer-attribution-v2')
rows = [json.loads(line) for line in (root / 'probe-2.jsonl').read_text().splitlines()]
expected = {'fresh-factory-statements-legacy-producer-lookup': [0, 1000, 0], 'replay-factory-statements-legacy-producer-lookup': [0, 1000, 1000], 'legacy-same-envelope-statements-legacy-producer-lookup': [1000, 0, 0]}
for phase, counts in expected.items():
    assert next(r['data'] for r in rows if r['phase'] == phase) == counts
    print(phase, counts)
print('\n| Preparation for 1,000 events | median (ms) | range (ms) |\n|---|---:|---:|')
for phase in ['legacy-actual-preparation', 'deterministic-equivalent-preparation']:
    values = [r['data']['elapsed_ns'] / 1e6 for r in rows if r['phase'] == phase]
    assert len(values) == 5
    print(f'| {phase} | {statistics.median(values):.3f} | {min(values):.3f}–{max(values):.3f} |')
print('\n| Prepared SQL inputs | transaction shape | legacy median (ms) | deterministic median (ms) | median paired ratio |\n|---|---|---:|---:|---:|')
for identical in [True, False]:
    for batch in [True, False]:
        values = {flag: [r['data']['elapsed_ns'] / 1e6 for r in rows if r['phase'] == 'prepared-enqueue' and r['data']['identical_envelopes'] == identical and r['data']['batch'] == batch and r['data']['deterministic'] == flag] for flag in [False, True]}
        assert all(len(v) == 5 for v in values.values())
        ratio = statistics.median(d / l for l, d in zip(values[False], values[True]))
        print(f'| {"identical envelopes" if identical else "each path actual identity layout"} | {"one batch" if batch else "one per event"} | {statistics.median(values[False]):.3f} | {statistics.median(values[True]):.3f} | {ratio:.4f} |')
assert all(r['data']['events'] == 1000 for r in rows if r['phase'] == 'prepared-enqueue')
print('\nPRODUCER_PROBE_ACCEPTED=true')
