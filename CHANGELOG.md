# Changelog

All notable changes to the `keiro` library are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/), and the project aims to follow
the [Haskell Package Versioning Policy](https://pvp.haskell.org/).

## 0.1.0.0 — 2026-05-22

### New Features

- `Keiro.Router`: a new stateless, effectful fan-out primitive — the Enterprise
  Integration Patterns *content-based Router* / dynamic *Recipient List* paired
  with the existing `Keiro.ProcessManager`. Where a process manager computes its
  targets purely (`handle`), a router resolves them *effectfully*, so the target
  set can be looked up from a read model (`Keiro.ReadModel.runQuery`) rather than
  derived from the event alone. Exposed (and re-exported from `Keiro`):
    - `Router (..)` — a record carrying `resolve :: input -> Eff es [PMCommand targetCi]`,
      a `key` correlation function, and the `targetEventStream`. It has no state
      stream, no `correlate`, and no self-command.
    - `RouterResult (..)` — the per-target `PMCommandResult` list from one run.
    - `runRouterOnce` — resolve the targets for a source event, then dispatch one
      command per target with the same crash-safe, exactly-once-per-target
      idempotency the process manager provides (deterministic command ids via
      `deterministicCommandId` plus a duplicate pre-check), so replay writes
      nothing new.
    - `runRouterWorker` — drive a `Router` as a live subscription over a Shibuya
      `Adapter`, with a documented ack policy (decode failure or any
      `PMCommandFailed` → `AckHalt`; otherwise `AckOk`). Unlike
      `runProcessManagerWorker`, it invokes the ingested message's
      `AckHandle.finalize` with the decision, so the ack policy reaches the
      adapter.
- `Keiro.ProcessManager`: now exports `eventAlreadyIn`, the idempotency
  pre-check, so routers (and other callers) can reuse it. Its behavior is
  unchanged.
