# Bundle Update Log

## 2026-08-14
* **Addition**: REV-12 approves the commit-pinned Language 5 stability gate: Language 5 is sole stable authoring, Language 4 remains published compatibility, and all exclusive and inherited conformance surfaces pass.
* **Addition**: REV-11 approves the commit-pinned Keiro umbrella version API after the public value and package-selecting probe began deriving from Cabal-generated metadata.
* **Addition**: REV-10 approves the commit-pinned durable-workflow user contract after both current guides aligned with live constraints, opaque id hand-off, and at-least-once step semantics.
* **Addition**: REV-9 approves the commit-pinned Jitsurei durable workflow after it began publishing the allocated id, asserting signal and completion, and proving journal survival across restart.
* **Addition**: REV-8 approves the commit-pinned DSL workflow awakeable integration after generated code began returning the live allocation id and the PostgreSQL lane proved signal-to-resume behavior.
* **Addition**: REV-7 approves the commit-pinned awakeable allocation API after opaque returned ids replaced coordinate-derived authoring and legacy probes moved behind the explicit compatibility surface.
* **Addition**: REV-1 records the release-blocking ambiguity between the current opaque awakeable allocation contract and the legacy coordinate-derived helper.
* **Addition**: REV-2 records the DSL workflow generator and conformance test certifying a signal id that fresh runtime allocations reject.
* **Addition**: REV-3 records the Jitsurei workflow remaining suspended while its driver reports successful completion and durability.
* **Addition**: REV-4 records unsafe at-most-once and deterministic-id promises in the public durable-workflow contract.
* **Addition**: REV-5 records the stale public `Keiro.version` value and the test that freezes it.
* **Addition**: REV-6 records the final Language 5 stability verdict: no new blocker in its exclusive surfaces, but registry promotion remains blocked by the unresolved workflow awakeable generator defect in REV-2.
