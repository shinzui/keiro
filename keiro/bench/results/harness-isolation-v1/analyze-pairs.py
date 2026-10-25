import csv,json,statistics,sys
from pathlib import Path
root=Path(sys.argv[1] if len(sys.argv)>1 else 'keiro/bench/results/harness-isolation-v1')
def rows(path):
    with path.open(newline='') as h:
        reader=csv.reader(h)
        header=next(reader)
        assert 'ps' in header[1],header
        return {r[0]:(float(r[1]),float(r[2])) for r in reader if r and r[0].startswith('All.')}
pairs=[(rows(root/f'pair-{p}-filtered.csv'),rows(root/f'pair-{p}-full.csv')) for p in [1,2,3]]
expected={r[0] for r in csv.reader(open('keiro/bench/baseline-command.csv')) if r and r[0].startswith('All.command.')}
assert len(expected)==15
inventory=set((root/'accepted-list-tests.txt').read_text().splitlines())
assert len(inventory)==96, ('inventory',len(inventory))
previous={line.strip() for line in (root/'final-list-tests-v2.txt').read_text().splitlines() if line.strip().startswith('All.')}
assert inventory==previous, ('renamed cases',previous-inventory,inventory-previous)
for baseline in Path('keiro/bench').glob('baseline-*.csv'):
    required={r[0] for r in csv.reader(baseline.open()) if r and r[0].startswith('All.')}
    assert required<=inventory, ('missing baseline names',baseline,required-inventory)
for pair,(filtered,full) in enumerate(pairs,1):
    assert filtered.keys()==expected, ('filtered names',pair,expected-filtered.keys(),filtered.keys()-expected)
    assert full.keys()==inventory, ('full names',pair,inventory-full.keys(),full.keys()-inventory)
    setup=(root/f'pair-{pair}-filtered.setup.log').read_text()
    assert all('group='+group not in setup for group in ['delegated-inbox','read-model','inbox','outbox','rebuild','producer-identity']), ('unselected setup',pair)
    for selection in ['filtered','full']:
        assert not any(line.startswith('{') for line in (root/f'pair-{pair}-{selection}.setup.log').read_text().splitlines()), ('timed probes enabled',pair,selection)

accepted=True
print('| Command row | filtered means ±2σ (us) | full means ±2σ (us) | median absolute paired difference |')
print('|---|---|---|---|')
for name in sorted(expected):
    for a,b in pairs:
        assert name in a and name in b,('missing',name)
    filtered=[a[name][0] for a,b in pairs]; full=[b[name][0] for a,b in pairs]
    differences=[abs(b/a-1)*100 for a,b in zip(filtered,full)]
    difference=statistics.median(differences)
    accepted &= difference<=10
    print('|',name.removeprefix('All.command.'),'|',', '.join(f'{a[name][0]/1e6:.1f} ±{a[name][1]/1e6:.1f}' for a,b in pairs),'|',', '.join(f'{b[name][0]/1e6:.1f} ±{b[name][1]/1e6:.1f}' for a,b in pairs),'|',f'{difference:.2f}%','|')
    if name.endswith(('no-op','rejected')):
        accepted &= max(filtered+full)<200e6
print('PAIR_ACCEPTED='+str(accepted).lower())
for a,b in pairs:
    for coordinator in ['router','process-manager']:
        for selected in [a,b]:
            times=[selected[f'All.command.domain.{coordinator}-fanout.{n}'][0] for n in [10,100,1000]]
            assert times==sorted(times),(coordinator,times)
for p,(_,full) in enumerate(pairs,1):
    for name in sorted(full):
        if '.fresh.metrics-off' in name:
            twin=name.removesuffix('off')+'on'
            delta=abs(full[name][0]/full[twin][0]-1)*100
            print(f'INBOX_TWIN pair={p} scenario={name} difference={delta:.2f}%')
            accepted &= delta<=25
print('HARNESS_TIMING_ACCEPTED='+str(accepted).lower())
sys.exit(0 if accepted else 1)
