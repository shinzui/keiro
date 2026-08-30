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
    nominalEqualityContractForService,
    nominalEqualityIdentityForService,
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
import Keiro.Dsl.HaskellName (haskellKeywords)
import Keiro.Dsl.IdDomain (enforcedIdDomainVersion)
import Keiro.Dsl.LanguageVersion (RuntimeCapability (..), runtimeProfileHasCapability)
import Keiro.Dsl.SemanticContract (CheckedService, EffectiveLanguageContract (..), checkedLanguageContract, checkedSpec)
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
  { keyRepresentation :: !NominalEqualityKey,
    domain :: !NominalEqualityDomain,
    contractVersion :: !Text
  }
  deriving stock (Eq, Ord, Show, Generic)

data ConsumerNominalBinding = ConsumerNominalBinding
  { haskell :: !HaskellSource,
    binding :: !QualifiedValueName,
    bindingVersion :: !BindingVersion,
    canonical :: !CanonicalTypeId,
    fixtures :: !QualifiedValueName,
    initial :: !(Maybe QualifiedValueName)
  }
  deriving stock (Eq, Ord, Show, Generic)

data NominalOwnership
  = GeneratedNominal
  | ConsumerNominal !ConsumerNominalBinding
  deriving stock (Eq, Ord, Show, Generic)

data ResolvedNominalType = ResolvedNominalType
  { name :: !Name,
    representation :: !NominalRepresentation,
    ownership :: !NominalOwnership,
    loc :: !Loc
  }
  deriving stock (Eq, Show, Generic)

instance Ord ResolvedNominalType where
  compare left right =
    compare
      ((.name) left, (.representation) left, (.ownership) left)
      ((.name) right, (.representation) right, (.ownership) right)

newtype NominalTypeRegistry = NominalTypeRegistry (Map Name ResolvedNominalType)
  deriving stock (Eq, Show, Generic)

nominalTypes :: NominalTypeRegistry -> Map Name ResolvedNominalType
nominalTypes (NominalTypeRegistry values) = values

lookupNominalType :: Name -> NominalTypeRegistry -> Maybe ResolvedNominalType
lookupNominalType name = Map.lookup name . nominalTypes

nominalEqualityContractForService :: EffectiveLanguageContract -> ResolvedNominalType -> Maybe CheckedNominalEquality
nominalEqualityContractForService languageContract nominal = case (.representation) nominal of
  IdRepresentation prefix ->
    Just
      CheckedNominalEquality
        { keyRepresentation = NominalTextEqualityKey,
          domain =
            if enforcesNominalEqualityV2
              then EnforcedTypeIdV7TextDomain prefix enforcedIdDomainVersion
              else case (.ownership) nominal of
                GeneratedNominal -> LegacyUnrestrictedTextDomain
                ConsumerNominal {} -> TypeIdTextDomain prefix,
          contractVersion =
            if enforcesNominalEqualityV2
              then "keiro-dsl/nominal-equality/2"
              else nominalEqualityContractVersion
        }
  EnumRepresentation constructors ->
    Just
      CheckedNominalEquality
        { keyRepresentation = NominalTextEqualityKey,
          domain = FiniteTextDomain (snd <$> constructors),
          contractVersion = nominalEqualityContractVersion
        }
  ScalarRepresentation {} -> Nothing
  where
    enforcesNominalEqualityV2 =
      runtimeProfileHasCapability ((.runtimeProfile) languageContract) NominalEqualityV2

-- | Stable, checked identity used by generated projection tags, fingerprints,
-- scaffold history, and explain output. It includes the existing binding
-- authority rather than introducing a second consumer equality function.
nominalEqualityIdentityForService :: EffectiveLanguageContract -> ResolvedNominalType -> Maybe Text
nominalEqualityIdentityForService languageContract nominal = do
  equality <- nominalEqualityContractForService languageContract nominal
  pure . T.intercalate "|" $
    [ "nominal-equality",
      "name=" <> (.name) nominal,
      "contract=" <> (.contractVersion) equality,
      "key=" <> renderEqualityKey ((.keyRepresentation) equality),
      "domain=" <> renderEqualityDomain ((.domain) equality),
      renderOwnership ((.ownership) nominal)
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
          "canonical=" <> unCanonicalTypeId ((.canonical) binding),
          "binding=" <> unQualifiedValueName ((.binding) binding),
          "binding-version=" <> unBindingVersion ((.bindingVersion) binding)
        ]

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
  let registry = NominalTypeRegistry (Map.fromList [((.name) value, value) | value <- resolved])
  rejectMany (registerInitialErrors registry)
  pure registry
  where
    declarationResults =
      map resolveId ((.ids) spec)
        <> map resolveEnum ((.enums) spec)
        <> map resolveScalar ((.nominalScalars) spec)
    declarationErrors = concatMap fst declarationResults
    resolvedDeclarations = [value | (_, Just value) <- declarationResults]

    resolveId declaration =
      let name = (.name) declaration
          loc = (.loc) declaration
          prefixErrors =
            case (.binding) declaration >>= const (TypeID.checkPrefix ((.prefix) declaration)) of
              Nothing -> []
              Just err -> [NominalInvalidIdPrefix name loc ((.prefix) declaration) (T.pack (show err))]
          (bindingErrors, ownership) = resolveOwnership name loc ((.binding) declaration)
          errors = prefixErrors <> bindingErrors
          value = ResolvedNominalType name (IdRepresentation ((.prefix) declaration)) <$> ownership <*> pure loc
       in (errors, value <* guardNoErrors errors)

    resolveEnum declaration =
      let name = (.name) declaration
          loc = (.loc) declaration
          representation = NE.nonEmpty ((.ctors) declaration)
          representationErrors = [NominalEmptyEnum name loc | representation == Nothing]
          (bindingErrors, ownership) = resolveOwnership name loc ((.binding) declaration)
          errors = representationErrors <> bindingErrors
          value = ResolvedNominalType name <$> (EnumRepresentation <$> representation) <*> ownership <*> pure loc
       in (errors, value <* guardNoErrors errors)

    resolveScalar declaration =
      let name = (.name) declaration
          loc = (.loc) declaration
          representation = scalarRepresentation ((.representation) declaration)
          representationErrors = [NominalUnsupportedScalar name loc ((.representation) declaration) | representation == Nothing]
          (bindingErrors, ownership) = resolveRequiredOwnership name loc ((.binding) declaration)
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
      [((.name) value, "id", (.loc) value) | value <- (.ids) spec]
        <> [((.name) value, "enum", (.loc) value) | value <- (.enums) spec]
        <> [((.name) value, "nominal scalar", (.loc) value) | value <- (.nominalScalars) spec]
        <> [(mappedName value, "mapped", mappedLoc value) | value <- (.mapped) spec]
        <> [((.name) value, "rule", (.loc) value) | value <- (.rules) spec]
        <> [(name, kind <> " node", loc) | node <- (.nodes) spec, let (kind, name, loc) = nodeIdentityLocal node]

    registerInitialErrors registry =
      [ NominalMissingRegisterInitial typeName ((.loc) register) ((.name) register)
      | aggregate <- [value | NAggregate value <- (.nodes) spec],
        register <- (.regs) aggregate,
        TRef typeName <- [(.valueType) register],
        Just resolved <- [lookupNominalType typeName registry],
        ConsumerNominal binding <- [(.ownership) resolved],
        (.initial) binding == Nothing
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
      [ ("haskell", (.haskell) binding == Nothing),
        ("binding", (.binding) binding == Nothing),
        ("binding-version", (.bindingVersion) binding == Nothing),
        ("canonical-type", (.canonicalType) binding == Nothing),
        ("fixtures", (.fixtures) binding == Nothing)
      ]
    haskellErrors = maybe [] (validateHaskellSource name loc) ((.haskell) binding)
    (bindingErrors, checkedBindingName) = validateQualified name loc "binding" ((.binding) binding)
    (fixtureErrors, checkedFixtures) = validateQualified name loc "fixtures" ((.fixtures) binding)
    (initialErrors, checkedInitial) = validateOptionalQualified name loc "initial" ((.initial) binding)
    (bindingVersionErrors, checkedBindingVersion) = validateBindingVersion name loc ((.bindingVersion) binding)
    (canonicalErrors, checkedCanonical) = validateCanonical name loc ((.canonicalType) binding)
    errors = requiredErrors <> haskellErrors <> bindingErrors <> fixtureErrors <> initialErrors <> bindingVersionErrors <> canonicalErrors
    checkedBinding =
      ConsumerNominalBinding
        <$> (.haskell) binding
        <*> checkedBindingName
        <*> checkedBindingVersion
        <*> checkedCanonical
        <*> checkedFixtures
        <*> pure checkedInitial

validateHaskellSource :: Name -> Loc -> HaskellSource -> [NominalTypeError]
validateHaskellSource name loc source =
  [NominalInvalidHaskellSource name loc "package" | not (cabalPackageName ((.package) source))]
    <> [NominalInvalidHaskellSource name loc "module" | not (moduleNameSafe ((.moduleName) source))]
    <> [NominalInvalidHaskellSource name loc "type" | not (constructorSafe ((.valueType) source))]

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
  NAggregate value -> ("aggregate", (.name) value, (.loc) value)
  NProcess value -> ("process", (.id) value, (.loc) value)
  NRouter value -> ("router", (.id) value, (.loc) value)
  NContract value -> ("contract", (.name) value, (.loc) value)
  NIntake value -> ("intake", (.name) value, (.loc) value)
  NEmit value -> ("emit", (.name) value, (.loc) value)
  NPublisher value -> ("publisher", (.name) value, (.loc) value)
  NWorkqueue value -> ("workqueue", (.name) value, (.loc) value)
  NPgmqDispatch value -> ("dispatch", (.name) value, (.loc) value)
  NReadModel value -> ("readmodel", (.name) value, (.loc) value)
  NProjectionTarget value -> ("target", (.name) value, (.loc) value)
  NRebuildGroup value -> ("rebuild-group", (.name) value, (.loc) value)
  NProjectionRevision value -> ("projection-revision", (.name) value, (.loc) value)
  NExternalRead value -> ("external-read", externalReadNodeIdentity value, (.loc) value)
  NProjectionOwner value -> ("projection-owner", (.name) value, (.loc) value)
  NWorkflow value -> ("workflow", (.id) value, workflowNodeLoc value)
  NOperation value -> ("operation", (.name) value, (.loc) value)

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
