---
id: 296
slug: add-checked-dsl-source-upgrades-and-mori-fleet-planning
title: "Add checked DSL source upgrades and Mori fleet planning"
kind: exec-plan
created_at: 2026-09-22T02:05:06Z
intention: "intention_01m33ee8ybesgbj7yy4rq4f1hw"
provenance:
  created_by:
    model: "gpt-6-astra"
    harness: "codex-cli"
    at: 2026-09-22T02:05:06Z
  revisions:
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-09-22T02:17:30Z
      mode: "update"
      note: "Link the intention created through mina ci at user request"
    - model: "claude-opus-5-5"
      harness: "claude-code"
      at: 2026-09-22T17:43:10Z
      mode: "update"
      note: "Rescope to Languages 5-6: replace upgrade engine, transactions, and fleet adapter with a tested check+diff recipe after verifying 5->6 is declaration-only on all v5 dependents"
---

# Add checked DSL source upgrades and Mori fleet planning

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.

The title and file name are kept as the plan's stable identifiers. The 2026-09-22 revision
narrowed its scope. It no longer builds an upgrade engine or a fleet command; it documents and
regression-tests the checked source-upgrade workflow the existing CLI already provides. See the
Decision Log and the revision note at the bottom.


## Purpose / Big Picture

[IR-5](../improvement-requests/add-version-aware-keiro-dsl-upgrade-and-fleet-rewrite-tooling.md)
asks for a safe way to move a `.keiro` source, or every member of a service workspace, to a
later DSL language version. A `.keiro` source starts with a preamble line such as
`language keiro-dsl 5`, which selects the parser and runtime-semantics contract. The request also
asks for a way to see which Keiro dependent repositories need that move. The risk it addresses is
real: in the past, editing only the preamble number could silently change behavior. For example,
from Language 1 to 2 an unannotated aggregate transition changed from an application-owned
Haskell hole to generated code.

Keiro is retiring Languages 1 through 4. Only Language 5 (stable) and Language 6 (candidate)
remain in scope, so the only upgrade path left is 5 → 6. Research for this revision (see
Surprises & Discoveries) shows that the existing toolchain already provides this migration end
to end:

1. edit the preamble,
2. run `keiro-dsl check`,
3. run `keiro-dsl diff --since <git-ref>`.

The `diff` command reports the language change as a located `ADDITIVE` source-language finding,
together with the runtime-semantics profile change. It reports any real semantic change
separately, and it prints a replay verdict. Git provides preview, rollback, and review.

After this plan, a user can follow a documented and tested recipe that upgrades a Language 5
file or workspace to Language 6 and proves the change is only a declaration change. They can
also inventory the Keiro dependents that still need upgrading with one documented Mori query.
No new command, module, report schema, transaction journal, or process adapter is added, so the
plan adds no ongoing maintenance.


## Progress

- [ ] Milestone 1: add the "Moving a source to the next language" section to
  `docs/user/typed-spec-toolchain.md`, including the fleet inventory recipe.
- [ ] Milestone 1: add `keiro-dsl/test/language-upgrade-recipe-test.sh` and confirm it exits 0.
- [ ] Milestone 1: record the changelog entry.
- [ ] Milestone 2: reconcile IR-5 status, acceptance notes, and bundle log with this plan.
- [ ] Outcomes & Retrospective written.


## Surprises & Discoveries

- 2026-09-22: The 5 → 6 edge is purely additive at the source level. Every Language 6 syntax
  feature in `keiro-dsl/src/Keiro/Dsl/LanguageVersion.hs` (`profileV5`) is gated by
  `requireLanguageFeatureAt` or `languageFeatureKeyword`
  (`keiro-dsl/src/Keiro/Dsl/Parser/Mapped.hs:346`). The keyword is recognized under every
  version and rejected when the feature is absent. So a Language 5 body cannot contain a
  construct that Language 6 reinterprets (such as a type named `Day`); it is already an error
  under Language 5. The one runtime capability that is read outside the parser,
  `StructuralNominalLeaves` in `keiro-dsl/src/Keiro/Dsl/Validate.hs:1394`, only lifts a
  restriction. Unlike the 1 → 2 transition-implementation default in
  `keiro-dsl/src/Keiro/Dsl/Parser/Aggregate.hs:351-352`, there is no default-changing gate.

- 2026-09-22: The manual recipe was run against every registered Language 5 dependent, using
  disposable copies of each repository's tracked `.keiro`/`.keiro-workspace` files.
  - Repositories: `mori://shinzui/kotei` (6 files), `mori://shinzui/meibo` (6),
    `mori://shinzui/danwa` (8), and `mori://shinzui/keiei` (9).
  - For each one, `keiro-dsl check <workspace>` exited 0 and `keiro-dsl diff --since HEAD
    <workspace>` exited 0.
  - The only findings were `ADDITIVE ... source-language ... declared v5 -> declared v6; effective
    runtime semantics changed keiro-dsl/runtime-semantics/4 -> keiro-dsl/runtime-semantics/5`,
    one per member with a located `declared: <file>:1`, followed by `replay-neutral: stored-data
    replay is unchanged by this diff`.
  - The in-repository fixtures `keiro-dsl/test/fixtures/mapped-readmodel-workspace/` and
    `keiro-dsl/test/fixtures/projection-catalog.keiro` gave the same result.
  - This used the 0.18.0.0 build from `cabal list-bin keiro-dsl`.

- 2026-09-22: Fleet inventory through Mori, from `mori registry dependents shinzui/keiro --json`
  deduplicated to 18 projects and checked with `git ls-files`:
  - Language 5: kotei, meibo, danwa, keiei.
  - Already Language 6: `mori://shinzui/mori` (15 files), `mori://shinzui/rei` (33), and
    `mori://shinzui/shikigami` (5).
  - Unversioned: `mori://shinzui/keiro-runtime-jitsurei` (8 example/fixture files), one spike in
    `mori://shinzui/kizashi`, and `kdsl/forge.keiro` in `mori://shinzui/kotei`.
  - `mori://shinzui/keiro-syntax` holds corpus files for every version.
  - Eight projects have no `.keiro` sources.

  The unversioned files are effectively Language 1. They belong to the Language 1–4 retirement
  inventory, not to this plan: no automated path from Language 1 remains in scope, and they must
  be migrated by hand or removed when retirement lands.

- 2026-09-22: Two defects were found in the original plan text. `cabal test keiro-dsl:tests` names
  a test suite that does not exist; `keiro-dsl/keiro-dsl.cabal` declares `keiro-dsl-test`. Also,
  `docs/user/typed-spec-toolchain.md` still calls Language 6 "unpublished", while 0.18.0.0 shipped
  it as a candidate. Milestone 1 touches that paragraph and should correct the wording.


## Decision Log

Decision (2026-09-21, superseded 2026-09-22): default to the published stable language and
require `--allow-candidate` with an explicit `--to 6`. Superseded because no `upgrade` command is
built. The recipe states that Language 6 is a candidate, and choosing it is the author's explicit
preamble edit.

Decision (2026-09-21, superseded 2026-09-22): preserve original text with located edits instead
of reprinting. This still holds in spirit: the recipe edits only the preamble line, so comments,
whitespace, and newline style are untouched by construction. No located-edit engine is needed.

Decision (2026-09-21, retained): stop on unknown or incompatible semantics instead of guessing.
The recipe's gate is `keiro-dsl diff --since` exiting 0 with only source-language findings. Any
other finding means the upgrade is not declaration-only and needs a reviewed source change.

Decision (2026-09-21, superseded 2026-09-22): recoverable multi-file transactions with a journal
and a `recover` command. Superseded because the recipe edits files that are tracked in Git, and
`git diff` / `git checkout -- <paths>` already provide preview and rollback. A journal would
duplicate version control and would need the most maintenance of anything in the original plan.

Decision (2026-09-21, superseded 2026-09-22): a Mori subprocess fleet command with a strict JSON
decoder. Superseded by a documented shell query. A fleet command would couple the `keiro-dsl`
release cycle to Mori's CLI JSON output, for an inventory of 18 projects that is run rarely.

Decision (2026-09-22): scope to Languages 5 and 6 only. The user stated that Languages 1–4 are
being dropped and their code removed. Building transforms for the 1→2, 2→3, 3→4, and 4→5 edges
would create code, fixtures, and goldens whose only purpose disappears with that retirement.
The retirement itself is a separate decision governed by
[ADR-47](../adr/0047-dsl-retirement-requires-complete-retained-history-evidence.md): removing old
syntax is separate from removing historical semantics. No plan for it exists yet.

Decision (2026-09-22): do not implement a `keiro-dsl upgrade` command now. For 5 → 6 it would
only wrap a one-line edit plus two existing commands, and those commands already prove the result
on every real consumer. **Revisit trigger:** a future language edge whose correct migration needs
more than a preamble edit, meaning the recipe's `diff` reports a non-source-language finding for
an unchanged body. The plan that introduces such a language owns its migration rule, because it
is the only place that knows what changed. That plan should decide at that point whether a
command is warranted. This matches how the 1 → 2 hazard would have been caught: `diff` reports
changed transition ownership as a semantic finding, not as provenance.

Decision (2026-09-22): put the recipe in the existing language reference
(`docs/user/typed-spec-toolchain.md`) rather than a new user document. This avoids another
bundle entry to keep current.


## Outcomes & Retrospective

(To be filled during and after implementation.)


## Context and Orientation

The `keiro-dsl` executable is defined in `keiro-dsl/app/Main.hs`. Two of its existing commands are
all this plan uses:

- `keiro-dsl check FILE` parses a `.keiro` file or a `.keiro-workspace` manifest, builds the
  checked service, and runs `checkIndexedServiceDiagnostics` from
  `keiro-dsl/src/Keiro/Dsl/ScaffoldRun.hs`. It prints `OK` and exits 0 when the specification is
  valid under the language each source declares. It may also print warnings.
- `keiro-dsl diff --since REF FILE` compares the working-tree source or workspace with the version
  at Git revision `REF`. It prints classified findings (`BREAKING`, `WARNING`, `ADDITIVE`), each
  with a source location, and ends with a replay verdict such as `replay-neutral: stored-data
  replay is unchanged by this diff`. It exits non-zero when a gated finding blocks.
  `keiro-dsl/test/diff-test.sh` is the existing integration test for this command and is the
  model for the new test script.

A language change is reported by `sourceLanguageChange` in `keiro-dsl/src/Keiro/Dsl/Diff.hs:969`
under the code `SourceLanguageDeclarationChanged`. [ADR-16](../adr/0016-source-language-provenance-wraps-the-semantic-keiro-dsl-graph.md)
explains why this is a *provenance* finding: the semantic graph excludes source-language
provenance, so a declaration-only upgrade produces exactly one source-language finding per member
and no semantic findings. [ADR-18](../adr/0018-runtime-semantics-use-capability-profiles-and-frozen-fold-identity.md)
defines the runtime-semantics profiles whose identifiers appear in that finding.
[ADR-14](../adr/0014-service-workspaces-compose-single-owner-members-under-one-manifest-identity.md)
requires every member of a workspace to be composed and checked together. Because of this, the
recipe changes all members before running `check`, and it runs `check` on the manifest, not on
individual members.

The language registry is `languageRegistry` in `keiro-dsl/src/Keiro/Dsl/LanguageVersion.hs:266`.
It lists Languages 1–6, marks Language 5 `Stable` and Language 6 `Candidate`, and records each
language's syntax profile and runtime-semantics profile. Language 6 differs from 5 by the syntax
features in `profileV5` and the runtime capabilities in `runtimeProfileV5`. All of them are
additive (see Surprises & Discoveries).

Keiro's dependents are listed by the external registry `mori://shinzui/mori`:
- `mori registry dependents shinzui/keiro --json` returns one row per dependency edge, with
  `namespace` and `name` fields, so a project can appear more than once.
- `mori registry show <namespace>/<name> --json` returns the project's checkout `path`.

Other relevant files:
- `docs/user/typed-spec-toolchain.md` is the Language 5 reference. Its "Preamble and context"
  section (around line 153) is where the recipe belongs.
- `keiro-dsl/CHANGELOG.md` records user-visible changes.
- `docs/improvement-requests/log.md` is the improvement-request bundle log.

No other ADR bears on this change. There is no ADR yet for retiring Languages 1–4.


## Plan of Work

### Milestone 1 — Documented, regression-tested upgrade recipe

In `docs/user/typed-spec-toolchain.md`, add a subsection "Moving a source to the next language"
directly after "Preamble and context". It must say the following:

- Language 6 is a candidate. Adopting it is an explicit choice by the author, and services that
  only use released features may stay on Language 5.
- The upgrade has four steps, all run from a clean Git working tree for the affected files:
  1. Change `language keiro-dsl 5` to `language keiro-dsl 6` in every member of the workspace
     (or in the single file). Edit no other text.
  2. Run `keiro-dsl check` on the manifest or file.
  3. Run `keiro-dsl diff --since HEAD` on the manifest or file.
  4. Accept the upgrade only if `diff` exits 0 and every finding is a `source-language` finding.
- Any other finding means the change is not declaration-only. Revert the edit with
  `git checkout -- <files>`, then treat the finding as a normal reviewed source change.
- Show a short example of the expected output, copied from the test run.
- Include the fleet inventory query from Concrete Steps, and note that absolute checkout paths are
  local facts, while projects are identified as `mori://<namespace>/<name>`.

In the same edit, correct the opening paragraph's "active, unpublished Language 6 candidate"
wording to match the released candidate status. Do not otherwise restructure the reference.

Add `keiro-dsl/test/language-upgrade-recipe-test.sh`, modeled on `keiro-dsl/test/diff-test.sh`.
It must do the following:
1. Create a temporary Git repository containing copies of
   `keiro-dsl/test/fixtures/mapped-readmodel-workspace/` and
   `keiro-dsl/test/fixtures/projection-catalog.keiro`, and commit them.
2. Replace only the preamble line of each copied member.
3. For the workspace manifest and for the single file, assert that `check` exits 0, that `diff
   --since HEAD` exits 0, and that every finding line contains `source-language`.
4. Assert that `git diff --numstat` shows exactly one added and one removed line per member.
5. As a negative control, add a field to an event in the committed single-file copy while
   bumping it. This is a known `BREAKING` change, the same one `diff-test.sh` uses. Assert that
   `diff` now exits non-zero, which proves the gate actually rejects.

The script prints `ok: language upgrade recipe verified` on success. The fixtures stay in place,
unchanged; the script only copies them.

Add one entry to `keiro-dsl/CHANGELOG.md` under the unreleased section. It documents the
recipe and states that there is intentionally no `upgrade` command.

Acceptance: `bash keiro-dsl/test/language-upgrade-recipe-test.sh` exits 0 and prints the success
line. The new documentation section renders and links correctly.

### Milestone 2 — Reconcile IR-5

Update `docs/improvement-requests/add-version-aware-keiro-dsl-upgrade-and-fleet-rewrite-tooling.md`.
Follow the bundle's existing metadata and log conventions (see the IR-41 and IR-47 entries in
`docs/improvement-requests/log.md`):

- Set `status` to `completed` and add `plan: docs/plans/296-add-checked-dsl-source-upgrades-and-mori-fleet-planning.md`.
- In the Status section, state that Languages 1–4 are being retired and that the only remaining
  edge (5 → 6) is served by the documented, tested check-and-diff recipe.
- State that the command, transaction engine, and fleet mode were declined, with the revisit
  trigger from the Decision Log.
- For each acceptance item, say how it is met or why it is obsolete:
  - Item 1 is obsolete, because the Language 1 fixture chain is being retired.
  - Items 2 and 4 are met by `diff` findings plus the negative control.
  - Item 3 is met because `check` composes the whole workspace before any commit and Git
    provides rollback.
  - Item 5 is met by the documented Mori query using canonical identities.

Add a dated **Status** entry to `docs/improvement-requests/log.md`.

Acceptance: the IR's frontmatter and body agree with this plan, and the log entry exists.


## Concrete Steps

Run from the repository root with the configured Haskell development environment.

```bash
cabal build keiro-dsl:exe:keiro-dsl
bash keiro-dsl/test/language-upgrade-recipe-test.sh
bash keiro-dsl/test/diff-test.sh
git diff --check
```

Expected: both scripts exit 0. The new script ends with `ok: language upgrade recipe verified`.

The recipe the guide documents, for a workspace (use a `.keiro` path for a single file):

```bash
sed -i.bak 's/^language keiro-dsl 5$/language keiro-dsl 6/' path/to/members/*.keiro && rm path/to/members/*.keiro.bak
keiro-dsl check path/to/service.keiro-workspace
keiro-dsl diff --since HEAD path/to/service.keiro-workspace
```

Expected `diff` output shape, one pair of lines per member, then the verdict:

```text
ADDITIVE: <service> source-language <member>.keiro: source form changed declared v5 -> declared v6; effective runtime semantics changed keiro-dsl/runtime-semantics/4 -> keiro-dsl/runtime-semantics/5; see the accompanying semantic-contract findings
    declared: <member>.keiro:1
replay-neutral: stored-data replay is unchanged by this diff
```

The fleet inventory query the guide documents (read-only; requires `mori` and `jq`):

```bash
mori registry dependents shinzui/keiro --json | jq -r '.[] | "\(.namespace)/\(.name)"' | sort -u |
while read -r project; do
  root=$(mori registry show "$project" --json | jq -r '.path // empty')
  [ -n "$root" ] || { echo "mori://$project: no checkout"; continue; }
  git -C "$root" ls-files '*.keiro' | while read -r f; do
    echo "mori://$project $f: $(grep -m1 -E '^language keiro-dsl [0-9]+' "$root/$f" || echo unversioned)"
  done
done
```

Name the loop variable `root`, not `path`. In zsh, `path` is tied to `PATH`, and assigning it
breaks every later command in the loop. This happened during research for this revision.


## Validation and Acceptance

- The recipe test exits 0 on a Language 5 workspace and a Language 5 single file. It proves:
  - `check` passes under Language 6;
  - `diff` exits 0 with only source-language findings and a `replay-neutral` verdict;
  - the textual change is exactly one line per member;
  - the negative control makes `diff` exit non-zero.
- `bash keiro-dsl/test/diff-test.sh` still passes, and no fixture under `keiro-dsl/test/fixtures/`
  is modified (`git status` shows only the new script and the documentation, changelog, and IR
  edits).
- IR-5's status, plan link, and log entry agree with this plan.

The maintenance acceptance: the change adds no Haskell module, no CLI flag, and no report schema.
The only artifact tied to specific language numbers is the test script. When Language 6 becomes
stable and Language 5 is retired, the retirement plan updates the script's fixtures and preamble
numbers or deletes the script.


## Idempotence and Recovery

The documentation and IR edits are ordinary text changes. The test script works in a `mktemp -d`
directory that it removes on exit, so rerunning it is safe. The recipe is idempotent: running
`sed` again on a Language 6 file changes nothing, and `diff --since HEAD` then reports no
source-language finding. The recipe's recovery path is `git checkout -- <files>`, which is why it
requires tracked files with no uncommitted edits before the bump.


## Interfaces and Dependencies

No new Haskell interfaces, modules, CLI commands, or package dependencies are added. The plan
depends only on the existing `keiro-dsl check` and `keiro-dsl diff --since` behavior, and on
`SourceLanguageDeclarationChanged` staying a source-provenance finding (ADR-16). The documented
fleet query depends on the `mori` CLI's `registry dependents` and `registry show --json` output
(`mori://shinzui/mori`, documented at `mori://shinzui/mori/docs/user-guide`). That is a
documentation dependency, not a build or test dependency.

Creation note (2026-09-21): feasibility evaluated against current source, registry, workspace/diff APIs, relevant ADRs, and Mori's live inventory/JSON implementation. No implementation or Haskell test execution is claimed by this planning document.

Revision note (2026-09-21): linked the intention created with `mina ci --json` at the user's request; implementation scope is unchanged.

Revision note (2026-09-22): rescoped after verification. The user stated that Languages 1–4 are
being dropped, leaving 5 → 6 as the only edge. Checking the parser gates showed that edge is
additive. Running the manual check-and-diff recipe against all four registered Language 5
dependents and two in-repository fixtures showed declaration-only, replay-neutral results. The
original six-milestone engine (step registry, located-edit rewriter, per-edge goldens,
transaction journal with recovery, Mori fleet subprocess adapter, two report schemas) would have
added lasting maintenance for no capability beyond the existing commands. It was replaced by a
documented recipe, one regression script with a negative control, and IR-5 reconciliation. The
original text remains in Git history at commit `2241a0be`.
