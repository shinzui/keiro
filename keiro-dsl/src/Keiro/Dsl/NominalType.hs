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

import Data.List.NonEmpty (NonEmpty (..))
import Data.List.NonEmpty qualified as NE
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import GHC.Generics (Generic)
import Keiro.Dsl.Grammar
import Keiro.Dsl.IdDomain (enforcedIdDomainVersion)
import Keiro.Dsl.LanguageVersion (RuntimeCapability (..), runtimeProfileHasCapability)
import Keiro.Dsl.SemanticContract (CheckedService, EffectiveLanguageContract (..), checkedLanguageContract, checkedSpec)
import Keiro.Dsl.TypeGraph

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

    resolveId declaration = case checkIdLeaf declaration of
      Left leafError -> (map leafIssueToNominalError (NE.toList ((.nominalLeafIssues) leafError)), Nothing)
      Right leaf -> ([], Just (resolvedFromLeaf leaf))

    resolveEnum declaration = case checkEnumLeaf declaration of
      Left leafError -> (map leafIssueToNominalError (NE.toList ((.nominalLeafIssues) leafError)), Nothing)
      Right leaf -> ([], Just (resolvedFromLeaf leaf))

    resolveScalar declaration = case checkScalarLeaf declaration of
      Left leafError -> (map leafIssueToNominalError (NE.toList ((.nominalLeafIssues) leafError)), Nothing)
      Right leaf -> ([], Just (resolvedFromLeaf leaf))

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

resolvedFromLeaf :: NominalLeaf -> ResolvedNominalType
resolvedFromLeaf leaf =
  ResolvedNominalType
    { name = (.name) leaf,
      representation = case (.kind) leaf of
        NominalIdLeaf prefix -> IdRepresentation prefix
        NominalEnumLeaf constructors -> EnumRepresentation constructors
        NominalScalarLeaf representation -> ScalarRepresentation representation,
      ownership = case (.ownership) leaf of
        GeneratedLeaf -> GeneratedNominal
        ConsumerLeaf binding -> ConsumerNominal binding,
      loc = (.loc) leaf
    }

leafIssueToNominalError :: NominalLeafIssue -> NominalTypeError
leafIssueToNominalError = \case
  LeafMissingIngredient name loc label -> NominalMissingIngredient name loc label
  LeafInvalidHaskellSource name loc label -> NominalInvalidHaskellSource name loc label
  LeafInvalidQualifiedValue name loc category value -> NominalInvalidQualifiedValue name loc category value
  LeafInvalidIdentity name loc category value -> NominalInvalidIdentity name loc category value
  LeafInvalidIdPrefix name loc prefix reason -> NominalInvalidIdPrefix name loc prefix reason
  LeafEmptyEnum name loc -> NominalEmptyEnum name loc
  LeafUnsupportedScalar name loc representation -> NominalUnsupportedScalar name loc representation

rejectErrors :: [e] -> [a] -> Either (NonEmpty e) [a]
rejectErrors errors values = maybe (Right values) Left (NE.nonEmpty errors)

rejectMany :: [e] -> Either (NonEmpty e) ()
rejectMany errors = maybe (Right ()) Left (NE.nonEmpty errors)

mappedName :: MappedDecl -> Name
mappedName MappedStructural {msName = name} = name
mappedName MappedRefined {mrName = name} = name
mappedName MappedOpaque {moName = name} = name

mappedLoc :: MappedDecl -> Loc
mappedLoc MappedStructural {msLoc = loc} = loc
mappedLoc MappedRefined {mrLoc = loc} = loc
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
