import argparse
import csv
import io
import math
import statistics
from pathlib import Path

parser = argparse.ArgumentParser()
parser.add_argument('--apply', action='store_true', help='apply validated median candidates to the five existing baselines')
args = parser.parse_args()
root = Path('keiro/bench/results')
inventory = set((root / 'harness-isolation-v1/checkpoint-list-tests.txt').read_text().splitlines())
payloads = []
for group in ['command', 'outbox', 'inbox', 'projection', 'read-model']:
    folder = root / f'{group}-v2'
    target = Path('keiro/bench') / f'baseline-{group}.csv'
    old = list(csv.reader(target.open()))
    assert old[0] == ['Name', 'Mean (ps)', '2*Stdev (ps)'], (target, old[0])
    expected = {name for name in inventory if group in name}
    samples = []
    for sample in range(1, 6):
        assert (folder / f'sample-{sample}.txt').read_text().rstrip().endswith('PROCESS_EXIT=0')
        raw = list(csv.reader((folder / f'sample-{sample}.csv').open()))
        assert raw[0] == old[0]
        rows = {r[0]: (float(r[1]), float(r[2])) for r in raw[1:]}
        assert len(raw) - 1 == len(rows) and rows.keys() == expected, (group, sample, expected - rows.keys())
        assert all(math.isfinite(m) and m > 0 and math.isfinite(s) and s >= 0 for m, s in rows.values())
        assert not any(x.startswith('{') for x in (folder / f'sample-{sample}.stderr').read_text().splitlines()), 'timed probes enabled'
        samples.append(rows)
    output = io.StringIO(newline='')
    writer = csv.writer(output, lineterminator='\n')
    writer.writerow(old[0])
    summary = ['| Row | median mean (ms) | median 2σ (ms) | mean range (ms) |', '|---|---:|---:|---:|']
    for row in old[1:]:
        name = row[0]
        means = [sample[name][0] for sample in samples]
        spreads = [sample[name][1] for sample in samples]
        mean, spread = statistics.median(means), statistics.median(spreads)
        writer.writerow([name, format(mean, '.17g'), format(spread, '.17g')])
        summary.append(f'| {name} | {mean / 1e9:.6f} | {spread / 1e9:.6f} | {min(means) / 1e9:.6f}–{max(means) / 1e9:.6f} |')
    payloads.append((folder, target, output.getvalue(), '\n'.join(summary) + '\n'))
for folder, target, candidate, summary in payloads:
    original = folder / 'original-baseline.csv'
    if not original.exists():
        original.write_bytes(target.read_bytes())
    else:
        assert target.read_bytes() in [original.read_bytes(), candidate.encode()], f'unexpected baseline edits: {target}'
    (folder / 'candidate-baseline.csv').write_text(candidate)
    (folder / 'summary.md').write_text(summary)
    if args.apply:
        target.write_text(candidate)
    print(f'{target}: {len(candidate.splitlines()) - 1} median rows; five complete serial samples; applied={args.apply}')
