{- | The default JSON encoding for aggregate snapshots.

'defaultStateCodec' builds a 'StateCodec' for the @(state, registers)@ pair
of a keiki machine, serializing it as a JSON object @{ "state": …,
"registers": … }@. The state half uses its 'ToJSON' \/ 'FromJSON'
instances; the register half uses keiki's register-file JSON encoding. The
codec's 'shapeHash' is derived from the register-file /shape/, so any change
to the register layout changes the hash and transparently invalidates older
snapshots (see "Keiro.Snapshot").

Pass your own version number to bump it explicitly when the state encoding
changes in a way the shape hash does not capture.
-}
module Keiro.Snapshot.Codec
  ( defaultStateCodec
  )
where

import Data.Aeson (Result (..), object, withObject, (.:))
import Data.Aeson qualified as Aeson
import Data.Aeson.Types (parseEither)
import Data.Text qualified as Text
import Keiki.Codec.JSON (RegFileToJSON, regFileFromJSON, regFileToJSON)
import Keiki.Core (RegFile)
import Keiki.Shape (KnownRegFileShape, regFileShapeHash)
import Keiro.EventStream (StateCodec (..))
import Keiro.Prelude

{- | A 'StateCodec' that serializes a @(state, registers)@ pair to a JSON
object, tagging it with the supplied codec version and a shape hash derived
from the register-file layout.
-}
defaultStateCodec ::
  forall rs s.
  (FromJSON s, KnownRegFileShape rs, RegFileToJSON rs, ToJSON s) =>
  Int ->
  StateCodec (s, RegFile rs)
defaultStateCodec version = StateCodec
  { stateCodecVersion = version
  , shapeHash = regFileShapeHash (Proxy @rs)
  , encode = \(state, registers) ->
      object
        [ "state" Aeson..= state
        , "registers" Aeson..= regFileToJSON registers
        ]
  , decode = decodeSnapshotValue
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
