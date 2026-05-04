# Keiki Functional Core — Current State Survey

Survey author: research subagent (Explore), 2026-05-04. Source tree: `/Users/shinzui/Keikaku/bokuno/keiki`.

## Overview

`keiki` is a ~4,500-line pure Haskell library implementing event sourcing, workflow engines, and durable execution via a single formalism: the **symbolic-register finite-state transducer** (FST). Rather than separate systems, keiki unifies three problems into one mathematical object — the `SymTransducer` — from which it mechanically derives decision logic, replay, composition, and verification.

The library is pre-1.0. The core `SymTransducer` shape, the builder DSL, and composition combinators are stable and ship with end-to-end worked examples (User Registration, Email Delivery, Loan Application). Schema evolution and runtime-effects boundaries are being refined.

## Core Abstraction: the `SymTransducer`

File: `src/Keiki/Core.hs:470–475`.

    data SymTransducer phi rs s ci co = SymTransducer
      { edgesOut    :: s -> [Edge phi rs ci co s]
      , initial     :: s
      , initialRegs :: RegFile rs
      , isFinal     :: s -> Bool
      }

Type parameters:

- `phi` — predicate carrier (guards on edges). v1 is `HsPred rs ci` (Haskell functions); v2 supports SBV/z3 symbolic solving.
- `rs` — slot-list of the register file (typed heterogeneous tuple); each slot is a `(Symbol, Type)` pair.
- `s` — control vertex (finite state); typically a user-defined sum.
- `ci` — command/input alphabet (user sum type).
- `co` — event/output alphabet (user sum type).

There is **no `Decider` typeclass or `Aggregate` typeclass** in keiki. Instead, `Decider` is a **record facade** (`Keiki/Decider.hs:67–72`) that projects the transducer:

    data Decider c e s = Decider
      { decide       :: c -> s -> [e]
      , evolve       :: s -> e -> s
      , initialState :: s
      , isTerminal   :: s -> Bool
      }

## The Fold: `evolve`

File: `Keiki/Core.hs:657–692` (`applyEvent`, `reconstitute`).

    applyEvent
      :: BoolAlg phi (RegFile rs, ci)
      => SymTransducer phi rs s ci co
      -> s -> RegFile rs -> co -> Maybe (s, RegFile rs)

Semantics: given a current state `(s, RegFile rs)` and an observed event `co`, reverse-engineer the command via `solveOutput` (invert the edge's `OutTerm`), verify the guard holds with that recovered input, then apply the edge's `update`. Returns `Nothing` if any step fails (malformed log, event matches no active edge).

Properties:

- **Not total per edge** — `applyEvent` succeeds only if the event matches exactly one active outgoing edge's output and the guard holds when the recovered input is applied.
- **Initial state** — `(initial t, initialRegs t)`. Slots are pre-seeded with `error "uninit: <slot>"` thunks by `emptyRegFile` (`Keiki/Generics.hs`), so uninitialized reads fail loudly.
- **Non-applicable events** — silently dropped (`Nothing`) on replay. This is intentional for **ε-edges** (edges with `output = Nothing`), which advance state silently and are invisible on replay.
- **Pure** — no `IO`, no effects.

Full replay: `reconstitute :: SymTransducer phi rs s ci co -> [co] -> Maybe (s, RegFile rs)` folds `applyEvent` from `(initial t, initialRegs t)`.

## The Decide: `decide`

File: `Keiki/Core.hs:610–621` (`delta`, `omega`); `Keiki/Decider.hs:119–132` (façade).

    delta
      :: BoolAlg phi (RegFile rs, ci)
      => SymTransducer phi rs s ci co
      -> s -> RegFile rs -> ci -> Maybe (s, RegFile rs)

    omega
      :: BoolAlg phi (RegFile rs, ci)
      => SymTransducer phi rs s ci co
      -> s -> RegFile rs -> ci -> Maybe co

`delta` is the forward state transition (NFA-like). `omega` is the forward output (event emission).

Façade (`toDecider`):

    decide = \cmd (s, regs) -> case omega t s regs cmd of
      Just co -> [co]
      Nothing -> []

Error model:

- **No `Either` or `MonadError`** — a command produces zero or one event (`[]` rejected, `[e]` accepted). Guard failure → `Nothing` masked as `[]`.
- **Pure** — no effects. Decisions cannot read external state inside `decide`; runtime adapter must pre-fetch.
- **ε-edge limitation** — ε-transitions advance state silently inside the transducer but are invisible to `decide`. Callers needing them call `delta` directly.

## Composition

File: `Keiki/Composition.hs`.

Three combinators:

1. **`compose t1 t2`** — sequential composition. `t1 :: ci₁ → mid` and `t2 :: mid → co₂` produce a composite `ci₁ → co₂` by unifying alphabets at `mid` and weakening indices across the combined register file. Registers from `t1` and `t2` are kept disjoint (concatenated).
2. **`alternative t1 t2`** — disjoint-input dispatch. `t1 :: Either a b → co` and `t2 :: Either c d → co` produce a composite with input `Either (Either a b) (Either c d)` and distribute commands.
3. **`feedback1 t`** — single-step feedback loop. The output alphabet is lifted into the input alphabet; one step's output feeds the next step's input.

**Process managers / sagas**: keiki does *not* provide a first-class saga or compensation primitive. Composition is syntactic; coordination is left to the runtime (subscriptions, routing, timers).

## Effectful Story

File: `Keiki/Core.hs` (pure), `docs/research/effects-boundary.md` (design rationale).

The boundary is **type-level, not convention**:

- **Pure layer** (`Keiki.Core`, ~900 lines): `SymTransducer`, `delta`, `omega`, `step`, `reconstitute`, `applyEvent`, `solveOutput`. No `IO`, no `Eff`, no `MonadError`.
- **Runtime layer** (to be implemented in a future `Keiki.Runtime` or by the application): event-store I/O, queue dequeue/enqueue, timers, subscriptions, serialization, error handling, retries, idempotence, observability.

**Effectful reads in decide**: the pure `decide` cannot read external state. If a decision needs a database lookup, the runtime adapter must pre-fetch and embed the data in the command payload. This keeps the transducer deterministic and testable.

How a runtime ties to `Hasql.Session` and other effects:

    runCommand :: Command -> AggId -> Eff '[EventStoreE, QueueE] [Event]
    runCommand cmd aggId = do
      (s, regs) <- readFromStore aggId
      case step transducer (s, regs) cmd of
        Nothing -> pure []  -- rejected
        Just (s', regs', mev) -> do
          appendToStore aggId [ev | Just ev <- [mev]]
          forM_ [ev | Just ev <- [mev]] dispatchSubscriptions
          pure [ev | Just ev <- [mev]]

The pure `step` sits inside this orchestration; no effects leak back.

## Codecs & Serialization

File: `docs/research/schema-evolution.md`, `Keiki/Generics.hs`.

Status: schema-evolution-aware in design, but **serialization is not implemented in keiki itself**. The library works on typed Haskell values; JSON/CBOR/Protobuf codecs live in the runtime.

Generic-derived `InCtor`/`WireCtor`: `mkInCtor` (`Keiki/Generics.hs:132–149`) derives `InCtor` values from a record's `Generic` instance, avoiding hand-rolled RCons towers. `deriveWireCtors` (TH splice) generates `WireCtor` values for event constructors.

Upcasting: the recommended pattern (schema-evolution note, §1) is:

- Events arrive at the boundary as JSON.
- An application-supplied **upcaster** runs at the event-store boundary: `oldEvent -> currentEvent`.
- keiki's `solveOutput` and replay see only current-schema events.
- Hidden-input checks run against the *current* schema only.

Version model: keiki commits to a single static schema per deployment. Schema evolution is an *application* concern. Register-file shape changes invalidate existing snapshots (snapshot validation uses a register-file shape hash).

## Identity & IDs

**No dedicated identity abstraction in keiki.** User supplies aggregate ID, event ID, correlation ID — all are runtime concerns. No `typeid`, no `newtype` per aggregate.

## Testing

Files: `keiki/test/`, `jitsurei/test/`.

- **Given-When-Then helpers** — none provided; tests are hand-written `Hspec`.
- **Property tests** — none in v1 core. The symbolic v2 layer (`Keiki.Symbolic`) backs property-like checks with z3: `isSingleValuedSym`, `symIsBot`, `symSat`.
- **Replay scenarios** — hand-coded fixtures (`Keiki/Fixtures/UserRegistration.hs:32–54`) pin canonical command sequences and verify round-trips:

        canonicalCmds =
          [ StartRegistration (StartRegistrationData "alice@x" "Z9F4" (t 0))
          , Continue
          , ResendConfirmation (ResendConfirmationData "K2P7" (t 100))
          , ConfirmAccount (ConfirmAccountData "K2P7" (t 200))
          , FulfillGDPRRequest (FulfillGDPRRequestData (t 300))
          ]

- **Decider round-trip** (`Keiki/DeciderSpec.hs:56–73`): verifies `decide` then `evolve` over emitted events lands on expected state.
- **ε-edge limitation** (`Keiki/DeciderSpec.hs:85–103`): documents that `decide` on an ε-edge returns `[]` even though `delta` would transition the state.

## Existing Kiroku Integration

**None.** keiki is currently independent of kiroku. There is no concrete integration point, no `EventStore` adapter, no event-loading shim.

The effects-boundary note (`docs/research/effects-boundary.md:126–145`) describes the *shape* of how a runtime would integrate — a hypothetical `readStream :: EventStore -> OrderId -> IO [OrderOutput]` and `appendEvent :: EventStore -> OrderId -> OrderOutput -> IO ()` — but no such adapter exists.

Implication for keiro: keiro must implement this integration. Pattern is:

1. Fetch the event log for an aggregate from kiroku.
2. Call `reconstitute` to recover `(s, RegFile rs)`.
3. Call `step` with the incoming command.
4. Append any emitted event back to kiroku.

## Gaps for Keiro

### Top 5 most consequential gaps

1. **Command-handler pipeline (hydration → decide → append).** No built-in orchestration connecting the three steps. Keiro must wire these in the runtime monad (e.g., `Eff [Store, Error CommandError] [Event]`).
2. **Idempotency at the command-handler level.** Commands may be redelivered; handler must dedup (e.g., via `commandId`). `step` is pure and has no notion of redelivery or idempotency keys.
3. **Structured error model.** A command can be rejected (`[]`), but there is no way to distinguish "user error" (invalid state) from "system error" (decode failure). Keiro should expose `Either CommandError [Event]`.
4. **Effectful read in decide.** Pure `decide` cannot read external state. Keiro may want to permit `Eff` in decide under constraints (read-only, deterministic, memoizable).
5. **Process manager / saga / durable workflow primitive.** Keiki's composition is syntactic; it does not model long-running multi-aggregate workflows with compensation, timeouts, or child-aggregate spawning.

### Additional gaps

- No built-in subscription/routing engine.
- No snapshot machinery beyond conceptual shape `(s, RegFile rs)`.
- No versioning/upcasting machinery in code.
- No metrics/logging hooks (pure core is silent by design).
- No effect boundaries for read-side views (projections, CQRS read models). `Acceptor` (`Keiki/Acceptor.hs`) projects the transducer onto one alphabet but no SQL/Kafka adapter.
