"""Validate all paired SQL observations, including the added parameterized probe."""
import json
import math
import statistics
import sys
from pathlib import Path


def flatten(value):
    if isinstance(value, dict):
        yield value
    else:
        for child in value:
            yield from flatten(child)


def nodes(plan, parents=()):
    yield plan, parents
    for child in plan.get('Plans', []):
        yield from nodes(child, parents + (plan,))


def samples(path):
    result = {}
    for row in flatten(json.loads(path.read_text())):
        key = row['groups'], row['mode'], row['deep'], row['sample']
        assert key not in result, f'duplicate {key}'
        assert row['returned'] == 100
        timing = row['plan'][0]['Execution Time']
        assert math.isfinite(timing) and timing > 0
        assert row['plan'][0]['Settings']['plan_cache_mode'] == row['mode']
        assert all(row['settings'][k] == 'on' for k in ('fsync', 'synchronous_commit', 'full_page_writes', 'autovacuum'))
        result[key] = row
    expected = {(n, m, d, s) for n in (10000, 100000) for m in ('force_custom_plan', 'force_generic_plan') for d in (False, True) for s in range(1, 6)}
    assert result.keys() == expected, 'missing/extra sample identities'
    return result


def validate_plan(row):
    root = row['plan'][0]['Plan']
    # Identify the added scalar subplan independently of the view's own lookups.
    probes = [(p, parents) for p, parents in nodes(root)
              if p.get('Relation Name') == 'keiro_projection_group_cursors'
              and p.get('Alias') == 'feeding_authority']
    assert len(probes) == 1, 'added lateral probe missing/ambiguous'
    probe, parents = probes[0]
    assert probe['Node Type'] in ('Index Scan', 'Index Only Scan')
    assert probe['Index Name'] == 'keiro_projection_group_cursors_pkey'
    assert probe['Actual Loops'] == 10
    assert "CASE WHEN status.serving_position_basis = 'checkpoint'" in row['sql']
    assert probe['Index Cond'] == '(group_id = page.group_id)'
    joins = [p for p in parents if p['Node Type'] == 'Nested Loop']
    assert any(any(n.get('CTE Name') == 'inspection_groups' for n, _ in nodes(p['Plans'][0])) for p in joins), 'page does not drive probe'
    assert root['Actual Rows'] == 101


def summarize(root):
    values = {}
    for pair in range(1, 4):
        baseline, candidate = (samples(root / f'{side}-{pair}.json') for side in ('baseline', 'candidate'))
        for key, before in baseline.items():
            after = candidate[key]
            assert before['settings'] == after['settings'], 'settings differ'
            assert before['models'] == after['models'] and before['arguments'] == after['arguments']
            validate_plan(after)
            shape = key[:3]
            entry = values.setdefault(shape, {'baseline_ms': [], 'candidate_ms': [], 'ratios': []})
            a, b = before['plan'][0]['Execution Time'], after['plan'][0]['Execution Time']
            entry['baseline_ms'].append(a)
            entry['candidate_ms'].append(b)
            entry['ratios'].append(b / a)
    rows = []
    for (groups, mode, deep), data in values.items():
        ratios = data['ratios']
        rows.append(dict(groups=groups, mode=mode, deep=deep,
                         baseline_median_ms=statistics.median(data['baseline_ms']),
                         candidate_median_ms=statistics.median(data['candidate_ms']),
                         paired_median_ratio=statistics.median(ratios),
                         minimum_ratio=min(ratios), maximum_ratio=max(ratios), ratios=ratios))
    return dict(passed=all(r['paired_median_ratio'] <= 1.10 for r in rows), shapes=rows)


if __name__ == '__main__':
    result = summarize(Path(sys.argv[1]))
    print(json.dumps(result, indent=2))
    sys.exit(0 if result['passed'] else 1)
