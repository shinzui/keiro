# Rejected cohort: concurrent external work

This cohort is **not performance acceptance evidence**. The parent controller
was interrupted after the capacity stage exposed large time-dependent drift.
The quiet-machine assumption was false: the retained process snapshot records
active external GHC/Cabal builds, a test executable and Chromium browser tests.
No external job was stopped. The current child leg was interrupted with the owned controller; nine complete
capacity-leg artifacts are retained and the tenth started leg is incomplete.
The manifest records the started command; its missing result marks the incomplete leg. No paced count-polling block was accepted.

`external-workload.txt` records process ids, CPU and executable basenames without
unrelated command arguments or source paths. `controller.log` records completed
leg summaries and interruption. `manifest.json` retains the complete commands,
frozen binary hashes, harness/controller hashes, fixture, hardware and a rejected
marker. The original controller source is in commit `36768697`; later controller
changes add quiet-machine preflight and boundary refusals, so a new run must use
a fresh output directory. Raw samples remain available for diagnosis, not for a
no-regression claim or a replacement baseline.

Observed unmounted capacities ranged from about 213 to 331 operations/second;
writer p95 also moved substantially on both binaries. Writer allocation remained
close, and each operation made the same eight workflow-header updates. These
measurements cannot attribute a timing change to the count implementation.
The original exact-count query measurements and functional/transport/Jitsurei
checks are separate from this rejected runtime cohort.
