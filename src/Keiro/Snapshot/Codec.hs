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

defaultStateCodec ::
  forall rs s.
  (FromJSON s, KnownRegFileShape rs, RegFileToJSON rs, ToJSON s) =>
  Int ->
  StateCodec (s, RegFile rs)
defaultStateCodec version = StateCodec
  { schemaVersion = version
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
