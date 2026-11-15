# Fixed-workload regression guards

Run `nix develop -c just bench-regression` or name one of the existing six groups.
The producer guard retains its 15 adjacent pairs and 1.10 ceiling. The five other
groups retain the existing workloads, within-run assertions, `-N2`, wall clock,
5% sampling goal, ten-second test timeout and 1.25 mean-ratio ceiling.

Their reference is immutable original recording source
`b8695a0d050c5b0db2f251887d43182da2b47eed`, built with today's Nix compiler and
measured on this machine. The historical CSVs remain visible diagnostics and the
required name inventory. They are not silently rewritten after an OS change.

The reference build cache lives under `dist-newstyle/benchmark-reference`.
Its executable and dependency plan are checksum-verified. Timings expire after
24 hours and are tied to the exact candidate executable and environment.
`release-gate --fresh` also forces fresh reference timings. Standalone guards
share the release workspace lock. A candidate change requires fresh reference timings. All required names must
exist; malformed/incomplete data cannot pass.

An over-budget result gets exactly two adjacent confirmations, in reverse orders,
within a 120-second family budget. Both mean ratios must pass to accept. Clear
excess cost in both is a regression; noisy, conflicting or unfinished comparisons
are inconclusive. Both block release, as do benchmark assertions and execution
errors. There is no retry-until-green loop.

Raw CSVs, logs, immutable reference identity, executable hashes, dependency plan
and per-case decisions are retained under `keiro/bench/results/release-gates`.
The release driver binds those files into stage receipts and rejects tampering.
A successful reference lookup does not bypass any correctness or artifact check.
Tracing groups acquire bracketed resources only when selected, and release them
before subsequent historical groups; listing/filtering does not force resource
handles. Existing quantity and retained-growth checks stay active.
