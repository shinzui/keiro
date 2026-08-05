# keiro-dsl conformance corpus

The directories named `conformance-*` are committed examples of public
`keiro-dsl scaffold` output. Together with their hand-owned fills and Cabal test
components, they prove that generated modules compile and that their runtime facts
hold.

## Regenerating the corpus

Run the driver from the repository development environment:

```console
nix develop -c cabal run -v0 keiro-dsl-corpus-regen -- regenerate
```

For a focused iteration, repeat `--only` with a repository-relative output
directory:

```console
nix develop -c cabal run -v0 keiro-dsl-corpus-regen -- regenerate \
  --only keiro-dsl/test/conformance-behavior-complete
```

The driver invokes the public CLI. It never passes the force-overwrite flag,
never overwrites create-once modules, and never commits. Review `git status` and
`git diff` after every run.

Ordinary single-spec and workspace invocations are derived from the committed
scaffold records. `conformance-corpus-manifest.txt` stores only provenance the
records cannot retain: workspace manifest locations, ordered stdin skeleton runs,
extra arguments, reviewed Cabal-inventory exemptions, and one legacy generated
file that predates the current record grammar. The driver rejects missing record
files, unrecorded generated files, dangling Cabal modules, and stale exemptions.

To verify the committed baseline without accepting drift, run:

```console
scripts/check-conformance-corpus.sh
```

The check refuses immediately when any corpus path is already dirty. From a
clean baseline it replays every invocation, verifies record/disk and Cabal/disk
consistency, and fails if regeneration changes a byte. The equivalent repository
recipe is `nix develop -c just conformance-corpus-policy`; it is also part of
`just verify`.

## Updating render goldens

Six renderer goldens are owned by `keiro-dsl-test`. Update them through the tests
that calculate the asserted values:

```console
nix develop -c cabal run -v0 keiro-dsl-corpus-regen -- update-goldens
```

Optional Cabal test arguments are passed through, for example
`--test-options=--match=fold`. Structural substring assertions continue to run in
accept mode, so an invalid renderer result is not accepted blindly. Review and
commit the resulting golden diff.

## Adding a conformance suite

1. Scaffold the fixture once with the public `keiro-dsl` CLI and fill its
   create-once modules.
2. Force-add the suite's scaffold record and build manifest. The global ignore
   rule remains correct for non-corpus consumer output.
3. Add a supplement row only when the history needs a workspace path, an ordered
   skeleton replay, extra scaffold arguments, or a reviewed generated-module
   exemption.
4. Add or extend the appropriate component in `keiro-dsl.cabal` and run its test.
5. Run focused regeneration and inspect the diff, then run the whole-corpus check
   from the committed baseline.

Do not hand-edit a generated module to make regeneration pass. Fix the generator,
fixture, record provenance, or Cabal inventory at its source.
