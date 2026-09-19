---
type: Improvement Request
title: Publish keiro terminology as a shared catalog
description: >-
  Adopt the shared documentation.terminology profile and publish keiro's controlled vocabulary
  as a docs/terminology catalog of TERM-N terms with preferred and discouraged wording,
  relations, succession, and code anchors, so agents and authors can query and cite it.
timestamp: 2026-09-18T22:19:42Z
requestId: IR-41
status: completed
completedAt: 2026-09-19T03:09:21Z
resolution: >-
  Adopted by hand (okf-profiles deferred the adopt-terminology blueprint until this first
  adoption): docs/terminology holds 27 TERM-N terms under okf-profiles v0.17.0's
  documentation.terminology profile, bound in mori.dhall and gated by just terminology-validate.
  The sidecar/slot-ledger premise was wrong and was not encoded: ADR-22 keeps "sidecar" as the
  current umbrella word and retired "scaffold record" and "conformance record" instead.
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

**Completed** on 2026-09-19, without an ExecPlan. The catalog lives at
[`docs/terminology/`](../terminology/index.md), is pinned to okf-profiles v0.17.0, and is checked
by `just terminology-validate` as part of `just verify`. Requested by
`mori://shinzui/mori/plans/268-specify-the-shared-terminology-contract-and-request-it-upstream`
as the first adopter of
`mori://shinzui/mori/masterplans/36-publish-project-terminology-as-a-first-class-okf-catalog`.

### Resolution Notes

- **No blueprint existed.** okf-profiles v0.17.0 shipped the profile but deferred the
  `adopt-terminology` blueprint until a first real adoption
  (`mori://shinzui/okf-profiles/okf/improvement-requests/concepts/IR-6`). Keiro is that adoption,
  so steps 2 to 5 were done by hand, following the user-documentation binding.
- **The sidecar premise was wrong.** ADR-22 did not rename "sidecars" to "slot ledgers", and no
  keiro artifact uses "slot ledger". ADR-22 keeps *sidecar* as the current umbrella word, and
  `Keiro.Dsl.SidecarNames` is named for it. It renamed the individual sidecars: the scaffold
  record became the scaffold ledger (TERM-22), the conformance record became the conformance
  ledger (TERM-24), and the generated manifest became the Cabal fragment (TERM-26). So *sidecar*
  (TERM-21) is `current`, *scaffold record* (TERM-23) and *conformance record* (TERM-25) are
  `deprecated` and name their ledgers in `replacedBy`, and *scaffold manifest* is discouraged
  wording on the Cabal fragment. `mori terms search sidecar` therefore returns TERM-21 and no
  replacement, which departs from the last acceptance criterion on purpose.
- **Decider is discouraged wording, not a deprecated term.** Keiro never had a decider concept.
  The keiro/keiki contract was chosen over a Decider facade. *decider* and *decider facade* are
  discouraged wording on *event stream* (TERM-2), the aggregate contract whose decision logic is
  a Keiki `SymTransducer`.
- **Keiki and Kiroku terms are referenced in prose only.** Neither project publishes a catalog
  yet, and a `mori://` relation to an unregistered term fails `mori terms validate`.
- **Live docs aligned.** The pages that still said "scaffold record" or "scaffold manifest"
  (`docs/guides/brownfield-migration-and-transducer-modeling.md`,
  `docs/guides/choosing-keiro-dsl.md`, `docs/user/api-reference.md`) now use the ledger and
  Cabal-fragment names. ADRs, plans, and the legacy-migration passage in
  `docs/user/typed-spec-toolchain.md` keep the old words as history.

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
