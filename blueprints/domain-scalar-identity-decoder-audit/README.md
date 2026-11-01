# domain-scalar-identity-decoder-audit

**Version:** `0.1.0`. **Kind:** runnable Seihou blueprint.

Apply the domain audit completed in
[Shikigami plan 108](mori://shinzui/shikigami/plans/108-complete-the-remaining-domain-scalar-identity-and-decoder-audit)
to an existing Haskell project. The agent inventories and classifies declarations
and members, fixes concrete scalar/identity/decoder findings, and records final
compiler, behavioral, compatibility, and source-freshness evidence.

The blueprint adapts to the target's packages, authorities, persistence owners,
test fixtures, and platform. It requires no particular Keiro version and can be
used by projects without Keiro. It has no migration edges, version probe,
baseline modules, or required variables. Its version describes the audit prompt,
not a library release. It makes source changes in the target project.

After this change is published, install and run from the target project:

```sh
seihou install https://github.com/shinzui/keiro.git --module domain-scalar-identity-decoder-audit
seihou agent --debug run domain-scalar-identity-decoder-audit
seihou agent run domain-scalar-identity-decoder-audit
```

For the unpublished local checkout, use its absolute blueprint directory in place
of the name:

```sh
seihou agent --debug run /absolute/path/to/keiro/blueprints/domain-scalar-identity-decoder-audit
seihou agent run /absolute/path/to/keiro/blueprints/domain-scalar-identity-decoder-audit
```

The currently tested Seihou CLI writes a blueprint receipt even during `--debug`
preview. Inspect `.seihou/manifest.json` afterwards and discard that preview-only
change if appropriate; it does not mean the audit ran.

An optional initial prompt can identify an existing audit or narrow the requested
scope. A scoped run must report its scope and cannot claim repository-wide
completion. Reruns reconcile existing evidence against current source and resume
unfinished work. Seihou's run receipt is not evidence that the audit passed.

The three acceptance stages remain separate: complete classification may contain
known findings; remediation requires none unresolved; final acceptance additionally
requires fresh evidence and executed tests. Primitive fields are not automatically
violations, and persistence does not automatically make a value a boundary DTO.
Existing native identities, valid wire bytes, and deterministic recipes retain
their authority. The agent must not invent grammars, allocate replacement IDs,
waive concrete findings, or silently skip database tests to finish.

Maintainer validation, from this repository:

```sh
nix develop -c seihou validate-blueprint blueprints/domain-scalar-identity-decoder-audit --lint
nix develop -c seihou registry validate
```
