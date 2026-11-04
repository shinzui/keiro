import importlib.util,json,shutil,tempfile
from copy import deepcopy
from pathlib import Path
root=Path('keiro/bench/results/inspection/projection-status-feeding-subscriptions');spec=importlib.util.spec_from_file_location('summary',root/'summarize.py');m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)
source=json.loads((root/'loaded-sql-v4/candidate-1.json').read_text());row=next(m.flatten(source));m.validate_plan(row);assert m.summarize(root/'loaded-sql-v4')['passed']
checks={'complete final-source SQL cohort':'passed'}
def refuses(name,call):
 try:call()
 except (AssertionError,KeyError,ValueError):checks[name]='refused';return
 raise AssertionError(name+' was accepted')
for name,field,value in [('missing keyed probes','Actual Loops',1),('fleet scan','Node Type','Seq Scan'),('unbound probe','Index Cond','true')]:
 bad=deepcopy(row)
 for node,_ in m.nodes(bad['plan'][0]['Plan']):
  if node.get('Alias')=='feeding_authority':node[field]=value
 refuses(name,lambda:m.validate_plan(bad))
with tempfile.TemporaryDirectory(prefix='keiro-327-negative-') as d:
 p=Path(d)/'bad.json'
 for name,rows in [('missing samples',[row]),('duplicate sample',[row,row])]:
  p.write_text(json.dumps(rows));refuses(name,lambda:m.samples(p))
 for name,field,value in [('wrong API row count','returned',99),('nonpositive timing','timing',0)]:
  bad=deepcopy(source);first=next(m.flatten(bad))
  if field=='timing':first['plan'][0]['Execution Time']=value
  else:first[field]=value
  p.write_text(json.dumps(bad));refuses(name,lambda:m.samples(p))
 for side in ['baseline','candidate']:
  for pair in range(1,4):shutil.copy2(root/f'loaded-sql-v4/{side}-{pair}.json',Path(d)/f'{side}-{pair}.json')
 p=Path(d)/'candidate-1.json';bad=json.loads(p.read_text());next(m.flatten(bad))['settings']['server_version']='mismatched';p.write_text(json.dumps(bad));refuses('paired settings mismatch',lambda:m.summarize(Path(d)))
print(json.dumps(checks,indent=2))
