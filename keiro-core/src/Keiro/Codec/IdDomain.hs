-- | Published runtime contract for canonical prefix-bearing TypeID-v7 values.
module Keiro.Codec.IdDomain
  ( IdNormalization (..),
    IdDomainContract (..),
    IdDomainFailure (..),
    enforcedIdDomainVersion,
    typeIdV7Domain,
    idDomainAcceptsText,
    validateIdDomainText,
    parseKindIdV7Text,
    parseKindIdV7Value,
    idDomainTextPattern,
    idDomainSampleText,
  )
where

import Data.Aeson (Value, withText)
import Data.Aeson.Types (Parser)
import Data.KindID (KindID)
import Data.KindID qualified as KindID
import Data.KindID.Class (ValidPrefix)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Proxy (Proxy (..))
import Data.Text (Text)
import Data.Text qualified as T
import Data.TypeID qualified as TypeID
import GHC.TypeLits (symbolVal)
import Keiki.ProjectionDomain
  ( DomainConstructionError,
    TextPattern,
    textCharSet,
    textConcat,
    textLiteral,
    textRepeatBetween,
  )

data IdNormalization = CanonicalLowercase
  deriving stock (Eq, Ord, Show)

data IdDomainContract = IdDomainContract
  { idDomainVersion :: !Text,
    idDomainPrefix :: !Text,
    idDomainSeparator :: !Char,
    idDomainSuffixLength :: !Int,
    idDomainMaxLength :: !Int,
    idDomainNormalization :: !IdNormalization,
    idDomainJsonRepresentation :: !Text
  }
  deriving stock (Eq, Ord, Show)

data IdDomainFailure
  = IdDomainNonCanonical
  | IdDomainWrongPrefix !Text !Text
  | IdDomainMalformed !Text
  | IdDomainNotUuidV7 !Text
  deriving stock (Eq, Ord, Show)

enforcedIdDomainVersion :: Text
enforcedIdDomainVersion = "keiro-dsl/id-domain/typeid-v7/1"

typeIdV7Domain :: Text -> IdDomainContract
typeIdV7Domain prefix =
  IdDomainContract
    { idDomainVersion = enforcedIdDomainVersion,
      idDomainPrefix = prefix,
      idDomainSeparator = '_',
      idDomainSuffixLength = 26,
      idDomainMaxLength = if T.null prefix then 26 else T.length prefix + 27,
      idDomainNormalization = CanonicalLowercase,
      idDomainJsonRepresentation = "canonical-json-text"
    }

idDomainAcceptsText :: IdDomainContract -> Text -> Bool
idDomainAcceptsText contract = either (const False) (const True) . validateIdDomainText contract

-- | @mmzk-typeid@ intentionally separates canonical parsing from the UUID
-- version check, so both operations are part of this frozen contract.
validateIdDomainText :: IdDomainContract -> Text -> Either IdDomainFailure ()
validateIdDomainText contract input = do
  parsed <- case TypeID.parseText input of
    Right value -> Right value
    Left reason ->
      case TypeID.parseText (T.toLower input) of
        Right canonical
          | TypeID.toText canonical == T.toLower input -> Left IdDomainNonCanonical
        _ -> Left (IdDomainMalformed (T.pack (show reason)))
  let actualPrefix = TypeID.getPrefix parsed
  if actualPrefix == idDomainPrefix contract
    then pure ()
    else Left (IdDomainWrongPrefix (idDomainPrefix contract) actualPrefix)
  if TypeID.toText parsed == input
    then pure ()
    else Left IdDomainNonCanonical
  maybe (Right ()) (Left . IdDomainNotUuidV7 . T.pack . show) (TypeID.checkTypeID parsed)

-- | Parse a canonical TypeID-v7 whose prefix is reflected in the result type.
-- Keiro's frozen admission policy runs before the dependency constructs the
-- prefix-indexed value, so generated consumers cannot accidentally widen it.
parseKindIdV7Text :: forall prefix. (ValidPrefix prefix) => Text -> Either IdDomainFailure (KindID prefix)
parseKindIdV7Text input = do
  validateIdDomainText (typeIdV7Domain expectedPrefix) input
  either (Left . IdDomainMalformed . T.pack . show) Right (KindID.parseText @prefix input)
  where
    expectedPrefix = T.pack (symbolVal (Proxy @prefix))

-- | Aeson parser for generated integration-contract fields. When used with
-- @explicitParseField@, Aeson attaches the owning field key to these stable
-- Keiro admission failures.
parseKindIdV7Value :: forall prefix. (ValidPrefix prefix) => Value -> Parser (KindID prefix)
parseKindIdV7Value = withText "KindID" $ \input ->
  either (fail . T.unpack . renderIdDomainFailure) pure (parseKindIdV7Text @prefix input)

renderIdDomainFailure :: IdDomainFailure -> Text
renderIdDomainFailure failure = case failure of
  IdDomainNonCanonical -> "TypeID text is not canonical lowercase"
  IdDomainWrongPrefix expected actual ->
    "TypeID prefix mismatch: expected '" <> expected <> "', found '" <> actual <> "'"
  IdDomainMalformed reason -> "malformed TypeID text: " <> reason
  IdDomainNotUuidV7 reason -> "TypeID suffix is not UUIDv7: " <> reason

idDomainTextPattern :: IdDomainContract -> Either DomainConstructionError TextPattern
idDomainTextPattern contract = do
  prefix <-
    textLiteral
      ( if T.null (idDomainPrefix contract)
          then ""
          else idDomainPrefix contract <> T.singleton (idDomainSeparator contract)
      )
  leading <- textCharSet ('0' :| "1234567")
  crockford <- textCharSet ('0' :| "123456789abcdefghjkmnpqrstvwxyz")
  version <- textCharSet ('e' :| "f")
  variant <- textCharSet ('8' :| "9abrstv")
  beforeVersion <- textRepeatBetween 9 9 crockford
  beforeVariant <- textRepeatBetween 2 2 crockford
  afterVariant <- textRepeatBetween 12 12 crockford
  pure
    ( textConcat
        ( prefix
            :| [ leading,
                 beforeVersion,
                 version,
                 beforeVariant,
                 variant,
                 afterVariant
               ]
        )
    )

idDomainSampleText :: IdDomainContract -> Text
idDomainSampleText contract =
  (if T.null (idDomainPrefix contract) then "" else idDomainPrefix contract <> "_")
    <> "01h455vb4pex5vsknk084sn02q"
