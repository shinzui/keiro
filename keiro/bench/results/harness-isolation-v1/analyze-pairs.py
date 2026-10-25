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
accepted=True
print('| Command row | filtered means (us) | full means (us) | median absolute paired difference |')
print('|---|---|---|---|')
for name in sorted(expected):
    for a,b in pairs:
        assert name in a and name in b,('missing',name)
    filtered=[a[name][0] for a,b in pairs]; full=[b[name][0] for a,b in pairs]
    differences=[abs(b/a-1)*100 for a,b in zip(filtered,full)]
    difference=statistics.median(differences)
    accepted &= difference<=10
    print('|',name.removeprefix('All.command.'),'|',', '.join(f'{x/1e6:.1f}' for x in filtered),'|',', '.join(f'{x/1e6:.1f}' for x in full),'|',f'{difference:.2f}%','|')
    if name.endswith(('no-op','rejected')):
        accepted &= max(filtered+full)<200e6
print('PAIR_ACCEPTED='+str(accepted).lower())
for a,b in pairs:
    for coordinator in ['router','process-manager']:
        times=[a[f'All.command.domain.{coordinator}-fanout.{n}'][0] for n in [10,100,1000]]
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
