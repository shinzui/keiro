---
type: Improvement Request
title: Publish keiro terminology as a shared catalog
description: >-
  Adopt the shared documentation.terminology profile and publish keiro's controlled vocabulary
  as a docs/terminology catalog of TERM-N terms with preferred and discouraged wording,
  relations, succession, and code anchors, so agents and authors can query and cite it.
timestamp: 2026-09-18T22:19:42Z
requestId: IR-41
status: proposed
origin: mori://shinzui/mori/plans/268-specify-the-shared-terminology-contract-and-request-it-upstream
reviews:
  - kind: model
    reviewer: claude-code-author
    reviewed_at: 2026-09-18T22:19:42Z
    document_timestamp: 2026-09-18T22:19:42Z
    scope: technical-accuracy
    outcome: commented
    provider: anthropic
    model: claude-opus-5
    effort: unspecified
    context: >-
      Author self-review, not an independent review. Every seed module named below was checked
      to exist in the keiro checkout at 26360258, the user-documentation bundle binding and
      Justfile verify recipe were read as the adoption template, and the request validates with
      mori/improvement-requests-profile.dhall.
---

# Improvement Request: Publish Keiro Terminology as a Shared Catalog

## Status

**Proposed.** Requested by
`mori://shinzui/mori/plans/268-specify-the-shared-terminology-contract-and-request-it-upstream`
as the first adopter of
`mori://shinzui/mori/masterplans/36-publish-project-terminology-as-a-first-class-okf-catalog`.

## Dependency

This request **hard-depends** on
`mori://shinzui/okf-profiles/okf/improvement-requests/concepts/IR-6`, which asks okf-profiles to
publish the `documentation.terminology` profile and the `adopt-terminology` blueprint. Do not
start before that profile is released in a tagged okf-profiles version (v0.17.0 or later). This
bundle's pinned improvement-request profile (v0.5.0) predates typed `dependencies`, so the
dependency is stated here in prose.

## Problem

Keiro's vocabulary is precise but lives only as prose: `docs/user/core-concepts.md` (DOC-5),
`docs/why-keiro.md`, the process-manager, durable-workflow, read-model, outbox, and typed-spec
guides, and ADRs. Nothing can be queried, a term cannot be cited by a stable URI, and nothing
tells an author or agent which wording to avoid. ADR-22 renamed generated "sidecars" to "slot
ledgers", yet `docs/user/typed-spec-toolchain.md` and
`docs/guides/adopting-keiro-dsl-idiomatic-v2.md` still say "sidecar". `docs/why-keiro.md` calls
`Keiki.Decider` legacy, but "decider" remains the natural word readers reach for.

Every project that depends on keiro inherits this vocabulary. Once published, Mori puts a
dependency's terms, including its discouraged wording, into `mori agent context` for dependent
projects, and answers `mori terms search sidecar` with the term to use instead.

## Requested Change

1. Run the `adopt-terminology` blueprint from the released okf-profiles version.
2. Create `docs/terminology/` as an OKF v0.2 bundle with `index.md` and `log.md`, one Markdown
   file per term at the bundle root, each with `type: Term` and a `termId` allocated by
   `okf id next docs/terminology --profile mori/terminology-profile.dhall TERM`.
3. Add `mori/terminology-profile.dhall` selecting `Profiles.documentation.terminology` from the
   pinned release.
4. Add an `OkfBundle` named `terminology` at `docs/terminology` to `mori.dhall`, with a
   `Schema.ProfileBinding.Published` binding shaped like the `user-documentation` entry
   (publisher `shinzui/okf-profiles`, export `documentation.terminology`, version, and pin).
5. Add a `terminology-validate` Justfile recipe and wire it into `verify`:

   ```bash
   okf validate docs/terminology --strict --profile mori/terminology-profile.dhall --profile-enforce --log-enforce
   mori terms validate --path .
   ```

## Seed Inventory

This is a starting inventory of terms keiro already defines, with the file that defines each
today and the module that embodies it. It is not wording to copy: keiro owns every definition,
and may merge, split, or drop entries.

- stream — `docs/user/core-concepts.md`; `Keiro.Stream` (`keiro-core`).
- codec — `docs/user/core-concepts.md`; `Keiro.Codec` (`keiro-core`).
- command cycle — `docs/user/core-concepts.md`; `Keiro.Command`.
- snapshot — `docs/user/core-concepts.md`; `Keiro.Snapshot`.
- read model — `docs/user/read-models-and-projections.md` (DOC-19); `Keiro.ReadModel`.
- projection, with the narrower terms inline projection and asynchronous projection —
  `docs/user/read-models-and-projections.md`; `Keiro.Projection`.
- process manager — `docs/user/process-managers-and-timers.md` (DOC-17); `Keiro.ProcessManager`.
- timer — `docs/user/process-managers-and-timers.md`; `Keiro.Timer`.
- durable workflow — `docs/user/durable-workflows.md` (DOC-8); `Keiro.Workflow`.
- journal — `docs/user/durable-workflows.md`; `Keiro.Workflow.Journal`.
- awakeable — `docs/user/durable-workflows.md`; `Keiro.Workflow.Awakeable`.
- transactional outbox — `docs/user/outbox.md` (DOC-16); `Keiro.Outbox`.
- inbox — `docs/user/outbox.md`; `Keiro.Inbox`.
- integration event — `Keiro.Integration.Event` (`keiro-core`).
- dead letter — `Keiro.DeadLetter`.
- slot ledger — ADR-22 and `docs/user/typed-spec-toolchain.md` (DOC-23);
  `Keiro.Dsl.SidecarNames`. It `replaces` a deprecated "sidecar" term whose `replacedBy` is
  slot ledger, and "sidecar" becomes discouraged wording.
- decider — `docs/why-keiro.md`. Keiro decides whether it is a deprecated term (replaced by
  the symbolic-transducer vocabulary) or discouraged wording on another term, and what it
  points to.

Terms that belong to Keiki or Kiroku (symbolic transducer, event store, Strategy E) are not
keiro's to define. Reference them with `sameAs` or `related` canonical URIs once those
projects publish catalogs, rather than redefining them here.

## Acceptance Criteria

- `okf validate docs/terminology --strict --profile mori/terminology-profile.dhall
  --profile-enforce --log-enforce` exits 0.
- `mori terms validate --path .` reports no findings.
- `just verify` runs `terminology-validate`.
- After registration, `mori path mori://shinzui/keiro/okf/terminology/concepts/TERM-1` resolves.
- After registration, `mori terms search sidecar` returns slot ledger as the term to use.
