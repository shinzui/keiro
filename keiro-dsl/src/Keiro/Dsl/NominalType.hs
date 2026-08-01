{-# OPTIONS_GHC -Werror=incomplete-patterns #-}

-- | Checked nominal declarations shared by validation, aggregate lowering,
-- generation, compatibility analysis, and scaffold records.
--
-- Parser declarations deliberately retain optional facts so diagnostics can be
-- located at their owner. This module is the phase boundary after which every
-- consumer binding is complete, every representation is closed, and every name
-- has one declaration category.
module Keiro.Dsl.NominalType
  ( NominalScalarRepresentation (..),
    NominalRepresentation (..),
    NominalEqualityKey (..),
    NominalEqualityDomain (..),
    CheckedNominalEquality (..),
    NominalOwnership (..),
    ConsumerNominalBinding (..),
    ResolvedNominalType (..),
    NominalTypeRegistry,
    nominalTypes,
    lookupNominalType,
    nominalEqualityContract,
    nominalEqualityContractForService,
    nominalEqualityIdentity,
    nominalEqualityIdentityForService,
    nominalEqualityIdentities,
    nominalEqualityIdentitiesForService,
    NominalTypeError (..),
    resolveNominalTypes,
  )
where

import Data.Char (isAscii, isDigit, isLower, isUpper, ord)
import Data.List.NonEmpty (NonEmpty (..))
import Data.List.NonEmpty qualified as NE
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.TypeID qualified as TypeID
import GHC.Generics (Generic)
import Keiro.Dsl.Grammar
import Keiro.Dsl.IdDomain (idDomainContractFor, idDomainVersion)
import Keiro.Dsl.LanguageVersion (SourceLanguage (..))
import Keiro.Dsl.SemanticContract (CheckedService (..), EffectiveLanguageContract, effectiveLanguageContract)
import Keiro.Dsl.TypeGraph

data NominalScalarRepresentation
  = NominalText
  | NominalInt
  | NominalNatural
  | NominalBool
  | NominalTime
  deriving stock (Eq, Ord, Show, Generic)

data NominalRepresentation
  = IdRepresentation !Text
  | EnumRepresentation !(NonEmpty (Name, Text))
  | ScalarRepresentation !NominalScalarRepresentation
  deriving stock (Eq, Ord, Show, Generic)

-- | The canonical carrier compared by generated nominal equality. IDs and
-- enums deliberately share their stable textual wire key while remaining
-- type-distinct in the checked expression tree.
data NominalEqualityKey
  = NominalTextEqualityKey
  deriving stock (Eq, Ord, Show, Generic)

-- | The exactness Keiro can honestly claim for a nominal equality projection.
-- Released generated IDs still wrap arbitrary 'Text', so their projection is
-- total but unconstrained until the enforcing language contract lands. A
-- consumer-bound ID is backed by a checked @KindID prefix@ representation and
-- therefore has the exact TypeID text image. Enums always have a finite image.
data NominalEqualityDomain
  = LegacyUnrestrictedTextDomain
  | TypeIdTextDomain !Text
  | EnforcedTypeIdV7TextDomain !Text !Text
  | FiniteTextDomain !(NonEmpty Text)
  deriving stock (Eq, Ord, Show, Generic)

data CheckedNominalEquality = CheckedNominalEquality
  { equalityKeyRepresentation :: !NominalEqualityKey,
    equalityDomain :: !NominalEqualityDomain,
    equalityContractVersion :: !Text
  }
  deriving stock (Eq, Ord, Show, Generic)

data ConsumerNominalBinding = ConsumerNominalBinding
  { consumerNominalHaskell :: !HaskellSource,
    consumerNominalBinding :: !QualifiedValueName,
    consumerNominalBindingVersion :: !BindingVersion,
    consumerNominalCanonical :: !CanonicalTypeId,
    consumerNominalFixtures :: !QualifiedValueName,
    consumerNominalInitial :: !(Maybe QualifiedValueName)
  }
  deriving stock (Eq, Ord, Show, Generic)

data NominalOwnership
  = GeneratedNominal
  | ConsumerNominal !ConsumerNominalBinding
  deriving stock (Eq, Ord, Show, Generic)

data ResolvedNominalType = ResolvedNominalType
  { resolvedNominalName :: !Name,
    resolvedNominalRepresentation :: !NominalRepresentation,
    resolvedNominalOwnership :: !NominalOwnership,
    resolvedNominalLoc :: !Loc
  }
  deriving stock (Eq, Show, Generic)

instance Ord ResolvedNominalType where
  compare left right =
    compare
      (resolvedNominalName left, resolvedNominalRepresentation left, resolvedNominalOwnership left)
      (resolvedNominalName right, resolvedNominalRepresentation right, resolvedNominalOwnership right)

newtype NominalTypeRegistry = NominalTypeRegistry
  { nominalTypes :: Map Name ResolvedNominalType
  }
  deriving stock (Eq, Show, Generic)

lookupNominalType :: Name -> NominalTypeRegistry -> Maybe ResolvedNominalType
lookupNominalType name = Map.lookup name . nominalTypes

-- | Resolve the declaration-scoped equality contract. Nominal scalar wrappers
-- keep their existing scalar projection behavior; this contract is the new
-- authority only for IDs and enums.
nominalEqualityContract :: ResolvedNominalType -> Maybe CheckedNominalEquality
nominalEqualityContract = nominalEqualityContractForService (effectiveLanguageContract LegacyUnversioned)

nominalEqualityContractForService :: EffectiveLanguageContract -> ResolvedNominalType -> Maybe CheckedNominalEquality
nominalEqualityContractForService languageContract nominal = case resolvedNominalRepresentation nominal of
  IdRepresentation prefix ->
    Just
      CheckedNominalEquality
        { equalityKeyRepresentation = NominalTextEqualityKey,
          equalityDomain = case idDomainContractFor languageContract prefix of
            Just contract -> EnforcedTypeIdV7TextDomain prefix (idDomainVersion contract)
            Nothing -> case resolvedNominalOwnership nominal of
              GeneratedNominal -> LegacyUnrestrictedTextDomain
              ConsumerNominal {} -> TypeIdTextDomain prefix,
          equalityContractVersion = case idDomainContractFor languageContract prefix of
            Just _ -> "keiro-dsl/nominal-equality/2"
            Nothing -> nominalEqualityContractVersion
        }
  EnumRepresentation constructors ->
    Just
      CheckedNominalEquality
        { equalityKeyRepresentation = NominalTextEqualityKey,
          equalityDomain = FiniteTextDomain (snd <$> constructors),
          equalityContractVersion = nominalEqualityContractVersion
        }
  ScalarRepresentation {} -> Nothing

-- | Stable, checked identity used by generated projection tags, fingerprints,
-- scaffold history, and explain output. It includes the existing binding
-- authority rather than introducing a second consumer equality function.
nominalEqualityIdentity :: ResolvedNominalType -> Maybe Text
nominalEqualityIdentity = nominalEqualityIdentityForService (effectiveLanguageContract LegacyUnversioned)

nominalEqualityIdentityForService :: EffectiveLanguageContract -> ResolvedNominalType -> Maybe Text
nominalEqualityIdentityForService languageContract nominal = do
  equality <- nominalEqualityContractForService languageContract nominal
  pure . T.intercalate "|" $
    [ "nominal-equality",
      "name=" <> resolvedNominalName nominal,
      "contract=" <> equalityContractVersion equality,
      "key=" <> renderEqualityKey (equalityKeyRepresentation equality),
      "domain=" <> renderEqualityDomain (equalityDomain equality),
      renderOwnership (resolvedNominalOwnership nominal)
    ]
  where
    renderEqualityKey NominalTextEqualityKey = "Text"
    renderEqualityDomain LegacyUnrestrictedTextDomain = "legacy-unrestricted-text"
    renderEqualityDomain (TypeIdTextDomain prefix) = "typeid-text:" <> prefix
    renderEqualityDomain (EnforcedTypeIdV7TextDomain prefix contractVersion) =
      "typeid-v7-text:" <> prefix <> ":" <> contractVersion
    renderEqualityDomain (FiniteTextDomain values) = "finite-text:" <> T.intercalate "," (NE.toList values)
    renderOwnership GeneratedNominal = "owner=generated"
    renderOwnership (ConsumerNominal binding) =
      T.intercalate
        ";"
        [ "owner=consumer",
          "canonical=" <> unCanonicalTypeId (consumerNominalCanonical binding),
          "binding=" <> unQualifiedValueName (consumerNominalBinding binding),
          "binding-version=" <> unBindingVersion (consumerNominalBindingVersion binding)
        ]

nominalEqualityIdentities :: Spec -> [Text]
nominalEqualityIdentities spec = nominalEqualityIdentitiesForService (CheckedService (effectiveLanguageContract LegacyUnversioned) spec)

nominalEqualityIdentitiesForService :: CheckedService -> [Text]
nominalEqualityIdentitiesForService service = case resolveNominalTypes spec of
  Left _ -> []
  Right registry ->
    [ identity
    | nominal <- Map.elems (nominalTypes registry),
      Just identity <- [nominalEqualityIdentityForService (checkedLanguageContract service) nominal]
    ]
  where
    spec = checkedSpec service

nominalEqualityContractVersion :: Text
nominalEqualityContractVersion = "keiro-dsl/nominal-equality/1"

data NominalTypeError
  = NominalMissingIngredient !Name !Loc !Text
  | NominalInvalidHaskellSource !Name !Loc !Text
  | NominalInvalidQualifiedValue !Name !Loc !Text !Text
  | NominalInvalidIdentity !Name !Loc !Text !Text
  | NominalInvalidIdPrefix !Name !Loc !Text !Text
  | NominalUnsupportedScalar !Name !Loc !Name
  | NominalEmptyEnum !Name !Loc
  | NominalMissingRegisterInitial !Name !Loc !Name
  | NominalDeclarationCollision !Name !Loc ![Text]
  deriving stock (Eq, Show, Generic)

resolveNominalTypes :: Spec -> Either (NonEmpty NominalTypeError) NominalTypeRegistry
resolveNominalTypes spec = do
  resolved <- rejectErrors declarationErrors resolvedDeclarations
  rejectMany collisionErrors
  let registry = NominalTypeRegistry (Map.fromList [(resolvedNominalName value, value) | value <- resolved])
  rejectMany (registerInitialErrors registry)
  pure registry
  where
    declarationResults =
      map resolveId (specIds spec)
        <> map resolveEnum (specEnums spec)
        <> map resolveScalar (specNominalScalars spec)
    declarationErrors = concatMap fst declarationResults
    resolvedDeclarations = [value | (_, Just value) <- declarationResults]

    resolveId declaration =
      let name = idName declaration
          loc = idLoc declaration
          prefixErrors =
            case idBinding declaration >>= const (TypeID.checkPrefix (idPrefix declaration)) of
              Nothing -> []
              Just err -> [NominalInvalidIdPrefix name loc (idPrefix declaration) (T.pack (show err))]
          (bindingErrors, ownership) = resolveOwnership name loc (idBinding declaration)
          errors = prefixErrors <> bindingErrors
          value = ResolvedNominalType name (IdRepresentation (idPrefix declaration)) <$> ownership <*> pure loc
       in (errors, value <* guardNoErrors errors)

    resolveEnum declaration =
      let name = enumName declaration
          loc = enumLoc declaration
          representation = NE.nonEmpty (enumCtors declaration)
          representationErrors = [NominalEmptyEnum name loc | representation == Nothing]
          (bindingErrors, ownership) = resolveOwnership name loc (enumBinding declaration)
          errors = representationErrors <> bindingErrors
          value = ResolvedNominalType name <$> (EnumRepresentation <$> representation) <*> ownership <*> pure loc
       in (errors, value <* guardNoErrors errors)

    resolveScalar declaration =
      let name = nominalScalarName declaration
          loc = nominalScalarLoc declaration
          representation = scalarRepresentation (nominalScalarRepresentation declaration)
          representationErrors = [NominalUnsupportedScalar name loc (nominalScalarRepresentation declaration) | representation == Nothing]
          (bindingErrors, ownership) = resolveRequiredOwnership name loc (nominalScalarBinding declaration)
          errors = representationErrors <> bindingErrors
          value = ResolvedNominalType name <$> (ScalarRepresentation <$> representation) <*> ownership <*> pure loc
       in (errors, value <* guardNoErrors errors)

    collisionErrors =
      [ NominalDeclarationCollision name loc categories
      | (name, occurrences) <- Map.toList originsByName,
        let categories = map fst occurrences,
        Set.size (Set.fromList categories) > 1,
        (_, loc) <- occurrences
      ]
    originsByName = Map.fromListWith (<>) [(name, [(category, loc)]) | (name, category, loc) <- origins]
    origins =
      [(idName value, "id", idLoc value) | value <- specIds spec]
        <> [(enumName value, "enum", enumLoc value) | value <- specEnums spec]
        <> [(nominalScalarName value, "nominal scalar", nominalScalarLoc value) | value <- specNominalScalars spec]
        <> [(mappedName value, "mapped", mappedLoc value) | value <- specMapped spec]
        <> [(ruleName value, "rule", ruleLoc value) | value <- specRules spec]
        <> [(name, kind <> " node", loc) | node <- specNodes spec, let (kind, name, loc) = nodeIdentityLocal node]

    registerInitialErrors registry =
      [ NominalMissingRegisterInitial typeName (regLoc register) (regName register)
      | aggregate <- [value | NAggregate value <- specNodes spec],
        register <- aggRegs aggregate,
        TRef typeName <- [regType register],
        Just resolved <- [lookupNominalType typeName registry],
        ConsumerNominal binding <- [resolvedNominalOwnership resolved],
        consumerNominalInitial binding == Nothing
      ]

resolveOwnership :: Name -> Loc -> Maybe NominalBindingDecl -> ([NominalTypeError], Maybe NominalOwnership)
resolveOwnership _ _ Nothing = ([], Just GeneratedNominal)
resolveOwnership name loc (Just binding) = resolveRequiredOwnership name loc binding

resolveRequiredOwnership :: Name -> Loc -> NominalBindingDecl -> ([NominalTypeError], Maybe NominalOwnership)
resolveRequiredOwnership name loc binding =
  (errors, ConsumerNominal <$> checkedBinding <* guardNoErrors errors)
  where
    requiredErrors =
      [NominalMissingIngredient name loc label | (label, missing) <- missingFacts, missing]
    missingFacts =
      [ ("haskell", nominalHaskell binding == Nothing),
        ("binding", nominalBinding binding == Nothing),
        ("binding-version", nominalBindingVersion binding == Nothing),
        ("canonical-type", nominalCanonicalType binding == Nothing),
        ("fixtures", nominalFixtures binding == Nothing)
      ]
    haskellErrors = maybe [] (validateHaskellSource name loc) (nominalHaskell binding)
    (bindingErrors, checkedBindingName) = validateQualified name loc "binding" (nominalBinding binding)
    (fixtureErrors, checkedFixtures) = validateQualified name loc "fixtures" (nominalFixtures binding)
    (initialErrors, checkedInitial) = validateOptionalQualified name loc "initial" (nominalInitial binding)
    (bindingVersionErrors, checkedBindingVersion) = validateBindingVersion name loc (nominalBindingVersion binding)
    (canonicalErrors, checkedCanonical) = validateCanonical name loc (nominalCanonicalType binding)
    errors = requiredErrors <> haskellErrors <> bindingErrors <> fixtureErrors <> initialErrors <> bindingVersionErrors <> canonicalErrors
    checkedBinding =
      ConsumerNominalBinding
        <$> nominalHaskell binding
        <*> checkedBindingName
        <*> checkedBindingVersion
        <*> checkedCanonical
        <*> checkedFixtures
        <*> pure checkedInitial

validateHaskellSource :: Name -> Loc -> HaskellSource -> [NominalTypeError]
validateHaskellSource name loc source =
  [NominalInvalidHaskellSource name loc "package" | not (cabalPackageName (hsPackage source))]
    <> [NominalInvalidHaskellSource name loc "module" | not (moduleNameSafe (hsModule source))]
    <> [NominalInvalidHaskellSource name loc "type" | not (constructorSafe (hsType source))]

validateQualified :: Name -> Loc -> Text -> Maybe Text -> ([NominalTypeError], Maybe QualifiedValueName)
validateQualified _ _ _ Nothing = ([], Nothing)
validateQualified name loc category (Just value) =
  case mkQualifiedValueName value of
    Right checked | qualifiedValueSafe value -> ([], Just checked)
    _ -> ([NominalInvalidQualifiedValue name loc category value], Nothing)

validateOptionalQualified :: Name -> Loc -> Text -> Maybe Text -> ([NominalTypeError], Maybe QualifiedValueName)
validateOptionalQualified = validateQualified

validateBindingVersion :: Name -> Loc -> Maybe Text -> ([NominalTypeError], Maybe BindingVersion)
validateBindingVersion _ _ Nothing = ([], Nothing)
validateBindingVersion name loc (Just value) =
  case mkBindingVersion value of
    Right checked | identitySafe value -> ([], Just checked)
    _ -> ([NominalInvalidIdentity name loc "binding-version" value], Nothing)

validateCanonical :: Name -> Loc -> Maybe Text -> ([NominalTypeError], Maybe CanonicalTypeId)
validateCanonical _ _ Nothing = ([], Nothing)
validateCanonical name loc (Just value) =
  case mkCanonicalTypeId value of
    Right checked | identitySafe value -> ([], Just checked)
    _ -> ([NominalInvalidIdentity name loc "canonical-type" value], Nothing)

scalarRepresentation :: Name -> Maybe NominalScalarRepresentation
scalarRepresentation = \case
  "Text" -> Just NominalText
  "Int" -> Just NominalInt
  "Natural" -> Just NominalNatural
  "Bool" -> Just NominalBool
  "Time" -> Just NominalTime
  "UTCTime" -> Just NominalTime
  _ -> Nothing

rejectErrors :: [e] -> [a] -> Either (NonEmpty e) [a]
rejectErrors errors values = maybe (Right values) Left (NE.nonEmpty errors)

rejectMany :: [e] -> Either (NonEmpty e) ()
rejectMany errors = maybe (Right ()) Left (NE.nonEmpty errors)

guardNoErrors :: [e] -> Maybe ()
guardNoErrors [] = Just ()
guardNoErrors _ = Nothing

mappedName :: MappedDecl -> Name
mappedName MappedStructural {msName = name} = name
mappedName MappedOpaque {moName = name} = name

mappedLoc :: MappedDecl -> Loc
mappedLoc MappedStructural {msLoc = loc} = loc
mappedLoc MappedOpaque {moLoc = loc} = loc

nodeIdentityLocal :: Node -> (Text, Name, Loc)
nodeIdentityLocal = \case
  NAggregate value -> ("aggregate", aggName value, aggLoc value)
  NProcess value -> ("process", procId value, procLoc value)
  NRouter value -> ("router", rtId value, rtLoc value)
  NContract value -> ("contract", ctrName value, ctrLoc value)
  NIntake value -> ("intake", inkName value, inkLoc value)
  NEmit value -> ("emit", emName value, emLoc value)
  NPublisher value -> ("publisher", pubName value, pubLoc value)
  NWorkqueue value -> ("workqueue", wqName value, wqLoc value)
  NPgmqDispatch value -> ("dispatch", pdName value, pdLoc value)
  NReadModel value -> ("readmodel", rmName value, rmLoc value)
  NWorkflow value -> ("workflow", wfId value, workflowNodeLoc value)
  NOperation value -> ("operation", opName value, opLoc value)

cabalPackageName :: Text -> Bool
cabalPackageName packageName = not (null components) && all validComponent components
  where
    components = T.splitOn "-" packageName
    validComponent component = not (T.null component) && T.all asciiAlphaNum component && T.any asciiLetter component

moduleNameSafe :: Text -> Bool
moduleNameSafe moduleName = not (null components) && all constructorSafe components
  where
    components = T.splitOn "." moduleName

qualifiedValueSafe :: Text -> Bool
qualifiedValueSafe qualified = case reverse (T.splitOn "." qualified) of
  value : reversedModule -> not (null reversedModule) && lowerIdentifierSafe value && all constructorSafe reversedModule
  [] -> False

constructorSafe :: Text -> Bool
constructorSafe name = case T.uncons name of
  Just (first, rest) -> asciiUpper first && T.all asciiAlphaNumOrUnderscore rest
  Nothing -> False

lowerIdentifierSafe :: Text -> Bool
lowerIdentifierSafe name = case T.uncons name of
  Just (first, rest) -> asciiLower first && T.all asciiAlphaNumOrUnderscore rest && name `Set.notMember` haskellKeywords
  Nothing -> False

identitySafe :: Text -> Bool
identitySafe value = not (T.null (T.strip value)) && not (T.any asciiControl value)

asciiUpper, asciiLower, asciiLetter, asciiAlphaNum, asciiAlphaNumOrUnderscore, asciiControl :: Char -> Bool
asciiUpper c = isAscii c && isUpper c
asciiLower c = isAscii c && isLower c
asciiLetter c = asciiUpper c || asciiLower c
asciiAlphaNum c = asciiLetter c || (isAscii c && isDigit c)
asciiAlphaNumOrUnderscore c = asciiAlphaNum c || c == '_'
asciiControl c = ord c < 32 || ord c == 127

haskellKeywords :: Set.Set Text
haskellKeywords =
  Set.fromList
    [ "case",
      "class",
      "data",
      "default",
      "deriving",
      "do",
      "else",
      "foreign",
      "if",
      "import",
      "in",
      "infix",
      "infixl",
      "infixr",
      "instance",
      "let",
      "module",
      "newtype",
      "of",
      "then",
      "type",
      "where",
      "mdo",
      "rec",
      "proc"
    ]
