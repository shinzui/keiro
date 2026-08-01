-- | Published runtime contract for canonical prefix-bearing TypeID-v7 values.
module Keiro.Codec.IdDomain
  ( IdNormalization (..),
    IdDomainContract (..),
    IdDomainFailure (..),
    enforcedIdDomainVersion,
    typeIdV7Domain,
    idDomainAcceptsText,
    validateIdDomainText,
    idDomainTextPattern,
    idDomainSampleText,
  )
where

import Data.List.NonEmpty (NonEmpty (..))
import Data.Text (Text)
import Data.Text qualified as T
import Data.TypeID qualified as TypeID
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
  parsed <- either (Left . IdDomainMalformed . T.pack . show) Right (TypeID.parseText input)
  let actualPrefix = TypeID.getPrefix parsed
  if actualPrefix == idDomainPrefix contract
    then pure ()
    else Left (IdDomainWrongPrefix (idDomainPrefix contract) actualPrefix)
  if TypeID.toText parsed == input
    then pure ()
    else Left IdDomainNonCanonical
  maybe (Right ()) (Left . IdDomainNotUuidV7 . T.pack . show) (TypeID.checkTypeID parsed)

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
