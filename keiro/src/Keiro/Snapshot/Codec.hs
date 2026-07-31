-- | The default JSON encoding for aggregate snapshots.
--
-- 'defaultStateCodecWithFold' builds the recommended 'StateCodec' for a
-- hand-written service's @(state, registers)@ pair, serializing it as a JSON
-- object @{ "state": …, "registers": … }@ and composing a hand-owned
-- 'FoldVersion' into the snapshot discriminator. Change the fold version in the
-- same edit that changes the service's event-folding behavior.
--
-- 'defaultStateCodec' builds the underlying codec for the @(state, registers)@ pair
-- of a keiki machine, serializing it as a JSON object @{ "state": …,
-- "registers": … }@. The state half uses its 'ToJSON' \/ 'FromJSON'
-- instances; the register half uses keiki's register-file JSON encoding. The
-- codec derives separate hashes for the control-state shape and register-file
-- layout, so structural changes transparently invalidate older snapshots (see
-- "Keiro.Snapshot").
--
-- Generated services use 'withFoldFingerprint' directly with a fingerprint
-- derived from their spec. Hand-written guard and update function bodies are not
-- structurally inspectable, so hand-written services should use
-- 'defaultStateCodecWithFold' and maintain its explicit 'FoldVersion'.
module Keiro.Snapshot.Codec
  ( FoldVersion (..),
    defaultStateCodec,
    defaultStateCodecWithFold,
    withFoldFingerprint,
  )
where

import Data.Aeson (Result (..), object, withObject, (.:))
import Data.Aeson qualified as Aeson
import Data.Aeson.Types (parseEither)
import Data.Text qualified as Text
import Keiki.Codec.JSON (RegFileToJSON, regFileFromJSON, regFileToJSON)
import Keiki.Core (RegFile)
import Keiki.Shape (CanonicalStateShape, KnownRegFileShape, regFileShapeHash)
import Keiki.Shape qualified as Shape
import Keiro.EventStream (StateCodec (..))
import Keiro.Prelude

-- | A 'StateCodec' that serializes a @(state, registers)@ pair to a JSON
-- object, tagging it with the supplied codec version and hashes derived from the
-- control-state datatype and register-file layout.
--
-- This function does not identify changes to hand-written guards, register
-- updates, emitted outputs, targets, or helper functions used by the fold. Prefer
-- 'defaultStateCodecWithFold' for hand-written services. Generated services use
-- 'withFoldFingerprint' with a fingerprint derived from their spec.
defaultStateCodec ::
  forall rs s.
  (CanonicalStateShape s, FromJSON s, KnownRegFileShape rs, RegFileToJSON rs, ToJSON s) =>
  Int ->
  StateCodec (s, RegFile rs)
defaultStateCodec version =
  StateCodec
    { stateCodecVersion = version,
      shapeHash = regFileShapeHash (Proxy @rs),
      stateShapeHash = Shape.stateShapeHash (Proxy @s),
      encode = \(state, registers) ->
        object
          [ "state" Aeson..= state,
            "registers" Aeson..= regFileToJSON registers
          ],
      decode = decodeSnapshotValue
    }

-- | A hand-owned identity for a hand-written service's event fold.
--
-- The DSL derives a fold fingerprint from the spec automatically; a hand-written
-- service has no spec, so its fold identity must be owned by hand. Treat the
-- token as a change detector, not an encoding version: keep it stable while fold
-- semantics are stable, and change it in the same edit that changes any guard,
-- register update, emitted output, or target state, including logic in helper
-- functions the fold calls. A convention such as @"orders-fold-v3"@ keeps the
-- token greppable and reviewable. Forgetting to bump it recreates the silent
-- stale-snapshot hazard this type exists to prevent; see
-- 'defaultStateCodecWithFold'.
newtype FoldVersion = FoldVersion Text
  deriving stock (Eq, Show)

-- | The default snapshot codec for hand-written services: 'defaultStateCodec'
-- with a hand-owned 'FoldVersion' composed into the control-state discriminator
-- via 'withFoldFingerprint'.
--
-- Prefer this over bare 'defaultStateCodec' whenever the service's fold is
-- hand-written. A changed token changes the stored discriminator, so an old
-- snapshot is simply not found and hydration falls back to a full replay of the
-- event log: a performance cost, never wrong state. The rendered discriminator
-- stays operator-readable as @<state-shape-hash>;fold=<token>@.
defaultStateCodecWithFold ::
  forall rs s.
  (CanonicalStateShape s, FromJSON s, KnownRegFileShape rs, RegFileToJSON rs, ToJSON s) =>
  FoldVersion ->
  Int ->
  StateCodec (s, RegFile rs)
defaultStateCodecWithFold (FoldVersion token) version =
  withFoldFingerprint token (defaultStateCodec version)

-- | Compose a caller-supplied fold identity into the control-state
-- discriminator.
--
-- The fingerprint is a change detector, not an encoding version. Keep it stable
-- when fold semantics are stable and change it whenever guards, updates, targets,
-- or other event-folding behavior changes. The rendered form remains
-- operator-readable as @<state-shape-hash>;fold=<fingerprint>@.
withFoldFingerprint :: Text -> StateCodec state -> StateCodec state
withFoldFingerprint fingerprint codec =
  codec
    { stateShapeHash =
        codec ^. #stateShapeHash <> ";fold=" <> fingerprint
    }

decodeSnapshotValue ::
  forall rs s.
  (FromJSON s, RegFileToJSON rs) =>
  Value ->
  Either Text (s, RegFile rs)
decodeSnapshotValue value =
  case parseEither parser value of
    Left message -> Left (Text.pack message)
    Right pair -> Right pair
  where
    parser = withObject "Keiro snapshot" $ \objectValue -> do
      stateValue <- objectValue .: "state"
      registerValue <- objectValue .: "registers"
      state <- case Aeson.fromJSON stateValue of
        Error message -> fail ("state: " <> message)
        Success decoded -> pure decoded
      registers <- case regFileFromJSON @rs registerValue of
        Left message -> fail ("registers: " <> message)
        Right decoded -> pure decoded
      pure (state, registers)
