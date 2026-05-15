{-# LANGUAGE BlockArguments #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE PolyKinds #-}
{-# LANGUAGE QualifiedDo #-}
{-# LANGUAGE TemplateHaskell #-}
-- The TH splice 'deriveAggregateCtors' generates per-constructor
-- payload-projection bindings (e.g. 'inpIncrement') that are never
-- referenced by the spike (the Builder DSL surfaces them via
-- 'PayloadProj' and 'OverloadedRecordDot' instead). They are
-- exported indirectly via the 'inCtorXxx' values, which are enough
-- for downstream code; suppressing the warning keeps the splice
-- output uncluttered.
{-# OPTIONS_GHC -Wno-unused-top-binds #-}

-- | The spike's sample aggregate. A two-vertex Counter that exercises
-- both event-sourcing transitions and a register-file-driven guard
-- (the workflow-flavoured M1.7 demonstration). Built on the keiki
-- 'SymTransducer' substrate via the 'Keiki.Builder' DSL.
--
-- Vertices: 'Idle' (the start state), 'Cooldown' (set after a
-- decrement, exited via a 'Tick' command whose timestamp passes the
-- @cooldownUntil@ slot).
--
-- Slots:
--
--   * @counter      :: Int@      — the running value.
--   * @cooldownUntil :: UTCTime@ — when 'Cooldown' may be exited.
--
-- Commands and events are isomorphic per pair so the structural
-- inverse 'solveOutput' works without hand-written inverses.
module Spike.Counter
  ( -- * Domain
    CounterCmd (..)
  , CounterEvent (..)
  , IncrementData (..)
  , DecrementData (..)
  , TickData (..)
  , IncrementedData (..)
  , DecrementedData (..)
  , CooldownEndedData (..)
    -- * Register file
  , CounterRegs
  , CounterVertex (..)
  , initialCounterRegs
    -- * Transducer
  , counter
    -- * Wire / Input constructors (re-exported for the codec)
  , wireIncremented
  , wireDecremented
  , wireCooldownEnded
  , inCtorIncrement
  , inCtorDecrement
  , inCtorTick
  , isIncrement
  , isDecrement
  , isTick
    -- * Helpers
  , cooldownDuration
  , eventTag
  ) where

import Data.Aeson (FromJSON, ToJSON)
import Data.Proxy (Proxy (..))
import Data.Text (Text)
import Data.Time
  ( NominalDiffTime
  , UTCTime (..)
  , addUTCTime
  , secondsToNominalDiffTime
  )
import GHC.Generics (Generic)
import Keiki.Builder ((.=))
import Keiki.Builder qualified as B
import Keiki.Core
import Keiki.Generics.TH (deriveAggregateCtors, deriveWireCtors)


-- * Command payloads -----------------------------------------------------

-- | Increment the counter by 1 in 'Idle'. @at@ is the runtime's
-- supplied wall-clock time; the spike threads it through to events
-- so replay sees a self-contained log.
newtype IncrementData = IncrementData { at :: UTCTime }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)


-- | Decrement the counter by 1 in 'Idle' and arm the cooldown.
newtype DecrementData = DecrementData { at :: UTCTime }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)


-- | Synthetic clock tick. In 'Cooldown', when @now >= cooldownUntil@
-- the aggregate emits 'CooldownEnded' and returns to 'Idle'. In any
-- other state, or in 'Cooldown' when the cooldown has not elapsed,
-- the command is rejected (no edge fires).
newtype TickData = TickData { now :: UTCTime }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)


data CounterCmd
  = Increment IncrementData
  | Decrement DecrementData
  | Tick      TickData
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)


-- * Event payloads ------------------------------------------------------

-- | Event payloads carry only direct projections of the input
-- command's fields. keiki's 'solveOutput' inverts the output by
-- structural matching: it only recognizes 'TInpCtorField' (direct
-- input-field reads), 'TLit' (constants), and 'TReg' (register
-- reads as no-ops in the inverse). Computed terms — 'TApp1',
-- 'TApp2' — defeat the inverse, so an event whose payload included
-- @newValue = counter + 1@ would crash 'applyEvent' on replay with
-- @Nothing@. The state delta on each event (@counter += 1@,
-- @cooldownUntil := at + cooldownDuration@) is carried by the
-- edge's @update@ alone, not duplicated into the event.
newtype IncrementedData = IncrementedData { at :: UTCTime }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)


newtype DecrementedData = DecrementedData { at :: UTCTime }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)


newtype CooldownEndedData = CooldownEndedData { at :: UTCTime }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)


data CounterEvent
  = Incremented   IncrementedData
  | Decremented   DecrementedData
  | CooldownEnded CooldownEndedData
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)


-- | Stable per-event-constructor wire tag. Used as kiroku's
-- @event_type@ column so the read-side can route on it without
-- decoding the JSON payload.
eventTag :: CounterEvent -> Text
eventTag = \case
  Incremented   {} -> "Incremented"
  Decremented   {} -> "Decremented"
  CooldownEnded {} -> "CooldownEnded"


-- * Register file & vertices --------------------------------------------

type CounterRegs =
  '[ '("counter",       Int)
   , '("cooldownUntil", UTCTime)
   ]


data CounterVertex = Idle | Cooldown
  deriving (Eq, Show, Enum, Bounded)


-- | Cooldown duration. Kept short so the contention test can wait it
-- out within the spike's runtime.
cooldownDuration :: NominalDiffTime
cooldownDuration = secondsToNominalDiffTime 0.05


-- | Unix epoch sentinel for 'cooldownUntil' before the first
-- 'Decrement' arms the slot.
epochUTC :: UTCTime
epochUTC = UTCTime (toEnum 0) 0


-- | Initial register file. We hand-build with 'RCons' because the
-- counter slot must start at 0 (an 'Increment' edge reads
-- @#counter@ before writing it). 'cooldownUntil' is sentinel-valued
-- because no edge reads it before a 'Decrement' has armed it; the
-- sentinel keeps the slot strict.
initialCounterRegs :: RegFile CounterRegs
initialCounterRegs =
  RCons (Proxy @"counter")       (0 :: Int)   $
  RCons (Proxy @"cooldownUntil") epochUTC     $
  RNil


-- * Per-constructor input projections + guards (TH-derived) ------------

$(deriveAggregateCtors ''CounterCmd ''CounterRegs
    [ ("Increment", "Increment")
    , ("Decrement", "Decrement")
    , ("Tick",      "Tick")
    ])


-- * Wire constructors for events (TH-derived) --------------------------

$(deriveWireCtors ''CounterEvent
    [ ("Incremented",   "Incremented")
    , ("Decremented",   "Decremented")
    , ("CooldownEnded", "CooldownEnded")
    ])


-- * The transducer ------------------------------------------------------

-- | The Counter aggregate's transducer.
counter
  :: SymTransducer (HsPred CounterRegs CounterCmd)
                   CounterRegs
                   CounterVertex
                   CounterCmd
                   CounterEvent
counter = B.buildTransducer Idle initialCounterRegs (const False) do

  B.from Idle do

    B.onCmd inCtorIncrement $ \d -> B.do
      B.slot @"counter" .= TApp1 (+ 1) #counter
      B.emit wireIncremented IncrementedTermFields { at = d.at }
      B.goto Idle

    B.onCmd inCtorDecrement $ \d -> B.do
      B.slot @"counter"       .= TApp1 (subtract 1) #counter
      B.slot @"cooldownUntil" .= TApp1 (addUTCTime cooldownDuration) d.at
      B.emit wireDecremented DecrementedTermFields { at = d.at }
      B.goto Cooldown

  B.from Cooldown do

    -- The register-file-driven guard: only fire when the supplied
    -- 'now' has reached or passed the slot. This is the workflow
    -- primitive (M1.7): a transition predicated on a slot value, not
    -- on the input alone. The transition still emits a synthetic
    -- 'CooldownEnded' event so replay sees an explicit edge to walk
    -- (per the M2 outline's preliminary recommendation against true
    -- ε-edges for replay determinism).
    B.onCmd inCtorTick $ \d -> B.do
      B.requireGuard
        (PEq (TApp2 cooldownExpired d.now #cooldownUntil) (TLit True))
      B.emit wireCooldownEnded CooldownEndedTermFields { at = d.now }
      B.goto Idle


-- | True iff @now@ has reached or passed @cooldownUntil@. Kept as a
-- top-level binding so it appears as a 'TApp2' node rather than a
-- nested closure; @keiki@'s pure layer only walks the 'Term' AST.
cooldownExpired :: UTCTime -> UTCTime -> Bool
cooldownExpired now until_ = now >= until_
