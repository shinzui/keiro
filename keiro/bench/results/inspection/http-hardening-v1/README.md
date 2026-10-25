# HTTP hardening acceptance

[Plan 318](../../../../../docs/plans/318-harden-the-http-operational-surface-against-cross-site-mutations-and-permit-exhaustion.md)
is accepted by the 49-example Nix HTTP suite in [acceptance.txt](acceptance.txt).
Run `nix develop -c cabal test keiro-ops-http-test --test-show-details=direct`.

The tests cover parsed Origin normalization/refusal before body and schema effects,
JSON confirmation including chunked bodies, allowed/no-Origin/empty previews,
four blocked response callbacks that each expire once and return admission,
caller cancellation, real-socket 403/415, and real Warp delivery backpressure.
The latter holds a 32-MiB response behind a 4-KiB client receive buffer, establishes
that delivery has not completed, observes shared-admission refusal, then verifies
callback termination, health recovery and a closed/truncated connection. The test
deadline is one second; the default delivery deadline is 30 seconds.

Feed tests cover two-view schema drift/refusal/recovery, current timer presentation
at stable sequence zero without a clock-only delta, retiring-slot refusal during
blocked cleanup, and reacquisition after cleanup joins. The timer test waits on
actual refreshed state with a seven-second bound to honor the five-second minimum
cadence. Composition retains full child origin policy and one CORS response header.

Strict ADR (58 records), user (34 documents) and guide (32 documents) validation
also passes. These tests establish transport behavior; they do not replace the
initiative's independent writer-interference, retention or release gates.
