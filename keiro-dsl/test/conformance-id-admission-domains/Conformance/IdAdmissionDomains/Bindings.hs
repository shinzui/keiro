module Conformance.IdAdmissionDomains.Bindings where

import Conformance.IdAdmissionDomains.Domain
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Generated.IdAdmissionDomains.Nominals (LegacyId, parseLegacyId)
import Generated.IdAdmissionDomains.Structural.Shape.IdentityEnvelope qualified as Shape
import Keiro.Codec.Structural (FixtureCases (..), StructuralBinding (..))

uuidV5Text, uuidV7Text :: Text
uuidV5Text = "legacy_58kj0y515rbwebzaxwzzknjqnk"
uuidV7Text = "legacy_01h455vb4pex5vsknk084sn02q"

uuidV5, uuidV7 :: LegacyId
uuidV5 = committedId uuidV5Text
uuidV7 = committedId uuidV7Text

v5Envelope, mixedEnvelope :: IdentityEnvelope
v5Envelope = IdentityEnvelope uuidV5 Nothing (Map.singleton uuidV5 "historical-v5")
mixedEnvelope = IdentityEnvelope uuidV7 (Just uuidV5) (Map.fromList [(uuidV5, "historical-v5"), (uuidV7, "current-v7")])

identityEnvelopeBinding :: StructuralBinding IdentityEnvelope Shape.IdentityEnvelopeShape
identityEnvelopeBinding =
  StructuralBinding
    { bindingToShape = \(IdentityEnvelope legacyId previousId labelsById) -> Shape.IdentityEnvelope legacyId previousId labelsById,
      bindingFromShape = \(Shape.IdentityEnvelope legacyId previousId labelsById) -> IdentityEnvelope legacyId previousId labelsById
    }

identityEnvelopeFixtures :: FixtureCases IdentityEnvelope
identityEnvelopeFixtures = FixtureCases (("uuid-v5", v5Envelope) :| [("mixed-v5-v7", mixedEnvelope)])

committedId :: Text -> LegacyId
committedId value = case parseLegacyId value of
  Right parsed -> parsed
  Left reason -> error ("invalid committed LegacyId fixture: " <> show reason)
