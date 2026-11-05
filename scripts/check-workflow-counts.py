#!/usr/bin/env python3
"""Compare counts to a complete list drain on a quiescent HTTP database."""
import argparse
import collections
import json
import urllib.parse
import urllib.request


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('base_url')
    parser.add_argument('--workflow-name')
    args = parser.parse_args()
    classes = ['running', 'retrying', 'sleeping', 'awaiting', 'completed', 'cancelled', 'failed']
    selection = {} if args.workflow_name is None else {'workflow_name': args.workflow_name}

    def get(kind, params):
        url = args.base_url.rstrip('/') + '/wf/inspect/' + kind + '?' + urllib.parse.urlencode(params)
        with urllib.request.urlopen(url, timeout=10) as response:
            return json.load(response)

    observed = get('counts', selection)
    counts = observed['counts']
    assert set(counts) == set(classes), counts
    assert all(type(n) is int and n >= 0 for n in counts.values()), counts
    actual = collections.Counter(dict.fromkeys(classes, 0))
    cursor = None
    seen = set()
    while True:
        params = dict(selection, limit=500)
        if cursor is not None:
            params['after'] = cursor
        page = get('list', params)
        for row in page['items']:
            assert row['status_class'] in classes, row
            actual[row['status_class']] += 1
        cursor = page.get('next_cursor')
        if cursor is None:
            break
        assert cursor not in seen, 'repeated cursor'
        seen.add(cursor)
    assert dict(actual) == counts, {'counts': counts, 'paged': dict(actual)}
    print('PASS: counts equal all listed instances', json.dumps(counts, sort_keys=True))


if __name__ == '__main__':
    main()
