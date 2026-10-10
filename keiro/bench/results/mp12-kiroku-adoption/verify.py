import subprocess, json, time
from pathlib import Path
root = Path(__file__).resolve().parents[4]
out = root / 'keiro/bench/results/mp12-kiroku-adoption'
start = time.monotonic()
budget = 1000
journal = {'budget_seconds': budget, 'actions': []}
for name, target, package in [('full-keiro', 'keiro:keiro-test', 'keiro'), ('keiro-ops', 'keiro-ops:keiro-ops-test', 'keiro-ops')]:
    binary = subprocess.check_output(['cabal', 'list-bin', target], cwd=root, text=True).strip()
    action = {'name': name, 'binary': binary, 'cwd': package}
    journal['actions'].append(action)
    with (out / (name + '.log')).open('w') as log:
        try:
            result = subprocess.run([binary], cwd=root / package, stdout=log, stderr=subprocess.STDOUT, timeout=max(1, budget - (time.monotonic() - start)))
            action['exit_code'] = result.returncode
        except subprocess.TimeoutExpired:
            action['timeout'] = True
            action['exit_code'] = 124
    action['elapsed_seconds'] = time.monotonic() - start
    (out / 'test-journal.json').write_text(json.dumps(journal, indent=2) + '\n')
    print(name, action, flush=True)
    if action['exit_code']:
        raise SystemExit(action['exit_code'])
