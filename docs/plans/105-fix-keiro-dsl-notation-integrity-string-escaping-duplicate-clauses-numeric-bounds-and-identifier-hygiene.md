---
id: 105
slug: fix-keiro-dsl-notation-integrity-string-escaping-duplicate-clauses-numeric-bounds-and-identifier-hygiene
title: "Fix keiro-dsl notation integrity: string escaping, duplicate clauses, numeric bounds, and identifier hygiene"
kind: exec-plan
created_at: 2026-07-13T18:56:58Z
intention: "intention_01kxed7haee7ja78qm70cc6qm5"
master_plan: "docs/masterplans/15-harden-and-extend-the-keiro-dsl-toolchain-surfaced-by-the-2026-07-dsl-audit.md"
---

# Fix keiro-dsl notation integrity: string escaping, duplicate clauses, numeric bounds, and identifier hygiene

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

keiro-dsl is the toolchain over a typed `.keiro` specification of a keiro service: a
parser (`keiro-dsl/src/Keiro/Dsl/Parser.hs`) turns spec text into an AST
(`keiro-dsl/src/Keiro/Dsl/Grammar.hs`), a pretty-printer
(`keiro-dsl/src/Keiro/Dsl/PrettyPrint.hs`) renders the AST back to text, a validator
checks it, and a scaffolder emits Haskell. The pretty-printer's stated contract (its own
module header) is `parseSpec (renderSpec s) == Right s`. Today that contract is false and,
worse, false *silently*: a string value containing a double-quote renders to text that
re-parses into a **different spec with exit 0**. Confirmed repro: an `emit` map row whose
value contains `"` renders and re-parses as TWO rows (evidence in Context below). There is
also no way for an author to write a legitimate `"` in any quoted string at all.

Beyond escaping, the notation currently accepts and silently mangles several other inputs:
duplicate `wire`/`projection` blocks and duplicate `goto` clauses are silently
first-wins-dropped; decimal literals silently wrap on `Int` overflow
(`schemaVersion=18446744073709551617` parses to `1`, confirmed); identifiers that generate
un-compilable Haskell (Haskell keywords as field names, lowercase aggregate names,
state/event constructor collisions) pass `check` and only explode later at GHC — breaking
the toolchain's core promise that `check` green implies `scaffold` output compiles. Three
error messages point at the wrong place. Finally, the round-trip property tests only
aggregate nodes over safe alphabets (so none of this was caught), and the unit suite only
runs from `keiro-dsl/` (fixture paths are cwd-relative).

After this plan: every AST renders to text that re-parses to the identical AST (proved by
a property over ALL node families with adversarial strings); ambiguous or overflowing
input is rejected loudly with a caret on the right line; a spec that passes `check` cannot
fail GHC for identifier-legality reasons; and the unit suite passes from any working
directory. Observable outcome: `keiro-dsl parse` on a spec containing `"a\" => Wat \"b"`
prints back one row, not two; `keiro-dsl check` on a duplicate `goto` exits non-zero with
a line-numbered error.


## Progress

- [x] M1: unit suite runs from any cwd (fixture-resolution helper, C8). Completed 2026-07-13T20:57:16Z; 112 examples passed from both the repository root and `keiro-dsl/`.
- [x] M2: string escaping in `stringLit` + `dquoted`, quoted-binding re-escape, unit tests, adversarial round-trip test (C1). Completed 2026-07-13T21:01:17Z; 116 examples passed and the CLI smoke printed exactly one escaped map row.
- [x] M3: `status-map partial { … }` concrete syntax for `mapPartial` (parser, printer, generator, NOTATION.md snippet) (C2). Completed 2026-07-13T21:03:28Z; 117 examples passed with totality suppression and round-trip coverage.
- [x] M4: duplicate `wire`/`projection`/`goto` rejected with positioned errors; missing-goto reported at the transition line; dash-aware keyword boundary; `try pRegDecl` removed (C3 + C6). Completed 2026-07-13T21:05:55Z; 122 examples passed and the CLI rejected the duplicate `goto` at line 10, column 5.
- [x] M5: bounded decimals at all seven `L.decimal` sites (C4). Completed 2026-07-13T21:08:42Z; all seven overflow fixtures and the `maxBound` boundary passed in the 130-example suite, and the CLI rejected the audited wraparound value.
- [x] M6: identifier hygiene validator rules + parser ASCII alphabet (C5). Completed 2026-07-13T21:15:14Z; 134 examples passed, all skeletons validate, and the CLI emitted the expected line-3/line-7 hygiene diagnostics.
- [x] M7: round-trip property extended to all node families with adversarial generators and empty-list edges; `states` accepts zero names; NOTATION.md touch-ups (C7). Completed 2026-07-13T21:22:23Z; the standard 136-example suite passed and a 1,000-case stress run covered every node family.
- [ ] Full keiro-dsl test matrix green (unit + all conformance suites); Outcomes written.

Implementation started 2026-07-13; M1 through M7 are complete and the full package matrix is next.


## Surprises & Discoveries

- The audit that motivated this plan counted "six `L.decimal` sites"; verification by
  `grep -n "L.decimal" keiro-dsl/src/Keiro/Dsl/Parser.hs` finds **seven**: lines 407
  (`pVersion`), 420 (wire `schemaVersion`), 470 (contract `schemaVersion`), 570 (decode
  `schemaVersion ==`), 656 (publisher `maxAttempts`), 697 (workqueue `maxRetries`), and
  1001 (timer `max-attempts`). All seven get the bound check.
- The cwd baseline was sharper than a generic failure: the package-directory run passed
  all 112 examples, while the repository-root run failed exactly 100 examples, all on
  unresolved `test/fixtures/` or `test/conformance/` paths. After routing reads through
  `resolveTestPath`, both invocation forms pass all 112 examples.
- M6 disproved the authoring-time claim that every starter skeleton was already
  identifier-safe. The aggregate skeleton declared state `Done` and event `ThingDone`;
  the live scaffolder's `vertexCtor` concatenation generates `ThingDone` for that state,
  so the two constructors collide. The skeleton now uses event `ThingCompleted`, keeping
  its state machine behavior while making `new aggregate` pass the new validator rule.
- M7's all-family property found two cross-node parser ambiguities that the former
  aggregate-only generator could not reach. `process` and top-level `dispatch` were
  absent from `reservedWords`, so an immediately preceding aggregate tried to parse them
  as transition sources. Separately, top-level `emit Name {` after a transition was
  swallowed as the transition clause `emit Name`, leaving `{` stranded. The parser now
  reserves both node keywords and makes the clause arm backtrack when `{` follows.
- (During implementation, record further discoveries here with short evidence snippets.)


## Decision Log

- Decision: escape scheme is Haskell-style backslash escapes with the closed set
  `\"`, `\\`, `\n`, `\t`, `\r`. A raw (unescaped) newline inside a quoted string is a
  parse error; an unknown escape (`\x` for any other x) is a parse error.
  Rationale: familiar to every Haskell author; the closed set keeps future escape
  extensions backward-compatible (unknown escapes are already errors, not silently
  literal); rejecting raw newlines keeps quoted strings single-line so a missing closing
  quote fails on the same line instead of swallowing the rest of the file. Raw tabs and
  other non-LF characters are still accepted raw on input; the printer normalizes `"`,
  `\`, LF, TAB, CR to their escapes and passes everything else through, so
  `parse . pretty == id` holds for every possible `Text` value.
  Date: 2026-07-13.
- Decision: the AST keeps storing the RAW (unescaped) text in every string-carrying field;
  escaping is purely a surface-syntax concern of Parser/PrettyPrint. This is the explicit
  cross-plan contract with docs/plans/106-harden-the-keiro-dsl-scaffolder-template-injection-firewall-completeness-collision-and-stale-module-detection-and-faithful-policy-lowering.md
  (see Context, "Cross-plan contract").
  Date: 2026-07-13.
- Decision: `mapPartial` gets concrete syntax (`status-map partial { … }`) rather than
  being deleted. Rationale: the suppression story is legitimate — an author sometimes
  wants a projection status-map that deliberately does not cover every event (events that
  do not change the projected status), and the validator's `StatusMapNotTotal` rule
  (`Validate.hs:447`) already honors the flag; the only thing missing is a way to write
  and print it. Deleting the field would remove a designed-for capability and force
  authors to add meaningless identity rows.
  Date: 2026-07-13.
- Decision: duplicate `wire`/`projection` blocks and duplicate `goto` clauses are rejected
  in the PARSER (positioned parse error at the duplicate), not the validator. Rationale:
  the duplicates are invisible after parsing — `pAggregate` (Parser.hs:310-311) collapses
  them with `listToMaybe` and the goto fold (Parser.hs:1112-1114) takes the head — so a
  validator rule would require widening the `Aggregate`/`Transition` AST to lists, which
  ripples into `Keiro.Dsl.Scaffold`/`Keiro.Dsl.Validate`/`Keiro.Dsl.Diff` (files owned by
  sibling plans). A parse error at the second occurrence's offset is loud, precise, and
  keeps the AST unchanged. Multiple `guard` clauses continue to fold into `EAnd`
  (intentional, per the grammar's design).
  Date: 2026-07-13.
- Decision: identifier hygiene is enforced in the VALIDATOR (three new `DiagnosticCode`s
  with line numbers from the owning declaration's `Loc`), except for the character
  alphabet, which tightens in the parser (`ident`/`wireWord` become ASCII-only).
  Rationale: keyword/Pascal/collision legality depends on the name's CATEGORY (a field
  name vs an aggregate name have different rules) and on sibling declarations
  (constructor collisions), which only the validator can see; putting them there yields
  uniform machine-matchable codes. The alphabet, by contrast, is a property of the lexeme
  itself, and keeping unicode out at the lexer also keeps it out of `wireWord` tokens
  (context names become module paths via `pascalFromKebab`). The parser stays otherwise
  liberal so any parseable name still round-trips.
  Date: 2026-07-13.
- Decision: C8 (cwd assumption) is fixed with a fixture-resolution helper in
  `keiro-dsl/test/Main.hs` — probe `test/fixtures/…` relative to cwd, then
  `keiro-dsl/test/fixtures/…`, then a `KEIRO_DSL_TEST_ROOT` environment override, and fail
  with a self-explanatory message otherwise. Rationale: smallest robust fix. Cabal
  `data-files`/`Paths_keiro_dsl` changes packaging and points at an install location that
  diverges from the source tree during development; `getExecutablePath` depends on
  dist-newstyle layout. The probe covers the two real invocation points (repo root and
  package dir), and the env var covers everything else.
  Date: 2026-07-13.
- Decision: expand M6's file scope to `keiro-dsl/src/Keiro/Dsl/Skeleton.hs` solely to
  rename the aggregate starter's colliding `ThingDone` event to `ThingCompleted`.
  Rationale: the new `VertexCtorCollision` diagnostic correctly exposed that the
  existing starter violated the plan's non-negotiable acceptance criterion that every
  `new <kind>` skeleton validate cleanly. Leaving a built-in invalid skeleton or
  weakening the diagnostic would contradict the purpose of M6.
  Date: 2026-07-13.
- Decision: disambiguate a transition `emit EventName` clause from a top-level
  `emit NodeName {` block by looking ahead for `{` after the name and backtracking only
  in the block case. Also reserve every current top-level node keyword, including the
  previously omitted `process` and `dispatch`.
  Rationale: the DSL is intentionally whitespace-insensitive, so indentation cannot be
  the boundary. The opening brace is the existing syntactic distinction and preserves
  every valid transition clause while making mixed-node specs round-trip.
  Date: 2026-07-13.
- Decision: `pStatesLine` changes from `some pStateDecl` to `many pStateDecl` so an
  aggregate with zero states is *representable* and the printer's output for it re-parses
  (today `renderSpec` of an empty-states aggregate prints `states` followed by nothing,
  which is unparseable — confirmed, see Context). Whether an empty state list is *valid*
  is a semantic question left to the validator plans; the notation-integrity invariant
  this plan owns is "everything the printer emits re-parses".
  Date: 2026-07-13.


## Outcomes & Retrospective

(To be filled during and after implementation.)


## Context and Orientation

### Standing assumption

keiro MasterPlan 14
(docs/masterplans/14-harden-the-keiro-command-coordination-and-snapshot-paths-surfaced-by-the-2026-07-keiki-path-review.md)
is implemented first. This plan changes ONLY the `keiro-dsl` package (its `src/`, `test/`,
and `keiro-dsl.cabal` test-suite stanza) plus the authoring-skill docs under
`agents/skills/keiro-dsl-authoring/` — never the runtime packages (`keiro`, `keiro-core`,
`keiro-pgmq`, `kiroku*`, `keiki`).

### The package, in one paragraph

A `.keiro` file describes a keiro service (aggregates, process managers, Kafka
contracts/intakes/emits/publishers, pgmq workqueues/dispatches, workflows/operations).
`keiro-dsl/src/Keiro/Dsl/Parser.hs` (megaparsec) parses it into the `Spec` AST defined in
`keiro-dsl/src/Keiro/Dsl/Grammar.hs`; `keiro-dsl/src/Keiro/Dsl/PrettyPrint.hs` renders a
`Spec` back to text; `keiro-dsl/src/Keiro/Dsl/Validate.hs` produces line-numbered
`Diagnostic` values (machine-matchable `DiagnosticCode`s); `keiro-dsl/src/Keiro/Dsl/Scaffold.hs`
and `Harness.hs` emit Haskell modules from the AST; `keiro-dsl/src/Keiro/Dsl/Skeleton.hs`
holds the `new <kind>` starter specs (a test pins that every skeleton parses and validates
clean — your parser changes must keep them parseable). The CLI lives in
`keiro-dsl/app/Main.hs` (`keiro-dsl new|parse|check|scaffold|diff`). Unit tests and the
QuickCheck round-trip property live in `keiro-dsl/test/Main.hs`; fixtures under
`keiro-dsl/test/fixtures/`; committed known-compiling scaffolder output under
`keiro-dsl/test/conformance*/` (compiled by 16 conformance test-suites listed in
`keiro-dsl/keiro-dsl.cabal`). `Loc` (Grammar.hs:119-127) is a line-number newtype whose
`Eq` ignores the value, so ASTs compare equal modulo source position — this is what makes
`parse . pretty == id` a well-posed property.

### C1 — no string escaping in either direction (the headline silent misparse)

`stringLit` (Parser.hs:1084-1089) accepts any character except `"` with NO escapes:

```haskell
stringLit :: P Text
stringLit = lexeme $ do
    _ <- char '"'
    s <- many (anySingleBut '"')
    _ <- char '"'
    pure (T.pack s)
```

`dquoted` (PrettyPrint.hs:366-367) wraps without escaping:

```haskell
dquoted :: Text -> Doc ann
dquoted t = "\"" <> pretty t <> "\""
```

Confirmed repro (run from the repo root; `cabal repl keiro-dsl`, then build an `EmitNode`
whose single map row is `EmitMapRow { emrValue = "a\" => Wat \"b", emrEvent = "ThingAccepted" }`
inside a minimal `Spec`, render, re-parse). The rendered text contains:

```text
  map status {
    "a" => Wat "b" => ThingAccepted
    _ => skip
  }
```

and re-parsing yields TWO rows — `(["a","b"],["Wat","ThingAccepted"])` — with
`spec2 == spec` printing `False` and no error anywhere. One row in, two rows out, exit 0.
Every `dquoted` field is affected: Kafka topics and `emit` sources, saga stream prefixes
and timer id prefixes, dead-letter reasons, wire names (`WqField`), header names,
`procName`, `wfStable`, workqueue logical/physical/dlq/table names, `derive` prefixes.
There is also no way to author a legitimate `"` at all.

One subtlety: `pBindingValue` (Parser.hs:1067-1072) stores QUOTED literals
quote-WRAPPED in `fbValue :: Maybe Text` (`Just ("\"" <> inner <> "\"")`), and
`docFieldBinding` (PrettyPrint.hs:361-364) prints `fbValue` verbatim. After this plan the
convention stays "wrapped means literal, and the wrapped inner text is RAW", so
`docFieldBinding` must strip the wrap and re-emit the inner through the escaping `dquoted`.

### Cross-plan contract with docs/plans/106 (state explicitly so either can land first)

`payloadExpr` (Scaffold.hs:733-738) splices the quote-wrapped `fbValue` VERBATIM into
generated Haskell — the scaffolder's one unescaped splice. Fixing that splice belongs to
docs/plans/106-harden-the-keiro-dsl-scaffolder-template-injection-firewall-completeness-collision-and-stale-module-detection-and-faithful-policy-lowering.md.
The agreed semantics both plans implement:

1. The AST stores raw, unescaped text in every string-carrying field. For `FieldBinding`
   specifically, a literal is `fbValue = Just ("\"" <> rawInner <> "\"")` where `rawInner`
   is unescaped; a reference is `fbValue = Just ref` with no leading quote.
2. `.keiro` surface escaping (THIS plan, Parser/PrettyPrint only): `\"`, `\\`, `\n`, `\t`,
   `\r`; raw LF inside quotes is a parse error; unknown escapes are parse errors; the
   printer escapes exactly `"`, `\`, LF, TAB, CR.
3. Generated-Haskell escaping (plan 106, Scaffold only): any AST text spliced into
   generated Haskell in string position is rendered with `show`-equivalent escaping (the
   `tshow` helper every other Scaffold site already uses); for `FieldBinding` literals
   that means unwrap the quotes and `tshow` the raw inner.

The two plans touch disjoint files and share only invariant (1), which already holds
today, so they can land in either order. Risk note if 105 lands first alone: escaping
makes embedded quotes *writable*, which widens the trigger surface of the pre-existing
Scaffold splice bug until 106 lands — acceptable inside one MasterPlan train, recorded
here so the ordering is a conscious choice.

### C2 — `mapPartial` is unwritable, unprintable, load-bearing

`Mapping` (Grammar.hs:195-199) carries `mapPartial :: Bool`; the validator's totality rule
consults it (Validate.hs:440-454, the `| mapPartial m -> True` guard at :447); yet
`pStatusMap` (Parser.hs:447-457) always constructs `mapPartial = False` and
`docProjection` (PrettyPrint.hs:441-451) never renders it. Decision (see Decision Log):
add syntax `status-map partial { … }`.

### C3 — duplicate blocks/clauses silently first-wins

`pAggregate` (Parser.hs:294-315) collapses duplicates with a local `listToMaybe` at
:310-311 (`aggWire`, `aggProjection`); `pTransition` (Parser.hs:1104-1125) takes the head
of the goto list at :1112-1114. Confirmed: a transition declaring `goto B` then `goto C`
parses with `tGoto = "B"`; an aggregate with two contradictory `wire` blocks keeps the
first (`schemaVersion=1` wins over `schemaVersion=2`), both exit 0. Multiple `guard`
clauses folding to `EAnd` (Parser.hs:1120) is intentional and stays.

### C4 — decimal overflow wraps

All seven `L.decimal` sites (lines listed in Surprises) parse into `Int`; megaparsec's
`L.decimal` at `Int` silently wraps. Confirmed:
`wire kind=ctorName fields=camelCase schemaVersion=18446744073709551617` parses to
`wireSchemaVersion = 1` (2^64 + 1 wrapped), exit 0.

### C5 — identifier hygiene: what GHC will reject that `check` accepts

`ident` (Parser.hs:138-145) accepts any `[letter_][alphaNum_]*` that is not a DSL reserved
word — including Haskell keywords (`data`, `type`, `where`, …), unicode letters, and
lowercase names for nodes whose names become module segments and type names. Where names
flow, verified in source:

- Aggregate names flow UNPASCALED: `scaffoldAggregate` uses `nm = aggName agg`
  (Scaffold.hs:217) for `genPrefixFor`/`holePrefixFor` (module segments, :213-214), the
  vertex type `nm <> "Vertex"` (:219), and the event/command sum types and `mkEventStreamOrThrow`
  name; `aggregate thing` scaffolds module `Generated.<Ctx>.thing` and `data thingEvent` —
  GHC errors, `check` green.
- Process ids flow UNPASCALED: `genPrefixFor ctx (procId p)` (Scaffold.hs:667, also
  Harness.hs:61), plus `lowerFirst (procId p)` as a function-name prefix (Scaffold.hs:724).
- Workflow ids flow UNPASCALED: `genPrefixFor ctx (wfId w)` (Harness.hs:130).
- Contract/intake/publisher/workqueue names DO go through `pascal`
  (Scaffold.hs:309, 425, 495, 548), but `pascal` (Scaffold.hs:1354-1357) only upcases the
  FIRST character — a `_`-leading name stays `_`-leading (invalid module segment/conid).
- Command/event names become constructors of the `<Agg>Command`/`<Agg>Event` sums; enum
  names/ctors, id names, process input names, and workqueue payload names become type or
  constructor names — all must be uppercase-leading conids.
- Field-position names (command/event fields, register names, input fields, workqueue
  payload field names, contract field names, field-binding names) become record fields
  and `payload.<field>` projections (e.g. Scaffold.hs:1029) — must be lowercase-or-`_`
  leading varids and NOT Haskell keywords.
- Vertex constructors are `aggName <> stateName` (`vertexCtor`, Scaffold.hs:1302-1303) and
  live in the same generated Domain module as the event/command/enum constructors:
  `aggregate Reservation` with state `Created` plus event `ReservationCreated` generates
  the constructor `ReservationCreated` TWICE → GHC "Multiple declarations" — with no
  duplicate visible anywhere in the spec text.

Scope split with docs/plans/104-close-the-keiro-dsl-validator-soundness-holes-workflows-rules-cross-node-references-and-disposition-tables.md:
plan 104 owns DUPLICATE-name detection for names the author literally wrote twice (two
aggregates named `Thing`, duplicate enum ctors, duplicate id prefixes, case-variant module
collisions). THIS plan owns notation-level LEGALITY — what strings may be a name at all in
each category — plus the `vertexCtor` collision, because that collision is between
*generated* names, not author-written duplicates, and is therefore a legality property of
the single aggregate.

### C6 — three error-message defects

- Missing `goto`: `pTransition` fails AFTER consuming all clauses (Parser.hs:1112-1114),
  so megaparsec reports the error at the FOLLOWING construct's line, not the transition's.
- Dash-blind keyword boundary: `keyword` (Parser.hs:60-66) checks `notFollowedBy identChar`
  and `-` is not an ident char, so `keyword "dispatch"` matches the prefix of
  `dispatch-id`; an author who writes the `dispatch-id` line before `schedule` gets a
  committed mid-word failure with a misleading caret (inside `pHandle`'s `many pDispatch`).
- `pRegsBlock = many (try pRegDecl)` (Parser.hs:317-321): the `try` erases the informative
  committed failure of a malformed reg (`foo Bar` missing `= initial`) into "expecting
  states" at the wrong place. The `try` is unnecessary: `ident` is itself
  `(lexeme . try)` and fails WITHOUT consuming on the reserved word `states`, so plain
  `many pRegDecl` terminates cleanly at the `states` line while letting a malformed reg
  fail loudly at its `=`.

### C7 — round-trip property covers almost nothing

`genSpec` (test/Main.hs:554-563) generates ONLY aggregate nodes, over safe alphabets
(`genName`/`genWire`, test/Main.hs:440-450). None of C1-C5 is reachable. Also confirmed:
an `Aggregate` with `aggStates = []` renders to text ending in a bare `states` line that
fails to re-parse (`unexpected end of input, expecting '_' or letter`) — the printer can
emit unparseable text for representable ASTs.

### C8 — cwd assumption

Every fixture read in `keiro-dsl/test/Main.hs` is relative (`test/fixtures/…`,
`test/conformance/…` in `assertMatchesCommitted`, test/Main.hs:412-416). From the repo
root, `cabal run keiro-dsl-test` fails dozens of examples with file-not-found; only
`cwd = keiro-dsl/` works.


## Plan of Work

All file paths are repo-relative. Work happens in `keiro-dsl/src/Keiro/Dsl/Parser.hs`,
`keiro-dsl/src/Keiro/Dsl/PrettyPrint.hs`, `keiro-dsl/src/Keiro/Dsl/Validate.hs`,
`keiro-dsl/src/Keiro/Dsl/Skeleton.hs`, `keiro-dsl/test/Main.hs`,
`keiro-dsl/keiro-dsl.cabal` (test-suite deps only), and
`agents/skills/keiro-dsl-authoring/NOTATION.md`. `Skeleton.hs` receives only the M6
aggregate-event rename documented in the Decision Log. `Grammar.hs`, `Scaffold.hs`,
`Harness.hs`, `Diff.hs`, `Manifest.hs`, and `app/Main.hs` are NOT edited (sibling plans
own their fixes; the skeletons and committed conformance sources must stay parseable/green
under the changes here — the existing tests enforce that).

### Milestone 1 — run the unit suite from any cwd (C8)

Scope: make `keiro-dsl-test` pass regardless of working directory, so every later
milestone can be verified from the repo root. Add to `keiro-dsl/test/Main.hs` a resolver:

```haskell
-- | Locate a repo file (fixtures, committed conformance sources) regardless of cwd:
-- probe relative to cwd, then under keiro-dsl/, then $KEIRO_DSL_TEST_ROOT.
resolveTestPath :: FilePath -> IO FilePath
```

implemented with `System.Directory.doesFileExist` probes in the order: `rel`,
`"keiro-dsl" </> rel`, `root </> rel` for `root` from `lookupEnv "KEIRO_DSL_TEST_ROOT"`,
else `fail` with a message naming all three attempts. Route every `TIO.readFile` of a
fixture and the `assertMatchesCommitted` conformance read (test/Main.hs:414) through it —
the cleanest edit is inside the existing helpers (`diagnosticCodesOf`, `errorCodesOf`,
`diffFixtures`, `specOf`, `scaffoldFixture`, `scaffoldProcessFixture`,
`assertMatchesCommitted`) plus the handful of inline `TIO.readFile` calls in test bodies.
Add `directory` and `filepath` to the `keiro-dsl-test` stanza's `build-depends` in
`keiro-dsl/keiro-dsl.cabal`. At the end of this milestone the suite passes from both the
repo root and `keiro-dsl/`.

### Milestone 2 — string escaping both directions (C1)

Scope: after this milestone, every `Text` value round-trips through
`dquoted`/`stringLit`, embedded quotes are authorable, and the confirmed two-rows repro
is dead.

In `Parser.hs`, replace `stringLit` (currently :1084-1089) with an escape-aware version:

```haskell
stringLit :: P Text
stringLit = lexeme $ do
    _ <- char '"'
    s <- many strChar
    _ <- char '"'
    pure (T.pack s)
  where
    strChar =
        choice
            [ char '\\' *> escapeCode
            , '\n' <$ (char '\n' *> fail "unescaped newline in string literal (write \\n)")
            , anySingleBut '"'
            ]
    escapeCode =
        choice
            [ '"' <$ char '"'
            , '\\' <$ char '\\'
            , '\n' <$ char 'n'
            , '\t' <$ char 't'
            , '\r' <$ char 'r'
            , anySingle >>= \c -> fail ("unknown escape sequence \\" <> [c] <> " in string literal")
            ]
```

(The exact combinator arrangement may differ — e.g. hanging the newline rejection off a
lookahead — but the observable behavior is fixed: the five escapes decode, raw LF and
unknown escapes fail with those messages, everything else passes raw.)

In `PrettyPrint.hs`, make `dquoted` (:366-367) escape:

```haskell
dquoted :: Text -> Doc ann
dquoted t = "\"" <> pretty (T.concatMap esc t) <> "\""
  where
    esc '"' = "\\\""
    esc '\\' = "\\\\"
    esc '\n' = "\\n"
    esc '\t' = "\\t"
    esc '\r' = "\\r"
    esc c = T.singleton c
```

Fix the quoted-binding printer: `docFieldBinding` (PrettyPrint.hs:361-364) currently
prints `fbValue` verbatim. Change the `Just v` arm to detect the literal convention
(`"\"" `T.isPrefixOf` v`), strip the wrapping quotes, and render the raw inner through the
new `dquoted`; references keep printing verbatim. (`pBindingValue`, Parser.hs:1067-1072,
needs no structural change — its `quoted` arm already wraps `stringLit`'s now-unescaped
inner text.)

Tests in `keiro-dsl/test/Main.hs`: a unit example parsing an `emit` spec whose map row is
written `"a\" => Wat \"b" => ThingAccepted` and asserting exactly ONE `EmitMapRow` with
`emrValue == "a\" => Wat \"b"`; a unit example asserting a raw newline inside quotes is a
`Left` whose message contains `unescaped newline`; a unit example asserting `\q` is a
`Left` containing `unknown escape`; and a focused property
`forAll genAdversarialText $ \t -> roundTripsVia (specWithTopic t)` embedding the text in
a contract topic, an emit-map value, and a quoted field binding (three placements, since
each exercises a different printer path), where `genAdversarialText` draws from an
alphabet including `"`, `\`, LF, TAB, CR, `=>`, `#`, `{`, `}`, spaces.

### Milestone 3 — concrete syntax for `mapPartial` (C2)

Scope: `status-map partial { … }` parses, prints, generates, and is documented; the
existing `StatusMapNotTotal` suppression becomes reachable from the notation.

Parser: in `pStatusMap` (Parser.hs:447-457), after `keyword "status-map"`, parse
`partial <- option False (True <$ keyword "partial")` and construct
`Mapping{mapPairs = pairs, mapPartial = partial}`. `partial` need not join
`reservedWords` — it appears only between `status-map` and `{`, where no identifier can
occur. Printer: in `docProjection` (PrettyPrint.hs:441-451), render
`"status-map partial"` when `mapPartial m`. Generator: in `genProjection`
(test/Main.hs:517-524), replace `pure False` with `arbitrary` so the round-trip property
covers both. Validator: no change — Validate.hs:447 already honors the flag.

Tests: a unit example that a spec with an intentionally non-total
`status-map partial { Created => held }` produces NO `StatusMapNotTotal` diagnostic,
while the same spec without `partial` still does (mirroring the existing
`reservation-no-statusmap.keiro` example); plus the property now covering the flag.
NOTATION.md: extend the aggregate snippet's status-map line with the `partial` variant and
one sentence ("`status-map partial { … }` opts out of the totality check for events that
do not change the projected status").

### Milestone 4 — reject duplicates loudly; fix the three error positions (C3 + C6)

Scope: duplicate `wire`/`projection`/`goto` become positioned parse errors; missing-goto
points at the transition; `dispatch-id` misplacement gets a sane error; malformed reg
decls fail at their `=`.

Add a positioning helper to `Parser.hs`:

```haskell
-- | Fail with the error caret placed at a previously captured offset.
failAt :: Int -> String -> P a
failAt o msg = region (setErrorOffset o) (fail msg)
```

(`region`, `setErrorOffset`, `getOffset` are all in `Text.Megaparsec`, megaparsec >= 9.6
per the cabal bounds.)

Duplicate `goto` and missing `goto`: in `pTransition` (Parser.hs:1104-1125), capture
`startOff <- getOffset` before `src <- ident`, and parse clauses with their offsets:
`cs <- many ((,) <$> getOffset <*> (pClause <* optional (symbol ";")))`. Then: if the
goto list `[(o, n) | (o, CGoto n) <- cs]` is empty, `failAt startOff ("transition " <> … <> " is missing a goto clause")`
(same message as today, now anchored to the transition's own line); if it has two or more,
`failAt` at the SECOND goto's offset with
`"duplicate goto clause (transition … already declared goto <first>)"`.

Duplicate `wire`/`projection`: in `pAggregate` (Parser.hs:294-315), parse body items with
offsets (`many ((,) <$> getOffset <*> pBodyItem)`); when assembling, if
`[o | (o, BIWire _) <- items]` has a second element, `failAt` that offset with
`"duplicate wire block in aggregate <name> (only one is allowed)"`; identically for
`BIProjection`. The first occurrence still populates the record fields, so the AST shape
is unchanged.

Dash-aware keyword boundary: change `keyword` (Parser.hs:60-66) to also reject a dash that
continues into a word:

```haskell
keyword w = (lexeme . try) (chunk w *> notFollowedBy (identChar <|> (char '-' *> identChar)))
```

The two-character lookahead matters: `outcome->` (an author omitting the space before the
arrow in an operation) must still lex `outcome` as a keyword because `-` is followed by
`>`, not an identifier character. With this change `keyword "dispatch"` no longer matches
the prefix of `dispatch-id`, so `many pDispatch` in `pHandle` (Parser.hs:941-949) stops
cleanly and a misplaced `dispatch-id` line (written before `schedule`) yields an error at
the line's start expecting `schedule`, instead of a mid-word caret after `dispatch`. The
dashed keywords themselves (`status-map`, `on-appended`, `kafka-key`, `fired-event-id`,
`dispatch-id`, `cross-check`, `not-mine`, `max-attempts`, `dead-letter`,
`unknown-status`, …) are unaffected — the boundary check runs after the full literal.

Reg decls: change `pRegsBlock` (Parser.hs:317-321) to `many pRegDecl` (drop the `try`).
`ident`'s internal `try` already backtracks without consuming on the reserved word
`states`, so the list still terminates; a malformed decl (`foo Bar` with no `=`) now fails
committed at the `=` position with megaparsec's `expecting '='`.

Tests: unit examples asserting (a) duplicate-goto input produces `Left` whose message
contains `duplicate goto` and the rendered error names the LINE of the second goto;
(b) two `wire` blocks produce `Left` containing `duplicate wire block`, at the second
block's line; same for `projection`; (c) the missing-goto fixture error names the
transition's own line (assert the `:<line>:` fragment of `errorBundlePretty` output);
(d) `dispatch-id` before `schedule` yields an error mentioning `schedule` positioned at
column 1-5 of the `dispatch-id` line, not after the word `dispatch`; (e) `foo Bar` in a
regs block yields an error containing `'='`. Also re-run the skeleton test
(test/Main.hs:273-279) — all ten `new <kind>` templates in `Skeleton.hs` must still parse
(they contain `dispatch-id`, dashed keywords, and single `wire`/`goto` uses; verified by
reading Skeleton.hs that none relies on the removed leniencies).

### Milestone 5 — bounded decimals (C4)

Scope: all seven `L.decimal` sites reject out-of-range instead of wrapping.

Add to `Parser.hs`:

```haskell
-- | A decimal Int literal that REJECTS values exceeding maxBound (L.decimal at Int
-- silently wraps on overflow). Parses at Integer, then bounds-checks.
boundedDecimal :: P Int
boundedDecimal = do
    o <- getOffset
    n <- lexeme (L.decimal :: P Integer)
    if n > fromIntegral (maxBound :: Int)
        then failAt o ("decimal literal " <> show n <> " is out of range (maximum " <> show (maxBound :: Int) <> ")")
        else pure (fromIntegral n)
```

Replace the seven uses: `pVersion` (:407, keep the `try`/`notFollowedBy identChar`
wrapping but bound the digits — note the bound check must sit INSIDE the `try` so a
non-`vN` token still backtracks, while an over-range `vN` still errors; the simplest
arrangement is `pVersion = do { o <- getOffset; n <- lexeme (try (char 'v' *> (L.decimal :: P Integer) <* notFollowedBy identChar)); … failAt o … }`),
`pWire` (:420), `pContract` (:470), `pDecode` (:570), `pPublisher` (:656),
`pWorkqueue` (:697), `pTimerNode` (:1001). Semantic minimums (e.g. `max-attempts 0`,
version `>= 1`) are validator territory owned by docs/plans/104-…; this milestone is
strictly overflow soundness.

Tests: unit examples asserting `schemaVersion=18446744073709551617` is a `Left`
containing `out of range` (this exact input parses to `1` today — pin the fix against the
confirmed repro), and that `schemaVersion=9223372036854775807` (`maxBound`) parses to
exactly that value.

### Milestone 6 — identifier hygiene (C5)

Scope: `check` rejects, with line-numbered diagnostics, every identifier that would make
the scaffolder emit un-compilable Haskell; the parser's alphabet becomes ASCII.

Parser alphabet: in `Parser.hs`, restrict `ident` (:138-145) and `wireWord` (:151-155) to
ASCII — replace `letterChar`/`alphaNumChar`/`digitChar` in those two lexemes (and
`identChar`, :65-66, plus `dottedRef`, :1077-1081, and `pModulePrefix`'s segment parser,
:204-213) with ASCII-restricted equivalents (`satisfy isAsciiAlpha` style predicates).
Rationale in Decision Log; unicode names would otherwise flow into module paths and file
names (APFS case-insensitivity hazard belongs to plan 104/106; the alphabet belongs here).

Validator rules: in `Validate.hs`, add three `DiagnosticCode` constructors —
`IdentHaskellKeyword`, `IdentNotConstructorSafe`, `VertexCtorCollision` — and a
`validateNames :: Spec -> [Diagnostic]` pass invoked from `validateSpec` (:110-112).
Embed the Haskell keyword list in the module (with a comment naming the source):
`case class data default deriving do else foreign if import in infix infixl infixr instance let module newtype of then type where`
plus the extension keywords `mdo rec proc` (defensive: generated code may enable Arrows or
RecursiveDo someday; rejecting three more lowercase words costs nothing).

The checks, per name category (line numbers from the owning declaration's `Loc`; per-field
`Loc`s do not exist — `Field`, `StateDecl`, `FieldBinding` carry none, a known
Grammar limitation — so fields anchor to their `Command`/`Event`/process/workqueue
declaration's line):

- Module/type-position names that flow UNPASCALED — `aggName` (anchored at `aggLoc`),
  `procId` (`procLoc`), `wfId` (`wfLoc`): must match `[A-Z][A-Za-z0-9_]*`. Diagnostic
  `IdentNotConstructorSafe`, message naming the category and why ("aggregate name
  'thing' must be PascalCase: it becomes the module segment and type-name prefix in
  scaffolded code").
- Node names that pass through `pascal` — `ctrName`, `inkName`, `emName`, `pubName`,
  `wqName`, `pdName`: must not begin with `_` (pascal keeps `_`, producing an invalid
  module segment). Same code.
- Constructor-position names — `cmdName`, `evName` (per aggregate), `enumName` and each
  enum constructor, `idName`, `inName` (process input), `wqPayloadName`, contract event
  names (`ceName`): must match `[A-Z][A-Za-z0-9_]*`. Same code.
- Field/register-position names — `regName`, command/event `fieldName`s, process input
  fields, `wqfName`, `cfName`, `fbName` (advance/dispatch/payload bindings), `projKey`:
  must match `[a-z_][A-Za-z0-9_]*` AND not be a Haskell keyword (`IdentHaskellKeyword`,
  message: "field name 'data' is a Haskell keyword and cannot become a record field in
  generated code").
- Vertex-constructor collision, per aggregate: compute
  `vertexCtors = [aggName <> stName s | s <- aggStates]` (the exact `vertexCtor`
  derivation, Scaffold.hs:1302-1303) and report `VertexCtorCollision` (at `aggLoc`,
  naming the state and the colliding declaration) for any member that equals a declared
  event name, command name, or enum constructor of the spec — all of these are lowered
  into the same generated Domain module's constructor namespace. Canonical example in the
  message: aggregate `Reservation` + state `Created` collides with event
  `ReservationCreated`.

Deliberately NOT checked here (recorded so nobody "completes" this plan wrongly):
duplicate author-written names (plan 104); operation names (`opName`) and workflow
input/output type names, which are never spliced into module/type position (verified:
operations scaffold no modules; `WorkflowFacts`/`WorkflowRuntime` embed them only as
string data).

Tests: one unit example per rule using inline spec text (e.g.
`aggregate thing` → `IdentNotConstructorSafe`; `command DoIt { data }` →
`IdentHaskellKeyword`; the Reservation/Created/ReservationCreated collision →
`VertexCtorCollision`), each asserting the code AND that the diagnostic's `line` equals
the declaration's line; plus a guard example that the canonical
`test/fixtures/reservation.keiro` and every `Skeleton.hs` template validate with zero
errors. M6 implementation found and corrected the aggregate starter's `ThingDone`
vertex/event collision; the existing skeleton test pins the corrected result.

NOTATION.md: add a short "identifier legality" paragraph to the shared-declarations
section (ASCII; PascalCase for aggregate/process/workflow and all type/constructor
names; lowercase non-Haskell-keyword for fields/registers; the vertex-collision rule with
the Reservation/Created example).

### Milestone 7 — round-trip property over ALL node families, adversarially (C7)

Scope: the property test becomes the standing proof of notation integrity: every
generated `Spec` — all ten node families, adversarial strings, empty-list edges —
satisfies `parseSpec "<gen>" (renderSpec s) === Right s`.

First, one parser change so the printer's output for representable ASTs always re-parses:
`pStatesLine` (Parser.hs:331-346) changes `some pStateDecl` to `many pStateDecl` (see
Decision Log; the trailing `notFollowedBy (symbol "--")` guard and `ident`'s
reserved-word backtracking already make the empty case unambiguous — confirmed by the
grammar reading in Context).

Then extend `keiro-dsl/test/Main.hs` generators (:440-570):

- `genAdversarialText` (shared with Milestone 2): arbitrary `Text` over an alphabet
  including `"`, `\`, LF, TAB, CR, `#`, `=>`, braces, spaces, plus plain letters. Used for
  every `stringLit`-backed field: contract topics, `emSource`, `emrValue`, `wqLogical`/
  `wqPhysical`/`wqDlq`/`wqTable`, `wqfWire`, header names in `BindRow`, `procName`,
  `sagaStreamPrefix`, `idePrefix`, `tmDeadLetter`, dead-letter reasons in
  `IAckOk`/`IRetry`/`IDeadLetter` and `DDeadLetter`, `dsPrefix`, `wfStable`.
- `genName` gains near-keyword and keyword-prefix names within the parser-legal alphabet:
  `data1`, `typeA`, `whereX`, `gotoX`, `guardY`, `emitZ`, `_lead` — names the C5 validator
  may reject but the parser accepts (the property tests parse∘pretty, not validity; this
  is deliberate and stated in a comment).
- `genWireWord` for dashed tokens (enum wire spellings, status-map values, workflow
  step/await/sleep/child labels, signal labels): includes dashes and digit-leading forms.
- New node generators, each mirroring its grammar's shape so the printed form re-parses:
  `genProcess` (dotted refs like `input.hospitalId` for `dispKey`/`fireKey`; field
  bindings as `Nothing` | dotted ref | quote-wrapped adversarial literal per the
  Milestone 2 convention; windows from a `genWindow` of digit+unit tokens like `5s`,
  `2m`, `100ms`; full `DispatchDisposition`/`FireDisposition` tables), `genContract`
  (including zero topics and zero events), `genIntake` (NON-empty `inkAccept` — the
  grammar requires `some ident` and an empty accept list is meaningless; recorded
  asymmetry), `genEmit` (including zero rows and `emSkip` both ways), `genPublisher`,
  `genWorkqueue` (empty payload/disposition included), `genPgmqDispatch`, `genWorkflow`
  (empty body and empty `wfInputFields` included; `wfIdField` both `Nothing` and `Just`),
  `genOperation` (all four shapes; `QueryOp` result as one-or-two unwords-joined names;
  the printer always emits the `consistency` line and the parser defaults to `"Strong"`,
  so the generator draws consistency from non-reserved idents including `Strong`).
- `genAggregate` gains the empty edges: empty `aggStates` (now representable), empty regs,
  and `mapPartial` from Milestone 3.
- `genSpec` (:554-563) draws `specNodes` from ALL families:
  `smallList (oneof [NAggregate <$> genAggregate, NProcess <$> genProcess, …])`.

Keep generators bounded (the existing `smallList`/`nonEmptyList` discipline) so the
property stays fast. Bump the property to a comfortably large case count if runtime allows
(hspec default 100 is acceptable; do not shrink below it).

NOTATION.md: add the string-escaping sentence to the file's preamble (strings support
`\" \\ \n \t \r`; raw newlines must be escaped) and note that duplicate
`wire`/`projection`/`goto` are parse errors. Keep the edits minimal — the holistic
notation/skill refresh is owned by
docs/plans/110-align-keiro-dsl-with-the-safe-apis-and-refresh-the-authoring-skill-and-corpus.md.


## Concrete Steps

All commands run from the repo root `/Users/shinzui/Keikaku/bokuno/keiro` unless noted.

1. Baseline (before any edit) — confirm the suite is green from the package dir and
   currently RED from the root (the C8 symptom):

   ```bash
   cd keiro-dsl && cabal run keiro-dsl-test 2>&1 | tail -3 && cd ..
   cabal run keiro-dsl:test:keiro-dsl-test 2>&1 | tail -3   # expect failures before M1
   ```

2. Milestone 1: edit `keiro-dsl/test/Main.hs` (add `resolveTestPath`, route reads) and
   `keiro-dsl/keiro-dsl.cabal` (`directory`, `filepath` in the test stanza). Verify:

   ```bash
   cabal run keiro-dsl:test:keiro-dsl-test 2>&1 | tail -3
   cd keiro-dsl && cabal run keiro-dsl-test 2>&1 | tail -3 && cd ..
   ```

   Both must end in `0 failures`.

3. Milestones 2-7 in order: edit the files named in Plan of Work; after EACH milestone run
   the unit suite and the parse-level smoke below, and update the Progress checklist.

   ```bash
   cabal run keiro-dsl:test:keiro-dsl-test 2>&1 | tail -3
   ```

4. Escaping smoke (after M2). Write a scratch spec and round-trip it through the CLI:

   ```bash
   cat > /tmp/escape-smoke.keiro <<'EOF'
   context svc

   contract c {
     schemaVersion 1
     discriminator messageType
     topic events "svc.events"
     event ThingAccepted on events { thingId: text }
     event Wat on events { thingId: text }
   }

   emit e {
     contract c
     topic events
     source "svc"
     key thingId
     map status {
       "a\" => Wat \"b" => ThingAccepted
       _ => skip
     }
     messageId derive hole
     idempotencyKey derive hole
   }
   EOF
   cabal run -v0 keiro-dsl:exe:keiro-dsl -- parse /tmp/escape-smoke.keiro
   ```

   Expected: exit 0, and the printed map block contains exactly one row, escaped:

   ```text
     map status {
       "a\" => Wat \"b" => ThingAccepted
       _ => skip
     }
   ```

   (Before this plan the same AST content was unwritable, and the unescaped rendering
   re-parsed as two rows — the confirmed silent misparse.)

5. Duplicate/positioning smoke (after M4):

   ```bash
   printf 'context svc\n\naggregate Thing\n  regs\n  states A B C\n\n  command Go { }\n  A -- Go -->\n    goto B\n    goto C\n' > /tmp/dup-goto.keiro
   cabal run -v0 keiro-dsl:exe:keiro-dsl -- check /tmp/dup-goto.keiro; echo "exit=$?"
   ```

   Expected: non-zero exit; the error transcript carets line 10 (the second `goto`) and
   contains `duplicate goto`. Before this plan the same file exits 0 with `tGoto = "B"`.

6. Overflow smoke (after M5):

   ```bash
   printf 'context svc\n\naggregate Thing\n  regs\n  states Open\n\n  wire kind=ctorName fields=camelCase schemaVersion=18446744073709551617\n' > /tmp/overflow.keiro
   cabal run -v0 keiro-dsl:exe:keiro-dsl -- check /tmp/overflow.keiro; echo "exit=$?"
   ```

   Expected: non-zero exit, message contains
   `decimal literal 18446744073709551617 is out of range`. Before: exits 0 having parsed
   the value as `1`.

7. Hygiene smoke (after M6):

   ```bash
   printf 'context svc\n\naggregate thing\n  regs\n  states Open\n\n  command DoIt { data }\n' > /tmp/hygiene.keiro
   cabal run -v0 keiro-dsl:exe:keiro-dsl -- check /tmp/hygiene.keiro; echo "exit=$?"
   ```

   Expected: non-zero exit with an `IdentNotConstructorSafe` diagnostic at line 3
   (aggregate `thing`) and an `IdentHaskellKeyword` diagnostic at line 7 (field `data`).

8. Full matrix (final): the unit suite plus every conformance suite of the package (the
   committed conformance sources compile against the live keiki/keiro runtimes; this
   proves the parser/printer changes did not disturb the scaffolder's inputs):

   ```bash
   cabal test keiro-dsl 2>&1 | tail -20
   ```

   Expected: every suite reports PASS. (The conformance suites are listed in
   `keiro-dsl/keiro-dsl.cabal`; none of their sources are edited by this plan.)

9. Commit per milestone with conventional-commit messages, e.g.:

   ```text
   fix(keiro-dsl): escape string literals in parser and printer (round-trip integrity)
   ```


## Validation and Acceptance

Acceptance is behavioral, with exact commands and expected outputs:

1. `cabal run keiro-dsl:test:keiro-dsl-test` from the repo root AND
   `cabal run keiro-dsl-test` from `keiro-dsl/` both end `… examples, 0 failures` (C8).
2. The Concrete Steps smokes 4-7 behave exactly as transcribed: one escaped emit row
   (C1), `duplicate goto` at the second goto's line with non-zero exit (C3/C6), the
   out-of-range message with non-zero exit (C4), and the two hygiene diagnostics with
   their codes and line numbers (C5).
3. New unit coverage exists in `keiro-dsl/test/Main.hs` for every behavior this plan adds:
   escape decode/reject cases, `status-map partial` parse + validator suppression,
   duplicate wire/projection/goto errors and their positions, the missing-goto position,
   the `dispatch-id`-before-`schedule` error, the malformed-reg error, the seven-site
   overflow rejection with a `maxBound` boundary case, and one example per hygiene rule
   asserting code + line.
4. The round-trip property (`parse . pretty` describe block, test/Main.hs:24-27) now
   generates ALL ten node families with adversarial string/name generators and empty-list
   edges, and passes at ≥ 100 cases (C7). As a spot-check of adversarial reach, the exact
   AST from the Context repro (`emrValue = "a\" => Wat \"b"`) is pinned as a unit example
   asserting `parseSpec "<rt>" (renderSpec spec) == Right spec`.
5. `keiro-dsl new <kind> | keiro-dsl check /dev/stdin` exits 0 for all ten kinds (the
   existing skeleton test pins this; it proves the tightened notation still accepts every
   template in `keiro-dsl/src/Keiro/Dsl/Skeleton.hs`).
6. `cabal test keiro-dsl` — the unit suite plus all conformance suites — is fully green,
   proving no regression in the scaffolder's committed, compiling output.


## Idempotence and Recovery

Every step is an ordinary source edit plus a test run; all commands are safe to re-run.
Milestones are independently committable and were ordered so the suite is green after each
one (M1 first specifically so later milestones can be verified from any cwd). If a parser
change regresses a fixture or skeleton, the unit suite names the exact example; revert the
single milestone commit (`git revert <sha>`) — no milestone leaves generated artifacts or
state behind. The scratch specs written to `/tmp` are throwaway inputs. NOTATION.md edits
are additive sentences; if docs/plans/110-… lands first and restructures the file, re-apply
the same facts wherever the corresponding sections moved.


## Interfaces and Dependencies

No new library dependencies for `keiro-dsl:lib`. The `keiro-dsl-test` stanza in
`keiro-dsl/keiro-dsl.cabal` gains `directory >=1.3` and `filepath >=1.4` (both already in
the build plan via the executable stanza).

megaparsec surface used (all in `Text.Megaparsec`, already a dependency at `>=9.6`):
`getOffset`, `region`, `setErrorOffset`, `anySingle`, `anySingleBut`, `satisfy`, plus
`Text.Megaparsec.Char.Lexer.decimal` instantiated at `Integer` for the bound check.

Signatures that exist at the end (module `Keiro.Dsl.Parser`, internal):
`failAt :: Int -> String -> P a`; `boundedDecimal :: P Int`; `stringLit :: P Text`
(escape-aware, same type). Module `Keiro.Dsl.Validate` exports the enlarged
`DiagnosticCode` with `IdentHaskellKeyword`, `IdentNotConstructorSafe`,
`VertexCtorCollision`. Module `Keiro.Dsl.PrettyPrint`'s public surface (`renderSpec`) is
unchanged. `Keiro.Dsl.Grammar` is unchanged (the `FieldBinding` quote-wrapped-literal
convention and raw-text AST invariant are preserved deliberately — see the cross-plan
contract with docs/plans/106-… in Context). Test module `Main` (keiro-dsl-test) gains
`resolveTestPath :: FilePath -> IO FilePath` and the per-family generators
(`genProcess`, `genContract`, `genIntake`, `genEmit`, `genPublisher`, `genWorkqueue`,
`genPgmqDispatch`, `genWorkflow`, `genOperation`, `genAdversarialText`, `genWindow`).

Sibling-plan touchpoints (paths only, per MasterPlan 15): escaping contract and
`payloadExpr` — docs/plans/106-harden-the-keiro-dsl-scaffolder-template-injection-firewall-completeness-collision-and-stale-module-detection-and-faithful-policy-lowering.md;
duplicate-name rules and semantic numeric ranges — docs/plans/104-close-the-keiro-dsl-validator-soundness-holes-workflows-rules-cross-node-references-and-disposition-tables.md;
holistic NOTATION/skill refresh — docs/plans/110-align-keiro-dsl-with-the-safe-apis-and-refresh-the-authoring-skill-and-corpus.md.


## Revision Notes

- 2026-07-13: Expanded M6 to update `Skeleton.hs` after the implemented validator
  proved the aggregate starter's `Done` state and `ThingDone` event generated the same
  Haskell constructor. This preserves the original acceptance criterion that every
  built-in skeleton passes `check`.
- 2026-07-13: Expanded M7's parser work to reserve the omitted `process`/`dispatch`
  node keywords and distinguish transition emit clauses from top-level emit blocks,
  after the new all-family property produced minimal cross-node counterexamples.
