-- | Published runtime contracts for canonical prefix-bearing TypeID values.
module Keiro.Codec.IdDomain
  ( IdAdmission (..),
    IdNormalization (..),
    IdDomainContract (..),
    IdDomainFailure (..),
    enforcedIdDomainVersion,
    v5OrV7IdDomainVersion,
    typeIdV7Domain,
    typeIdV5OrV7Domain,
    idDomainAcceptsText,
    validateIdDomainText,
    parseKindIdText,
    parseKindIdValue,
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

-- | The closed UUID-version admission policy owned by a declaration. This
-- selects which already-canonical TypeID texts may enter a service; it does not
-- select an ID generator.
data IdAdmission
  = TypeIdV7
  | TypeIdV5OrV7
  deriving stock (Eq, Ord, Show)

data IdNormalization = CanonicalLowercase
  deriving stock (Eq, Ord, Show)

data IdDomainContract = IdDomainContract
  { idDomainAdmission :: !IdAdmission,
    idDomainVersion :: !Text,
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
  | IdDomainVersionNotAdmitted !Char
  | IdDomainVariantNotRfc4122 !Char
  deriving stock (Eq, Ord, Show)

enforcedIdDomainVersion :: Text
enforcedIdDomainVersion = "keiro-dsl/id-domain/typeid-v7/1"

v5OrV7IdDomainVersion :: Text
v5OrV7IdDomainVersion = "keiro-dsl/id-domain/typeid-v5-or-v7/1"

typeIdV7Domain :: Text -> IdDomainContract
typeIdV7Domain = idDomainContract TypeIdV7

typeIdV5OrV7Domain :: Text -> IdDomainContract
typeIdV5OrV7Domain = idDomainContract TypeIdV5OrV7

idDomainContract :: IdAdmission -> Text -> IdDomainContract
idDomainContract admission prefix =
  IdDomainContract
    { idDomainAdmission = admission,
      idDomainVersion = case admission of
        TypeIdV7 -> enforcedIdDomainVersion
        TypeIdV5OrV7 -> v5OrV7IdDomainVersion,
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
-- version check. Keiro owns the admitted version and RFC-4122 variant tables so
-- a dependency upgrade cannot silently widen a frozen contract.
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
  let suffix = T.takeEnd (idDomainSuffixLength contract) input
      versionCharacter = T.index suffix 10
      variantCharacter = T.index suffix 13
  if versionCharacter `elem` admittedVersionCharacters (idDomainAdmission contract)
    then pure ()
    else case idDomainAdmission contract of
      TypeIdV7 -> Left (IdDomainNotUuidV7 "Invalid UUID part!")
      TypeIdV5OrV7 -> Left (IdDomainVersionNotAdmitted versionCharacter)
  if variantCharacter `elem` rfc4122VariantCharacters
    then pure ()
    else case idDomainAdmission contract of
      TypeIdV7 -> Left (IdDomainNotUuidV7 "Invalid UUID part!")
      TypeIdV5OrV7 -> Left (IdDomainVariantNotRfc4122 variantCharacter)

-- | Parse a canonical ID under an explicit declaration-owned admission policy.
-- The result remains the established @KindID prefix@ carrier so existing
-- bindings and generators stay source-compatible.
parseKindIdText :: forall prefix. (ValidPrefix prefix) => IdDomainContract -> Text -> Either IdDomainFailure (KindID prefix)
parseKindIdText contract input = do
  let expectedPrefix = T.pack (symbolVal (Proxy @prefix))
  if idDomainPrefix contract == expectedPrefix
    then pure ()
    else Left (IdDomainWrongPrefix expectedPrefix (idDomainPrefix contract))
  validateIdDomainText contract input
  either (Left . IdDomainMalformed . T.pack . show) Right (KindID.parseText @prefix input)

-- | Aeson parser for a generated integration-contract field under an explicit
-- declaration-owned admission policy.
parseKindIdValue :: forall prefix. (ValidPrefix prefix) => IdDomainContract -> Value -> Parser (KindID prefix)
parseKindIdValue contract = withText "KindID" $ \input ->
  either (fail . T.unpack . renderIdDomainFailure) pure (parseKindIdText @prefix contract input)

-- | Parse a canonical TypeID-v7 whose prefix is reflected in the result type.
-- Keiro's frozen admission policy runs before the dependency constructs the
-- prefix-indexed value, so generated consumers cannot accidentally widen it.
parseKindIdV7Text :: forall prefix. (ValidPrefix prefix) => Text -> Either IdDomainFailure (KindID prefix)
parseKindIdV7Text = parseKindIdText @prefix (typeIdV7Domain expectedPrefix)
  where
    expectedPrefix = T.pack (symbolVal (Proxy @prefix))

-- | Aeson parser for generated integration-contract fields. When used with
-- @explicitParseField@, Aeson attaches the owning field key to these stable
-- Keiro admission failures.
parseKindIdV7Value :: forall prefix. (ValidPrefix prefix) => Value -> Parser (KindID prefix)
parseKindIdV7Value = parseKindIdValue @prefix (typeIdV7Domain expectedPrefix)
  where
    expectedPrefix = T.pack (symbolVal (Proxy @prefix))

renderIdDomainFailure :: IdDomainFailure -> Text
renderIdDomainFailure failure = case failure of
  IdDomainNonCanonical -> "TypeID text is not canonical lowercase"
  IdDomainWrongPrefix expected actual ->
    "TypeID prefix mismatch: expected '" <> expected <> "', found '" <> actual <> "'"
  IdDomainMalformed reason -> "malformed TypeID text: " <> reason
  IdDomainNotUuidV7 reason -> "TypeID suffix is not UUIDv7: " <> reason
  IdDomainVersionNotAdmitted character ->
    "TypeID suffix UUID version is not admitted (encoded version character '" <> T.singleton character <> "')"
  IdDomainVariantNotRfc4122 character ->
    "TypeID suffix does not use the RFC 4122 variant (encoded variant character '" <> T.singleton character <> "')"

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
  version <- textCharSet (admittedVersionCharacterSet (idDomainAdmission contract))
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

admittedVersionCharacters :: IdAdmission -> [Char]
admittedVersionCharacters = toList . admittedVersionCharacterSet
  where
    toList (first :| rest) = first : rest

admittedVersionCharacterSet :: IdAdmission -> NonEmpty Char
admittedVersionCharacterSet TypeIdV7 = 'e' :| "f"
admittedVersionCharacterSet TypeIdV5OrV7 = 'a' :| "bef"

rfc4122VariantCharacters :: [Char]
rfc4122VariantCharacters = "89abrstv"
