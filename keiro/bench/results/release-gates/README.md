# Release-gate evidence

`20261025T053433Z-847b395c.log` ran `nix develop -c just release-gate` from clean
`847b395c`. The full correctness gate passed, including DSL symbolic/conformance and mutation
proofs. All six benchmark guards ran. The recipe returned 1 with `VERIFY_EXIT=0` and
`BENCH_EXIT=1`: producer-identity/projection failed; outbox/inbox/command/read-model passed.
The existing CSVs and producer ceilings were unchanged. This records refusal and continuation.

The producer rows have wide spreads, and external test/solver activity was observed during
them. These timings are exploratory, not quiet-machine baseline acceptance. Projection's
sequential diagnostic failed despite passing alternating latency requirements; plan 321 owns
its fixture follow-up. A passing final source revision and quiet acceptance remain pending.
