# Bundle Update Log

## 2026-07-31
* **Review and planning**: IR-3 was revalidated against the current outbox implementation and is
  linked to plan 165 for its public outcome, durable rejected status,
  ordering, crash/recovery, telemetry, migration, and compatibility implementation.
* **Addition**: IR-10 requests an optional atomic async-projection mode whose user SQL, fencing,
  and Kiroku checkpoint advancement commit together through released store/adapter APIs.
* **Addition**: IR-9 requests a bounded declarative dynamic-router selection language while
  retaining effectful resolver holes as an explicit unchecked escape hatch.
* **Addition**: IR-8 requests first-class atomic multi-stream command coordination above Kiroku's
  lower-level transaction substrate.
* **Addition**: IR-7 requests typed application rejection and no-op outcomes instead of reducing
  every business refusal to generic `CommandRejected`.
* **Addition**: IR-6 requests independent DSL, generated Haskell-selector, and JSON wire-key names
  for direct aggregate fields.
* **Addition**: IR-5 requests sequential version-aware `keiro-dsl upgrade` transforms and later
  Mori-aware fleet rewrite planning after the declared-language-version foundation lands.
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
