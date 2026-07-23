{- | The default JSON encoding for aggregate snapshots.

'defaultStateCodec' builds a 'StateCodec' for the @(state, registers)@ pair
of a keiki machine, serializing it as a JSON object @{ "state": …,
"registers": … }@. The state half uses its 'ToJSON' \/ 'FromJSON'
instances; the register half uses keiki's register-file JSON encoding. The
codec derives separate hashes for the control-state shape and register-file
layout, so structural changes transparently invalidate older snapshots (see
"Keiro.Snapshot").

Use 'withFoldFingerprint' to compose a stable fold identity into the
control-state discriminator. Pass your own version number and bump it when the
encoding or fold logic changes in a way neither structural hash nor that
fingerprint captures; notably, hand-written guard and update function bodies
are invisible to the default codec.
-}
module Keiro.Snapshot.Codec (
    defaultStateCodec,
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

{- | A 'StateCodec' that serializes a @(state, registers)@ pair to a JSON
object, tagging it with the supplied codec version and hashes derived from the
control-state datatype and register-file layout.
-}
defaultStateCodec ::
    forall rs s.
    (CanonicalStateShape s, FromJSON s, KnownRegFileShape rs, RegFileToJSON rs, ToJSON s) =>
    Int ->
    StateCodec (s, RegFile rs)
defaultStateCodec version =
    StateCodec
        { stateCodecVersion = version
        , shapeHash = regFileShapeHash (Proxy @rs)
        , stateShapeHash = Shape.stateShapeHash (Proxy @s)
        , encode = \(state, registers) ->
            object
                [ "state" Aeson..= state
                , "registers" Aeson..= regFileToJSON registers
                ]
        , decode = decodeSnapshotValue
        }

{- | Compose a caller-supplied fold identity into the control-state
discriminator.

The fingerprint is a change detector, not an encoding version. Keep it stable
when fold semantics are stable and change it whenever guards, updates, targets,
or other event-folding behavior changes. The rendered form remains
operator-readable as @<state-shape-hash>;fold=<fingerprint>@.
-}
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
