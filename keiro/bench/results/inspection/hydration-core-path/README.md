# Ordinary hydration path comparison

Five alternating before/after pairs per case use the existing retention ledger
fixture, GHC 9.12.4, library O1, driver O2 and RTS `-N2 -T`. Before is commit
`842535ac`; `source.patch.gz` captures the candidate hydration/observation change.
The driver calls ordinary `hydrate`, with no mounted surface, and disables
sampled seed verification in both versions. Each leg measures 200 hydrations after
20 warmups on a fresh normally durable benchmark database. Cases cover compatible
snapshot hit, absent snapshot, corrupt JSON fallback, no codec and 10,000-event
full replay. The retained fixture source and binary/source hashes accompany raw
latency and allocation samples. `summary.json` reports paired percent changes.

The optimized ordinary worker excerpt contains no source/reason constructors;
inspection's continuation is separate after inlining. Source review confirms the
same owning store reads, seed scheduling and metrics behavior. This evidence
addresses the new continuation worker, not the initiative's integrated release
interference or domain retention checks. The historical command smoke used a
one-second timeout and timed out on large fanout cases; its CSV/log are retained
as diagnostics and are not acceptance evidence.

`driver.hs.txt` and `Fixture.hs.txt` preserve the exact compiler inputs. Copy
the driver to a `.hs` file and the fixture to `Retention/Fixture.hs` under the
source import path before compiling with the manifest flags.
