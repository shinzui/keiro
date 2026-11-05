# Final candidate: paired runtime evidence

**PASS:** five alternating unpaced pairs and five complete paced blocks on one
million balanced-class headers plus 100,000 timers. The final candidate disables
PostgreSQL parallel workers in the dedicated inspection pool; four admitted
requests and the existing two/five-second SQL/handler limits remain unchanged.
No schema or ordinary writer setting changes support this read.

The fixed paced rate was 210 writer operations/second, selected as 50% of the
slowest measured baseline capacity, rounded down to ten. Every leg passed the
existing scheduling-headroom check. Parent RTS settings were `-N2 -T`; HTTP
clients were separate processes using the compiled `-N8` default. The exact
commands, binaries/source hashes, hardware, durable settings, raw samples,
WAL/update counters and ambient diagnostics are retained in `manifest.json`,
the per-leg artifacts and logs. Builds/tests did not run alongside these legs.
Ambient processes were diagnostic and never automatically rejected a leg.

Paired median percentage changes (candidate/control; negative latency or
allocation is lower cost):

| Comparison | Throughput | Writer p95 | Writer bytes/op |
| --- | ---: | ---: | ---: |
| Unpaced capacity | -0.237% | +0.848% | -0.003% |
| Paced unmounted | +0.005% | +1.607% | +0.013% |
| Mounted idle | -0.003% | +2.649% | -0.026% |
| One count client vs idle | -0.001% | -2.677% | -0.014% |
| Eight count clients vs idle | -0.000% | -2.683% | +0.007% |
| One count client vs unmounted | +0.002% | -3.923% | +0.003% |
| Eight count clients vs unmounted | +0.003% | -3.449% | +0.012% |

All existing 5% ceilings passed. The analyzer also rejects a smaller loss
when every paired result consistently exceeds 1%; no comparison triggered it.
Its negative control rejects deliberately degraded capacity, latency and
allocation. `comparisons.json` retains all individual paired changes and ranges.

There is real timing spread: capacity paired throughput changes ranged from
-3.28% to +2.36%; p95 comparisons include wider individual swings. The capacity
median was -0.237%, p95 +0.848%, and writer allocation -0.003%. Signs were mixed,
ordinary-path source work was unchanged, and no reproducible attributable loss
was established. Treat the active-read negative p95 medians as absence of an
observed regression in this experiment, not evidence that polling accelerates
writers. No threshold or existing baseline was moved.

The five single-client legs completed **100 successful count reads, zero
failures**. The eight-client legs completed **400 successful reads and 400
admission refusals**, as expected from aligned bursts over four slots. Every
burst leg also completed an uncounted successful recovery request afterward.
No SQL/handler timeout or unexpected response was accepted. The seven-class
JSON was validated by the external clients.

Every measured writer operation retained real schedule, retry/reset,
suspend/resume, claim, named step, completion, lease release and timer
schedule/claim/fire work. Header-update counters equal exactly eight updates
per completed operation in all forty legs. Runtime allocation is attributed
with the writer thread allocation counter; whole-process allocation is only
diagnostic. No new per-instance counting state, event reads or maintenance
was added to ordinary runtime paths.

The supported measured polling envelope is one unfiltered read per second,
or the tested eight-client aligned overload mixture of unfiltered, common,
rare and absent names, at this dataset and offered writer rate. The default
admission refusal is part of overload behavior; no all-refusal run qualifies.
This is an observed envelope, not a universal zero-cost guarantee for larger
populations, other connection policies or arbitrary cadences.

The earlier actual burst failure and its original frozen candidate remain
in `../runtime-paired/`; the interrupted original quiet-machine attempt is
in `../runtime/`. They are not substituted for these final-source results.

Reanalyze from the repository root inside the Nix shell:

```bash
python3 scripts/analyze-workflow-counts.py --self-test
python3 scripts/analyze-workflow-counts.py keiro/bench/results/workflow-counts/runtime-serial
```
