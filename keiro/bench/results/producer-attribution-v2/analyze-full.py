import json
import statistics
from pathlib import Path

root = Path('keiro/bench/results/producer-attribution-v2')
rows = [json.loads(line) for line in (root / 'probe-3.jsonl').read_text().splitlines()]
assert not (root / 'probe-3.stderr').read_text()
print('| Actual full workload, 1,000 events | legacy median ms | deterministic median ms | paired ratio median | paired ratio range | paired delta median ms |')
print('|---|---:|---:|---:|---:|---:|')
for batch in [True, False]:
    samples = {}
    for row in rows:
        if row['phase'] != 'full-factory' or row['data']['batch'] != batch:
            continue
        data = row['data']
        assert data['events'] == 1000 and data['elapsed_ns'] > 0
        key = (data['sample'], data['deterministic'])
        assert key not in samples
        samples[key] = data['elapsed_ns'] / 1e6
    assert samples.keys() == {(i, flag) for i in range(1, 16) for flag in [False, True]}
    legacy = [samples[i, False] for i in range(1, 16)]
    deterministic = [samples[i, True] for i in range(1, 16)]
    ratios = [d / l for l, d in zip(legacy, deterministic)]
    deltas = [d - l for l, d in zip(legacy, deterministic)]
    print(f'| {"one batch" if batch else "one per event"} | {statistics.median(legacy):.3f} | {statistics.median(deterministic):.3f} | {statistics.median(ratios):.4f} | {min(ratios):.4f}–{max(ratios):.4f} | {statistics.median(deltas):.3f} |')
print('\nFULL_FACTORY_PROBE_COMPLETE=true; 15 alternating pairs per transaction shape')
