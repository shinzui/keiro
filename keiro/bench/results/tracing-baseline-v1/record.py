#!/usr/bin/env python3
"""Record five serial tracing samples without replacing historical baselines."""
import csv
import hashlib
import json
import platform
import statistics
import subprocess
from pathlib import Path

output = Path(__file__).resolve().parent
root = output.parents[3]

def run(command):
    return subprocess.check_output(command, cwd=root, text=True).strip()

binary = Path(run(['cabal', 'list-bin', 'keiro:bench:keiro-bench']))
metadata = {
    'revision': run(['git', 'rev-parse', 'HEAD']),
    'platform': platform.platform(),
    'machine': run(['sysctl', '-n', 'machdep.cpu.brand_string']),
    'ghc': run(['ghc', '--numeric-version']),
    'cabal': run(['cabal', '--numeric-version']),
    'postgres': run(['postgres', '--version']),
    'binary_sha256': hashlib.sha256(binary.read_bytes()).hexdigest(),
    'command': [str(binary), '-p', 'tracing', '-j1', '--time-mode', 'wall', '--hide-progress', '--stdev', '5', '--timeout', '10s', '+RTS', '-N2', '-RTS'],
}
if (output / 'environment.json').exists():
    raise SystemExit('Refusing to overwrite existing recording')
(output / 'environment.json').write_text(json.dumps(metadata, indent=2) + '\n')
all_rows = []
for sample in range(1, 6):
    target = output / f'sample-{sample}.csv'
    command = metadata['command'] + ['--csv', str(target)]
    with (output / f'sample-{sample}.log').open('w') as log:
        result = subprocess.run(command, cwd=root, stdout=log, stderr=subprocess.STDOUT)
    if result.returncode:
        raise SystemExit(f'Sample {sample} failed; preserve its log')
    with target.open() as handle:
        rows = list(csv.DictReader(handle))
    if len(rows) != 8 or (all_rows and [r['Name'] for r in rows] != [r['Name'] for r in all_rows[0]]):
        raise SystemExit('Unexpected tracing cell inventory')
    all_rows.append(rows)
with (output / 'baseline.csv').open('w') as handle:
    writer = csv.writer(handle)
    writer.writerow(['Name', 'Mean (ps)', '2*Stdev (ps)'])
    for index in range(8):
        writer.writerow([all_rows[0][index]['Name']] + [int(statistics.median(int(rows[index][key]) for rows in all_rows)) for key in ['Mean (ps)', '2*Stdev (ps)']])
with (output / 'pairs.md').open('w') as handle:
    handle.write('| Workload | No tracer (ms) | Tracer (ms) | Difference |\n|---|---:|---:|---:|\n')
    for index in range(0, 8, 2):
        plain, traced = [statistics.median(int(rows[i]['Mean (ps)']) for rows in all_rows) / 1e9 for i in [index, index + 1]]
        handle.write(f'| {all_rows[0][index]["Name"]} | {plain:.3f} | {traced:.3f} | {(traced / plain - 1) * 100:+.1f}% |\n')
