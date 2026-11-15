# Focused released-version control

Exact `keiro-0.24.0.0` was extracted with `git archive` and its `keiro:bench:keiro-bench`
target built using the current project's Nix development shell. The source archive
was unmodified. `inputs.json` records source revisions, executable checksums and
exact commands. Both dependency plans and the original build/measurement logs are
retained. External versions differ only for the intentionally upgraded Shibuya
cohort; all other common external versions match.

One existing `legacy.no-op` case ran serially in previous/candidate order with the
standard `-N2`, wall-time, 5% deviation and ten-second timeout settings. The
identified Node service was temporarily suspended and resumed in a `finally` block.
The measurements were 23.433 us for 0.24 and 23.050 us for 0.25 (ratio 0.984).
The already released version also exceeds the historical CSV threshold in this
environment. This one-case, one-pair observation does not establish a cause for
every failed guard or replace release acceptance. The historical recording used
Darwin 27.0; the current environment is Darwin 27.2. The OS contribution is not
isolated.

Inspection also found three tracing-specific stores and a recording provider
acquired before filtering in the candidate harness. Selection-scoped acquisition
is a follow-up opportunity; no harness or numerical baseline was changed during
this release attempt. This comparison does not attribute the no-op slowdown to
those stores.
