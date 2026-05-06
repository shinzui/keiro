-- | The contract record the spike's @runCommand@ consumes. This is
-- the M1 (spike) collapse of the M2 (production) shape: the bare
-- encode/decode pair stands in for EP-2's @Codec co@; the snapshot
-- machinery (state codec, snapshot policy) is omitted because EP-4
-- is downstream.
--
-- The shape derived in EP-1's M0 contract derivation is:
--
--   data Aggregate phi rs s ci co = Aggregate
--     { aggTransducer    :: SymTransducer phi rs s ci co
--     , aggEventCodec    :: Codec co                       -- EP-2
--     , aggStateCodec    :: StateCodec (s, RegFile rs)     -- EP-4
--     , aggEventTag      :: co -> Text
--     , aggSnapshotPolicy :: SnapshotPolicy (s, RegFile rs) -- EP-4
--     }
--
-- The spike's collapse keeps only the substrate slots that are
-- actually exercised by the load -> fold -> decide -> append cycle
-- under M1's acceptance criteria.
module Spike.Aggregate
  ( Aggregate (..)
  ) where

import Data.Aeson (Value)
import Data.Text (Text)
import Keiki.Core (SymTransducer)


-- | The keiro <-> keiki contract, M1 spike shape.
--
-- @phi@ — predicate carrier (the spike uses @HsPred CounterRegs
-- CounterCmd@). @rs@ — register-file slot list. @s@ — control vertex.
-- @ci@ — command alphabet. @co@ — event alphabet.
data Aggregate phi rs s ci co = Aggregate
  { aggTransducer :: SymTransducer phi rs s ci co
    -- ^ The pure native primitive. Carries 'initial', 'initialRegs',
    -- 'edgesOut', 'isFinal'. Consumed by 'step' (forward) and
    -- 'applyEvent'/'applyEvents' (replay).
  , aggEncode     :: co -> Value
    -- ^ Spike-only standalone encoder. EP-2 promotes this to a
    -- 'Codec co' that also carries schema-version evolution.
  , aggDecode     :: Value -> Either String co
    -- ^ Spike-only standalone decoder; the pair with 'aggEncode'.
  , aggEventTag   :: co -> Text
    -- ^ Stable per-event-constructor wire tag, written into kiroku's
    -- @event_type@ column. The read-side routes on it without
    -- decoding the JSON payload.
  }
