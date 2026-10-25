import collections
import json
import re
import statistics
from pathlib import Path

root = Path('keiro/bench/results/harness-isolation-v1')
blocks = collections.defaultdict(list)
plans = {}
for line in (root / 'command-growth-durable-blocks.txt').read_text().splitlines():
    match = re.fullmatch(r'(FRESH|NOOP)_PROBE label=(\S+) block=(\d+)(?: events=\d+)? mean_ns=(\d+)', line)
    if match:
        kind, label, block, mean = match.groups()
        blocks[label, kind].append(int(mean) / 1000)
    elif line.startswith('{'):
        record = json.loads(line)
        plans[record['label']] = record

def nodes(value):
    if isinstance(value, dict):
        if 'Node Type' in value:
            yield value
        for child in value.values():
            yield from nodes(child)
    elif isinstance(value, list):
        for child in value:
            yield from nodes(child)

print('| Population | fresh median [range] (us) | no-op median [range] (us) |')
print('|---|---|---|')
for label in plans:
    formatted = []
    for kind in ['FRESH', 'NOOP']:
        values = blocks[label, kind]
        assert len(values) == 5, (label, kind, values)
        formatted.append(f'{statistics.median(values):.2f} [{min(values):.2f}, {max(values):.2f}]')
    print('|', label, '|', ' | '.join(formatted), '|')
    settings = plans[label]['counts']
    assert all(settings[k] == 'on' for k in ['fsync', 'synchronous_commit', 'full_page_writes', 'autovacuum'])
for kind in ['FRESH', 'NOOP']:
    early = statistics.median(blocks['grown-100000', kind])
    late = statistics.median(blocks['grown-3005000', kind])
    difference = abs(late / early - 1) * 100
    print(f'{kind}_EARLY_LATE_DIFFERENCE={difference:.2f}%')
    assert difference <= 10, (kind, difference)
late = plans['grown-3005000']
assert late['counts']['events'] == 3007500, late['counts']
assert late['counts']['streams'] == 3007501, late['counts']
assert late['counts']['stream_events'] == 6015000, late['counts']
assert any(n.get('Relation Name') == 'streams' and n.get('Index Name') == 'ix_streams_stream_name' for n in nodes(late['plan']))
assert max(blocks['grown-3005000', 'NOOP']) < 200
print('GROWTH_ACCEPTED=true')
