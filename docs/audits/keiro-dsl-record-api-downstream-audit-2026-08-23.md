# keiro-dsl record API downstream audit — 2026-08-23

This read-only audit supports the next PVP-breaking `keiro-dsl` release. Mori reports
no registered package-specific dependent of
`mori://shinzui/keiro/packages/keiro-dsl`, but it reports coarse project-level
dependents of `mori://shinzui/keiro`. Each registered project path was therefore
inspected for Cabal dependencies, `Keiro.Dsl` imports, `.keiro` sources, scaffold
ledgers/fragments, generated banners, and hand-owned imports of generated modules.

Counts below are lexical risk indicators, not promises that every import uses a
changed field. “Generated” counts tracked Haskell files with a keiro-dsl generated
banner. “Hand imports” counts non-Generated Haskell files importing a generated
module.

| Registered project | Actual use | Evidence and required action |
| --- | --- | --- |
| `mori://shinzui/danwa` | Generated API | 15 generated files and 11 hand-owned generated imports; one `.keiro` source and no current edition ledger. Treat the tree as historical/legacy and recover or establish attributable ledger history; when that ledger records `legacy-v1`, adopt names and `idiomatic-v2` in one run with both flags. |
| `mori://shinzui/keiro-runtime-jitsurei` | Generated API | 97 generated files, 43 hand-owned generated imports, two service specs, and historical `keiro-dsl-scaffold-record`/manifest sidecars without an edition row. Use the one-run legacy path with both `--apply-name-migrations` and `--apply-generated-haskell-edition`. |
| `mori://shinzui/kotei` | Generated API | 20 generated files, 22 hand-owned generated imports, and five `.keiro` sources without current edition ledgers. Re-establish attributable history, then use the one-run both-flags path for any recovered `legacy-v1` ledger. |
| `mori://shinzui/shikigami` | Generated API | 17 generated files, nine hand-owned generated imports, a workspace, and an `idiomatic-v1` workspace ledger. Use the explicit backup-backed `idiomatic-v2` path. |
| `mori://shinzui/mori` | Generated API | 161 generated files, 140 hand-owned generated imports, a language-5 workspace, and an `idiomatic-v1` workspace ledger. Use the explicit backup-backed `idiomatic-v2` path. Its registered Keiro package dependencies do not include `keiro-dsl` as a library dependency. |
| `mori://shinzui/rei` | Package and generated APIs | 235 generated files, 201 hand-owned generated imports, an `idiomatic-v1` workspace ledger, a direct `keiro-dsl` Cabal bound, and three source/test imports of `Keiro.Dsl`. Apply both the package record API migration and explicit generated-edition adoption. |
| `mori://shinzui/keiro-runtime-docs` | Documentation only | Mirrors and explains keiro-dsl but contains no Cabal dependency, Haskell import, ledger, or generated Haskell. Refresh prose through that project's normal source-sync process; no compile migration here. |
| `mori://shinzui/keiro-runtime-patterns` | Documentation only | References keiro-dsl patterns and plans but contains no Cabal dependency, Haskell import, ledger, or generated Haskell. No compile migration. |
| `mori://shinzui/kanmon` | No DSL use found | No searched package, import, ledger, generated Haskell, or relevant documentation match. |
| `mori://shinzui/kawa` | No DSL use found | No searched package, import, ledger, generated Haskell, or relevant documentation match. |
| `mori://shinzui/keiro-syntax` | No DSL use found | No searched package, import, ledger, or generated Haskell match. |
| `mori://shinzui/kikan` | No DSL use found | Its coarse Keiro reference does not resolve to a keiro-dsl package or generated API use. |
| `mori://shinzui/kizashi` | No DSL use found | No searched package, import, ledger, or generated Haskell match. |
| `mori://shinzui/meibo` | No DSL use found | No searched package, import, ledger, or generated Haskell match. |
| `mori://shinzui/mori-app` | No DSL use found | The registered app project has no separate keiro-dsl package, import, ledger, or generated source; the actual Mori workspace use belongs to `mori://shinzui/mori`. |
| `mori://shinzui/kioku` | No DSL use found | Registered package edges target Keiro runtime and migrations only. Kioku's own changelog and plans explicitly state that it does not consume `keiro-dsl`. |


## Release implication

An empty package-specific reverse-dependency result is not evidence of zero users.
The six generated consumers above need an attributed, project-owned migration when
they choose the new toolchain; this plan does not edit those repositories. `rei` is
the only registered project found to require the package Haskell API migration as
well as the generated edition. Documentation mirrors should be refreshed after the
new release contract is final.

The supported procedures are
[`migrating-keiro-dsl-record-api-0.15.md`](../guides/migrating-keiro-dsl-record-api-0.15.md)
and
[`adopting-keiro-dsl-idiomatic-v2.md`](../guides/adopting-keiro-dsl-idiomatic-v2.md).
