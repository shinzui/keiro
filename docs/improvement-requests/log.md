# Bundle Update Log

## 2026-07-31
* **Review**: IR-4 passes an in-repository technical-accuracy review against the current Keiro
  implementation and the released Keiki `Natural` capability. The review corrected the
  description of Haskell `Natural` subtraction from saturation to `Underflow` and records that
  the required capability is published in Keiki `0.5.0.0` on Hackage with a matching upstream tag.
* **Addition**: IR-4 requests truthful direct aggregate lowering for `Time` and `Natural`, plus a
  shared validation/scaffolding capability model so a clean check cannot fail later on type
  lowering.

## 2026-07-30
* **Addition**: IR-3 requests an explicit terminal outbox rejection outcome so downstream
  applications can finalize intentional refusals without retrying or reporting success.

## 2026-07-29
* **Addition**: IR-2 requests first-class multi-file service composition for per-aggregate Keiro specs, including shared declaration resolution, whole-service validation/diffing, and atomic context-level scaffolding.

## 2026-07-28
* **Review**: IR-1 records an OpenAI Codex review with gpt-5.6-sol at xhigh effort after
  in-repository verification against Keiki constraints and Keiro architecture principles.
* **Addition**: IR-1 requests structural consumer-owned record and union support in keiro-dsl for Mori EP-171.
