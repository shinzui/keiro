{-# OPTIONS_GHC -Werror=incomplete-patterns #-}

-- | Checked, resolved consumer-owned mapped types. Parser declarations keep
-- mandatory facts optional so diagnostics can name omissions; this module is
-- the phase boundary after which missing facts and unresolved references are
-- unrepresentable.
module Keiro.Dsl.TypeGraph
  ( QualifiedValueName (..),
    unQualifiedValueName,
    CanonicalTypeId (..),
    unCanonicalTypeId,
    BindingVersion (..),
    unBindingVersion,
    CodecIdentity (..),
    unCodecIdentity,
    CodecVersion (..),
    unCodecVersion,
    mkQualifiedValueName,
    mkCanonicalTypeId,
    mkBindingVersion,
    mkCodecIdentity,
    mkCodecVersion,
    NominalScalarRepresentation (..),
    ConsumerNominalBinding (..),
    NominalLeafKind (..),
    NominalLeafOwnership (..),
    NominalLeaf (..),
    NominalLeafIssue (..),
    NominalLeafError (..),
    checkIdLeaf,
    checkEnumLeaf,
    checkScalarLeaf,
    MappedDeclError (..),
    CheckedMappedDecl (..),
    StructuralDecl (..),
    OpaqueDecl (..),
    checkMappedDecl,
    MappedKey (..),
    unMappedKey,
    ResolvedTypeExpr (..),
    ResolvedWireField (..),
    ResolvedWireArm (..),
    ResolvedMappedShape (..),
    ResolvedMappedDecl (..),
    TypeGraphError (..),
    DerivedMappedConsumer (..),
    UnsupportedProjectionSource (..),
    TypeGraph (..),
    RootRef (..),
    UseSite (..),
    NominalRootSite (..),
    PathSeg (..),
    UsePath (..),
    resolveTypeGraph,
    resolveTypeExpression,
    useSiteSegments,
    usePaths,
    nominalUsePaths,
    renderUsePath,
    TypeExprAlgebra (..),
    foldTypeExpr,
    MappedShapeAlgebra (..),
    foldMappedShape,
    MappedDeclAlgebra (..),
    foldMappedDecl,
    wireFingerprint,
    wireFingerprintForCalendarDayPolicy,
    nominalWireFingerprint,
  )
where

import Data.Bifunctor (first)
import Data.Bits (xor)
import Data.Char (isAscii, isDigit, isLower, isUpper, ord)
import Data.Either (partitionEithers)
import Data.Graph (SCC (..), stronglyConnComp)
import Data.List (sort, sortOn)
import Data.List.NonEmpty (NonEmpty (..))
import Data.List.NonEmpty qualified as NE
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.TypeID qualified as TypeID
import Data.Word (Word64)
import GHC.Generics (Generic)
import Keiro.Codec.CalendarDay (calendarDayCodecPolicyIdentity)
import Keiro.Dsl.Grammar
import Keiro.Dsl.HaskellName (haskellKeywords)
import Numeric (showHex)

newtype QualifiedValueName = QualifiedValueName {unQualifiedValueName :: Text}
  deriving stock (Eq, Ord, Show, Generic)

unQualifiedValueName :: QualifiedValueName -> Text
unQualifiedValueName (QualifiedValueName value) = value

newtype CanonicalTypeId = CanonicalTypeId {unCanonicalTypeId :: Text}
  deriving stock (Eq, Ord, Show, Generic)

unCanonicalTypeId :: CanonicalTypeId -> Text
unCanonicalTypeId (CanonicalTypeId value) = value

newtype BindingVersion = BindingVersion {unBindingVersion :: Text}
  deriving stock (Eq, Ord, Show, Generic)

unBindingVersion :: BindingVersion -> Text
unBindingVersion (BindingVersion value) = value

newtype CodecIdentity = CodecIdentity {unCodecIdentity :: Text}
  deriving stock (Eq, Ord, Show, Generic)

unCodecIdentity :: CodecIdentity -> Text
unCodecIdentity (CodecIdentity value) = value

newtype CodecVersion = CodecVersion {unCodecVersion :: Text}
  deriving stock (Eq, Ord, Show, Generic)

unCodecVersion :: CodecVersion -> Text
unCodecVersion (CodecVersion value) = value

data MappedDeclError
  = MissingHaskellSource !Name
  | MissingStructuralBinding !Name
  | MissingStructuralBindingVersion !Name
  | MissingCanonicalType !Name
  | MissingFixtureCases !Name
  | MissingOpaqueCodecIdentity !Name
  | MissingOpaqueCodecVersion !Name
  | EmptyQualifiedValueName !Text
  | EmptyCanonicalTypeId !Text
  | EmptyBindingVersion !Text
  | EmptyCodecIdentity !Text
  | EmptyCodecVersion !Text
  deriving stock (Eq, Show, Generic)

mkQualifiedValueName :: Text -> Either MappedDeclError QualifiedValueName
mkQualifiedValueName value
  | T.null (T.strip value) = Left (EmptyQualifiedValueName value)
  | otherwise = Right (QualifiedValueName value)

mkCanonicalTypeId :: Text -> Either MappedDeclError CanonicalTypeId
mkCanonicalTypeId value
  | T.null (T.strip value) = Left (EmptyCanonicalTypeId value)
  | otherwise = Right (CanonicalTypeId value)

mkBindingVersion :: Text -> Either MappedDeclError BindingVersion
mkBindingVersion value
  | T.null (T.strip value) = Left (EmptyBindingVersion value)
  | otherwise = Right (BindingVersion value)

mkCodecIdentity :: Text -> Either MappedDeclError CodecIdentity
mkCodecIdentity value
  | T.null (T.strip value) = Left (EmptyCodecIdentity value)
  | otherwise = Right (CodecIdentity value)

mkCodecVersion :: Text -> Either MappedDeclError CodecVersion
mkCodecVersion value
  | T.null (T.strip value) = Left (EmptyCodecVersion value)
  | otherwise = Right (CodecVersion value)

data NominalScalarRepresentation
  = NominalText
  | NominalInt
  | NominalNatural
  | NominalBool
  | NominalTime
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

data NominalLeafKind
  = NominalIdLeaf !Text
  | NominalEnumLeaf !(NonEmpty (Name, Text))
  | NominalScalarLeaf !NominalScalarRepresentation
  deriving stock (Eq, Ord, Show, Generic)

data NominalLeafOwnership
  = GeneratedLeaf
  | ConsumerLeaf !ConsumerNominalBinding
  deriving stock (Eq, Ord, Show, Generic)

data NominalLeaf = NominalLeaf
  { name :: !Name,
    kind :: !NominalLeafKind,
    ownership :: !NominalLeafOwnership,
    loc :: !Loc
  }
  deriving stock (Eq, Show, Generic)

data NominalLeafIssue
  = LeafMissingIngredient !Name !Loc !Text
  | LeafInvalidHaskellSource !Name !Loc !Text
  | LeafInvalidQualifiedValue !Name !Loc !Text !Text
  | LeafInvalidIdentity !Name !Loc !Text !Text
  | LeafInvalidIdPrefix !Name !Loc !Text !Text
  | LeafEmptyEnum !Name !Loc
  | LeafUnsupportedScalar !Name !Loc !Name
  deriving stock (Eq, Show, Generic)

newtype NominalLeafError = NominalLeafError {nominalLeafIssues :: NonEmpty NominalLeafIssue}
  deriving stock (Eq, Show, Generic)

checkIdLeaf :: IdDecl -> Either NominalLeafError NominalLeaf
checkIdLeaf declaration = do
  ownership <- checkLeafOwnership ((.name) declaration) ((.loc) declaration) ((.binding) declaration)
  case (.binding) declaration >>= const (TypeID.checkPrefix ((.prefix) declaration)) of
    Just err ->
      Left
        ( NominalLeafError
            (LeafInvalidIdPrefix ((.name) declaration) ((.loc) declaration) ((.prefix) declaration) (T.pack (show err)) :| [])
        )
    Nothing ->
      Right
        NominalLeaf
          { name = (.name) declaration,
            kind = NominalIdLeaf ((.prefix) declaration),
            ownership = ownership,
            loc = (.loc) declaration
          }

checkEnumLeaf :: EnumDecl -> Either NominalLeafError NominalLeaf
checkEnumLeaf declaration = do
  ownership <- checkLeafOwnership ((.name) declaration) ((.loc) declaration) ((.binding) declaration)
  constructors <- case NE.nonEmpty ((.ctors) declaration) of
    Nothing -> Left (NominalLeafError (LeafEmptyEnum ((.name) declaration) ((.loc) declaration) :| []))
    Just values -> Right values
  Right
    NominalLeaf
      { name = (.name) declaration,
        kind = NominalEnumLeaf constructors,
        ownership = ownership,
        loc = (.loc) declaration
      }

checkScalarLeaf :: NominalScalarDecl -> Either NominalLeafError NominalLeaf
checkScalarLeaf declaration = do
  ownership <- checkRequiredLeafOwnership ((.name) declaration) ((.loc) declaration) ((.binding) declaration)
  representation <- case scalarLeafRepresentation ((.representation) declaration) of
    Nothing -> Left (NominalLeafError (LeafUnsupportedScalar ((.name) declaration) ((.loc) declaration) ((.representation) declaration) :| []))
    Just value -> Right value
  Right
    NominalLeaf
      { name = (.name) declaration,
        kind = NominalScalarLeaf representation,
        ownership = ownership,
        loc = (.loc) declaration
      }

checkLeafOwnership :: Name -> Loc -> Maybe NominalBindingDecl -> Either NominalLeafError NominalLeafOwnership
checkLeafOwnership _ _ Nothing = Right GeneratedLeaf
checkLeafOwnership name loc (Just declaration) = checkRequiredLeafOwnership name loc declaration

checkRequiredLeafOwnership :: Name -> Loc -> NominalBindingDecl -> Either NominalLeafError NominalLeafOwnership
checkRequiredLeafOwnership name loc declaration =
  case NE.nonEmpty issues of
    Just errors -> Left (NominalLeafError errors)
    Nothing -> case checkedBinding of
      Just value -> Right (ConsumerLeaf value)
      Nothing -> error "keiro-dsl internal invariant: a nominal leaf binding without issues is complete"
  where
    issues =
      [LeafMissingIngredient name loc label | (label, missing) <- missingFacts, missing]
        <> maybe [] (validateLeafHaskellSource name loc) ((.haskell) declaration)
        <> qualifiedIssues "binding" ((.binding) declaration)
        <> qualifiedIssues "fixtures" ((.fixtures) declaration)
        <> qualifiedIssues "initial" ((.initial) declaration)
        <> identityIssues "binding-version" ((.bindingVersion) declaration)
        <> canonicalIssues ((.canonicalType) declaration)
    missingFacts =
      [ ("haskell", (.haskell) declaration == Nothing),
        ("binding", (.binding) declaration == Nothing),
        ("binding-version", (.bindingVersion) declaration == Nothing),
        ("canonical-type", (.canonicalType) declaration == Nothing),
        ("fixtures", (.fixtures) declaration == Nothing)
      ]
    qualifiedIssues category value = case value of
      Just symbol | not (qualifiedValueSafe symbol) -> [LeafInvalidQualifiedValue name loc category symbol]
      _ -> []
    identityIssues category value = case value of
      Just identity | not (identitySafe identity) -> [LeafInvalidIdentity name loc category identity]
      _ -> []
    canonicalIssues value = case value of
      Just identity | not (identitySafe identity) -> [LeafInvalidIdentity name loc "canonical-type" identity]
      _ -> []
    checkedBinding =
      ConsumerNominalBinding
        <$> (.haskell) declaration
        <*> ((.binding) declaration >>= either (const Nothing) Just . mkQualifiedValueName)
        <*> ((.bindingVersion) declaration >>= either (const Nothing) Just . mkBindingVersion)
        <*> ((.canonicalType) declaration >>= either (const Nothing) Just . mkCanonicalTypeId)
        <*> ((.fixtures) declaration >>= either (const Nothing) Just . mkQualifiedValueName)
        <*> pure ((.initial) declaration >>= either (const Nothing) Just . mkQualifiedValueName)

validateLeafHaskellSource :: Name -> Loc -> HaskellSource -> [NominalLeafIssue]
validateLeafHaskellSource name loc source =
  [LeafInvalidHaskellSource name loc "package" | not (cabalPackageName ((.package) source))]
    <> [LeafInvalidHaskellSource name loc "module" | not (moduleNameSafe ((.moduleName) source))]
    <> [LeafInvalidHaskellSource name loc "type" | not (constructorSafe ((.valueType) source))]

scalarLeafRepresentation :: Name -> Maybe NominalScalarRepresentation
scalarLeafRepresentation = \case
  "Text" -> Just NominalText
  "Int" -> Just NominalInt
  "Natural" -> Just NominalNatural
  "Bool" -> Just NominalBool
  "Time" -> Just NominalTime
  "UTCTime" -> Just NominalTime
  _ -> Nothing

data StructuralDecl = StructuralDecl
  { name :: !Name,
    haskell :: !HaskellSource,
    binding :: !QualifiedValueName,
    bindingVersion :: !BindingVersion,
    canonical :: !CanonicalTypeId,
    fixtures :: !QualifiedValueName,
    initial :: !(Maybe QualifiedValueName),
    loc :: !Loc
  }
  deriving stock (Eq, Show, Generic)

data OpaqueDecl = OpaqueDecl
  { name :: !Name,
    haskell :: !HaskellSource,
    codecIdentity :: !CodecIdentity,
    codecVersion :: !CodecVersion,
    fixtures :: !QualifiedValueName,
    initial :: !(Maybe QualifiedValueName),
    loc :: !Loc
  }
  deriving stock (Eq, Show, Generic)

data CheckedMappedDecl
  = CheckedStructural !StructuralDecl !MappedShape
  | CheckedOpaque !OpaqueDecl
  deriving stock (Eq, Show, Generic)

checkMappedDecl :: MappedDecl -> Either (NonEmpty MappedDeclError) CheckedMappedDecl
checkMappedDecl MappedStructural {msName = name, msHaskell = haskell, msBinding = binding, msBindingVersion = bindingVersion, msCanonical = canonical, msFixtures = fixtures, msInitial = initial, msShape = shape, msLoc = loc} = do
  checkedHaskell <- require (MissingHaskellSource name) haskell
  checkedBinding <- require (MissingStructuralBinding name) binding >>= liftOne . mkQualifiedValueName
  checkedBindingVersion <- require (MissingStructuralBindingVersion name) bindingVersion >>= liftOne . mkBindingVersion
  checkedCanonical <- require (MissingCanonicalType name) canonical >>= liftOne . mkCanonicalTypeId
  checkedFixtures <- require (MissingFixtureCases name) fixtures >>= liftOne . mkQualifiedValueName
  checkedInitial <- traverse (liftOne . mkQualifiedValueName) initial
  pure
    ( CheckedStructural
        StructuralDecl
          { name = name,
            haskell = checkedHaskell,
            binding = checkedBinding,
            bindingVersion = checkedBindingVersion,
            canonical = checkedCanonical,
            fixtures = checkedFixtures,
            initial = checkedInitial,
            loc = loc
          }
        shape
    )
checkMappedDecl MappedOpaque {moName = name, moHaskell = haskell, moCodecId = codecIdentity, moCodecVersion = codecVersion, moFixtures = fixtures, moInitial = initial, moLoc = loc} = do
  checkedHaskell <- require (MissingHaskellSource name) haskell
  checkedCodecIdentity <- require (MissingOpaqueCodecIdentity name) codecIdentity >>= liftOne . mkCodecIdentity
  checkedCodecVersion <- require (MissingOpaqueCodecVersion name) codecVersion >>= liftOne . mkCodecVersion
  checkedFixtures <- require (MissingFixtureCases name) fixtures >>= liftOne . mkQualifiedValueName
  checkedInitial <- traverse (liftOne . mkQualifiedValueName) initial
  pure
    ( CheckedOpaque
        OpaqueDecl
          { name = name,
            haskell = checkedHaskell,
            codecIdentity = checkedCodecIdentity,
            codecVersion = checkedCodecVersion,
            fixtures = checkedFixtures,
            initial = checkedInitial,
            loc = loc
          }
    )

require :: e -> Maybe a -> Either (NonEmpty e) a
require err = maybe (Left (err :| [])) Right

liftOne :: Either e a -> Either (NonEmpty e) a
liftOne = first (:| [])

newtype MappedKey = MappedKey {unMappedKey :: Name}
  deriving stock (Eq, Ord, Show, Generic)

unMappedKey :: MappedKey -> Name
unMappedKey (MappedKey value) = value

data ResolvedTypeExpr
  = RText
  | RInt
  | RInteger
  | RBool
  | RNatural
  | RTime
  | RDay
  | RJson
  | ROptional !ResolvedTypeExpr
  | RList !ResolvedTypeExpr
  | RMap !ResolvedTypeExpr
  | RKeyedMap !NominalLeaf !ResolvedTypeExpr
  | RRef !MappedKey
  | RNominal !NominalLeaf
  deriving stock (Eq, Show, Generic)

data ResolvedWireField = ResolvedWireField
  { haskell :: !Name,
    key :: !Text,
    valueType :: !ResolvedTypeExpr,
    presence :: !Presence,
    onMissing :: !(Maybe OnMissing),
    loc :: !Loc
  }
  deriving stock (Eq, Show, Generic)

data ResolvedWireArm = ResolvedWireArm
  { ctor :: !Name,
    tag :: !Text,
    payload :: !(Maybe ResolvedTypeExpr),
    loc :: !Loc
  }
  deriving stock (Eq, Show, Generic)

data ResolvedMappedShape
  = RRecord !Name !UnknownFields ![ResolvedWireField]
  | REnum ![WireEnum]
  | RUnion !UnionEncoding ![ResolvedWireArm]
  | RBare !ResolvedTypeExpr
  deriving stock (Eq, Show, Generic)

data ResolvedMappedDecl
  = ResolvedStructural !StructuralDecl !ResolvedMappedShape
  | ResolvedOpaque !OpaqueDecl
  deriving stock (Eq, Show, Generic)

data TypeGraphError
  = TGDeclError !Name !MappedDeclError
  | TGAmbiguousName !Name ![Text]
  | TGUnresolvedRef !Name !Name !Loc
  | TGUnresolvedConsumerRef !Text !Name !Loc
  | TGUnsupportedNominalLeaf !Name !Name !Text !Loc
  | TGRecursive ![Name]
  deriving stock (Eq, Show, Generic)

data RootRef
  = RootCommandField !Name !Name !Name
  | RootEventField !Name !Name !Name
  | RootRegister !Name !Name
  | RootWorkqueueField !Name !Name
  | RootReadModelQueryInput !Name
  | RootReadModelQueryResult !Name
  | RootContractField !Name !Name !Name
  deriving stock (Eq, Ord, Show, Generic)

data UseSite = UseSite
  { root :: !RootRef,
    mappedKey :: !MappedKey
  }
  deriving stock (Eq, Ord, Show, Generic)

data NominalRootSite = NominalRootSite
  { root :: !RootRef,
    nominal :: !Name,
    segments :: ![PathSeg]
  }
  deriving stock (Eq, Ord, Show, Generic)

data PathSeg
  = SegField !Name !Text
  | SegArm !Name !Text
  | SegElem
  | SegMapKey
  | SegMapValue
  | SegOptional
  | SegDecl !Name
  | SegNominal !Name
  deriving stock (Eq, Ord, Show, Generic)

data UsePath = UsePath
  { root :: !RootRef,
    segments :: ![PathSeg]
  }
  deriving stock (Eq, Ord, Show, Generic)

-- | A projection consumer whose mapped dependencies are inherited from one
-- authoritative aggregate event union rather than spelled a second time.
data DerivedMappedConsumer
  = AggregateInlineProjectionConsumer !Name !Name
  | CatalogProjectionConsumer !Name !Name
  deriving stock (Eq, Ord, Show, Generic)

-- | A catalog boundary that deliberately has no single generated event type.
-- Keeping it in the checked graph makes the unsupported boundary visible
-- without fabricating a mapped declaration consumer.
data UnsupportedProjectionSource
  = UnsupportedCatalogCategory !Name !Text
  | UnsupportedCatalogAll !Name
  deriving stock (Eq, Ord, Show, Generic)

data TypeGraph = TypeGraph
  { declarations :: !(Map MappedKey ResolvedMappedDecl),
    reachability :: !(Map MappedKey (Set MappedKey)),
    nominalLeaves :: !(Map Name NominalLeaf),
    unsupportedNominalLeafKinds :: !(Map Name Text),
    nominalReachability :: !(Map MappedKey (Set Name)),
    useSites :: ![UseSite],
    nominalRootSites :: ![NominalRootSite],
    rootSegments :: !(Map UseSite [PathSeg]),
    derivedMappedConsumers :: ![DerivedMappedConsumer],
    replayableProjectionGroups :: !(Map DerivedMappedConsumer Name),
    projectionOperationalIdentities :: !(Map DerivedMappedConsumer Text),
    unsupportedProjectionSources :: ![UnsupportedProjectionSource]
  }
  deriving stock (Eq, Show, Generic)

resolveTypeGraph :: Spec -> Either (NonEmpty TypeGraphError) TypeGraph
resolveTypeGraph spec = do
  checked <- collectChecked ((.mapped) spec)
  rejectMany (ambiguityErrors spec checked)
  let keyByName = Map.fromList [(checkedName decl, MappedKey (checkedName decl)) | decl <- checked]
      nominalLeaves = collectNominalLeaves spec
      enumNames = Set.empty
      (resolveErrors, resolvedPairs) = partitionEithers (map (resolveCheckedDecl keyByName nominalLeaves enumNames) checked)
  rejectMany resolveErrors
  let declarations = Map.fromList resolvedPairs
  rejectMany (cycleErrors declarations)
  let reachability = Map.mapWithKey (reachableFrom declarations) declarations
      nominalReachability = Map.mapWithKey (nominalsReachableFrom declarations) declarations
      (rootErrors, rootSites) = partitionEithers (collectUseSites keyByName nominalLeaves enumNames spec)
  rejectMany rootErrors
  let mappedRootSites = [(site, segments) | CollectedMapped site segments <- rootSites]
      nominalRootSites = [site | CollectedNominal site <- rootSites]
  pure
    TypeGraph
      { declarations = declarations,
        reachability = reachability,
        nominalLeaves = nominalLeaves,
        unsupportedNominalLeafKinds = Map.empty,
        nominalReachability = nominalReachability,
        useSites = map fst mappedRootSites,
        nominalRootSites = nominalRootSites,
        rootSegments = Map.fromList mappedRootSites,
        derivedMappedConsumers = sort (derivedMappedConsumers spec),
        replayableProjectionGroups = replayableProjectionGroups spec,
        projectionOperationalIdentities = projectionOperationalIdentities spec,
        unsupportedProjectionSources = sort (unsupportedProjectionSources spec)
      }

collectNominalLeaves :: Spec -> Map Name NominalLeaf
collectNominalLeaves spec =
  Map.fromList
    [ ((.name) leaf, leaf)
    | result <- map checkIdLeaf ((.ids) spec) <> map checkEnumLeaf ((.enums) spec) <> map checkScalarLeaf ((.nominalScalars) spec),
      Right leaf <- [result]
    ]

derivedMappedConsumers :: Spec -> [DerivedMappedConsumer]
derivedMappedConsumers spec =
  [ AggregateInlineProjectionConsumer ((.name) aggregate) ((.table) projection)
  | NAggregate aggregate <- (.nodes) spec,
    Just projection <- [(.projection) aggregate]
  ]
    <> [ CatalogProjectionConsumer ((.name) owner) aggregate
       | NProjectionOwner owner <- (.nodes) spec,
         CatalogAggregate aggregate <- (.sources) owner
       ]

replayableProjectionGroups :: Spec -> Map DerivedMappedConsumer Name
replayableProjectionGroups spec =
  Map.fromList
    [ (CatalogProjectionConsumer ((.name) owner) aggregate, (.group) owner)
    | NProjectionOwner owner <- (.nodes) spec,
      (.replay) owner == ProjectionReplayExplicit,
      CatalogAggregate aggregate <- (.sources) owner
    ]

projectionOperationalIdentities :: Spec -> Map DerivedMappedConsumer Text
projectionOperationalIdentities spec =
  Map.fromList (inlineRows <> catalogRows)
  where
    readModels = [readModel | NReadModel readModel <- (.nodes) spec]
    inlineRows =
      [ ( AggregateInlineProjectionConsumer ((.name) aggregate) ((.table) projection),
          renderOperation Nothing [(.table) projection] [(.name) readModel | readModel <- readModels, (.name) readModel == (.table) projection] False
        )
      | NAggregate aggregate <- (.nodes) spec,
        Just projection <- [(.projection) aggregate]
      ]
    catalogRows =
      [ ( CatalogProjectionConsumer ((.name) owner) aggregate,
          renderOperation
            (Just ((.group) owner))
            ((.targets) owner)
            [ (.name) readModel
            | readModel <- readModels,
              (.group) readModel == Just ((.group) owner),
              not (Set.disjoint (Set.fromList ((.observedTargets) readModel)) (Set.fromList ((.targets) owner)))
            ]
            ((.replay) owner == ProjectionReplayExplicit)
        )
      | NProjectionOwner owner <- (.nodes) spec,
        CatalogAggregate aggregate <- (.sources) owner
      ]
    renderOperation groupName targets observers canReplay =
      T.intercalate
        ";"
        [ "group=" <> maybe "(inline)" id groupName,
          "targets=" <> T.intercalate "," (sort targets),
          "read-models=" <> T.intercalate "," (sort observers),
          "replayable=" <> if canReplay then "yes" else "no"
        ]

unsupportedProjectionSources :: Spec -> [UnsupportedProjectionSource]
unsupportedProjectionSources spec =
  [ boundary
  | NProjectionOwner owner <- (.nodes) spec,
    source <- (.sources) owner,
    boundary <- case source of
      CatalogAggregate _ -> []
      CatalogCategory category -> [UnsupportedCatalogCategory ((.name) owner) category]
      CatalogAll -> [UnsupportedCatalogAll ((.name) owner)]
  ]

collectChecked :: [MappedDecl] -> Either (NonEmpty TypeGraphError) [CheckedMappedDecl]
collectChecked declarations =
  let checked = [(rawName declaration, checkMappedDecl declaration) | declaration <- declarations]
      errors =
        [ TGDeclError name err
        | (name, Left declarationErrors) <- checked,
          err <- NE.toList declarationErrors
        ]
   in case NE.nonEmpty errors of
        Just nonEmptyErrors -> Left nonEmptyErrors
        Nothing -> Right [declaration | (_, Right declaration) <- checked]

rejectMany :: [e] -> Either (NonEmpty e) ()
rejectMany errors = maybe (Right ()) Left (NE.nonEmpty errors)

rawName :: MappedDecl -> Name
rawName MappedStructural {msName = name} = name
rawName MappedOpaque {moName = name} = name

checkedName :: CheckedMappedDecl -> Name
checkedName (CheckedStructural declaration _) = (.name) declaration
checkedName (CheckedOpaque declaration) = (.name) declaration

ambiguityErrors :: Spec -> [CheckedMappedDecl] -> [TypeGraphError]
ambiguityErrors spec declarations =
  [ TGAmbiguousName name origins
  | (name, origins) <- Map.toList allOrigins,
    length origins > 1,
    "mapped" `elem` origins || "built-in" `elem` origins
  ]
  where
    builtins = ["Text", "Int", "Bool", "Natural", "Time", "UTCTime", "Json", "Optional", "List", "Map"]
    originPairs =
      [(checkedName declaration, "mapped") | declaration <- declarations]
        ++ [((.name) declaration, "id") | declaration <- (.ids) spec]
        ++ [((.name) declaration, "enum") | declaration <- (.enums) spec]
        ++ [((.name) declaration, "nominal scalar") | declaration <- (.nominalScalars) spec]
        ++ [(name, "built-in") | name <- builtins]
    allOrigins = Map.fromListWith (++) [(name, [origin]) | (name, origin) <- originPairs]

resolveCheckedDecl :: Map Name MappedKey -> Map Name NominalLeaf -> Set Name -> CheckedMappedDecl -> Either TypeGraphError (MappedKey, ResolvedMappedDecl)
resolveCheckedDecl _ _ _ (CheckedOpaque declaration) =
  Right (MappedKey ((.name) declaration), ResolvedOpaque declaration)
resolveCheckedDecl keyByName nominalByName enumNames (CheckedStructural declaration shape) = do
  resolvedShape <- resolveShape keyByName nominalByName enumNames ((.name) declaration) shape
  pure (MappedKey ((.name) declaration), ResolvedStructural declaration resolvedShape)

resolveShape :: Map Name MappedKey -> Map Name NominalLeaf -> Set Name -> Name -> MappedShape -> Either TypeGraphError ResolvedMappedShape
resolveShape keyByName nominalByName enumNames owner (ShapeRecord constructor unknownFields fields) =
  RRecord constructor unknownFields <$> traverse resolveField fields
  where
    resolveField field =
      ResolvedWireField
        ((.haskell) field)
        ((.key) field)
        <$> resolveExpr keyByName nominalByName enumNames owner (wireFieldLoc field) ((.valueType) field)
        <*> pure ((.presence) field)
        <*> pure ((.onMissing) field)
        <*> pure (wireFieldLoc field)
resolveShape _ _ _ _ (ShapeEnum entries) = Right (REnum entries)
resolveShape keyByName nominalByName enumNames owner (ShapeUnion encoding arms) =
  RUnion encoding <$> traverse resolveArm arms
  where
    resolveArm arm =
      ResolvedWireArm
        ((.ctor) arm)
        ((.tag) arm)
        <$> traverse (resolveExpr keyByName nominalByName enumNames owner ((.loc) arm)) ((.payload) arm)
        <*> pure ((.loc) arm)
resolveShape keyByName nominalByName enumNames owner (ShapeBare expression) =
  RBare <$> resolveExpr keyByName nominalByName enumNames owner noLoc expression

resolveExpr :: Map Name MappedKey -> Map Name NominalLeaf -> Set Name -> Name -> Loc -> TypeExpr -> Either TypeGraphError ResolvedTypeExpr
resolveExpr _ _ _ _ _ TText = Right RText
resolveExpr _ _ _ _ _ TInt = Right RInt
resolveExpr _ _ _ _ _ TInteger = Right RInteger
resolveExpr _ _ _ _ _ TBool = Right RBool
resolveExpr _ _ _ _ _ TNatural = Right RNatural
resolveExpr _ _ _ _ _ TTime = Right RTime
resolveExpr _ _ _ _ _ TDay = Right RDay
resolveExpr _ _ _ _ _ TJson = Right RJson
resolveExpr names nominals enums owner loc (TOptional value) = ROptional <$> resolveExpr names nominals enums owner loc value
resolveExpr names nominals enums owner loc (TList value) = RList <$> resolveExpr names nominals enums owner loc value
resolveExpr names nominals enums owner loc (TMap value) = RMap <$> resolveExpr names nominals enums owner loc value
resolveExpr names nominals enums owner loc (TKeyedMap key value) = do
  leaf <- case Map.lookup key nominals of
    Just candidate@NominalLeaf {kind = NominalIdLeaf {}} -> Right candidate
    Just NominalLeaf {kind = NominalEnumLeaf {}} -> Left (TGUnsupportedNominalLeaf owner key "enum map key" loc)
    Just NominalLeaf {kind = NominalScalarLeaf {}} -> Left (TGUnsupportedNominalLeaf owner key "nominal scalar map key" loc)
    Nothing
      | Map.member key names -> Left (TGUnsupportedNominalLeaf owner key "mapped map key" loc)
      | key `Set.member` enums -> Left (TGUnsupportedNominalLeaf owner key "enum map key" loc)
      | otherwise -> Left (TGUnresolvedRef owner key loc)
  RKeyedMap leaf <$> resolveExpr names nominals enums owner loc value
resolveExpr names nominals enums owner loc (TRef name) =
  case Map.lookup name names of
    Just key -> Right (RRef key)
    Nothing -> case Map.lookup name nominals of
      Just leaf -> Right (RNominal leaf)
      Nothing
        | name `Set.member` enums -> Left (TGUnsupportedNominalLeaf owner name "enum" loc)
        | otherwise -> Left (TGUnresolvedRef owner name loc)

-- | Resolve a consumer-surface type expression against an already checked
-- graph. Emitters use this entry point instead of reconstructing declaration
-- lookup rules independently.
resolveTypeExpression :: TypeGraph -> Text -> Loc -> TypeExpr -> Either TypeGraphError ResolvedTypeExpr
resolveTypeExpression graph owner loc = resolveExpr keyByName ((.nominalLeaves) graph) (Map.keysSet ((.unsupportedNominalLeafKinds) graph)) owner loc
  where
    keyByName = Map.fromList [(unMappedKey key, key) | key <- Map.keys ((.declarations) graph)]

cycleErrors :: Map MappedKey ResolvedMappedDecl -> [TypeGraphError]
cycleErrors declarations =
  [ TGRecursive (map unMappedKey keys)
  | CyclicSCC keys <- stronglyConnComp vertices
  ]
  where
    vertices =
      [ (key, key, Set.toList (directRefs declaration))
      | (key, declaration) <- Map.toList declarations
      ]

directRefs :: ResolvedMappedDecl -> Set MappedKey
directRefs =
  foldMappedDecl
    MappedDeclAlgebra
      { onStructuralDecl = \_ shape -> refsInShape shape,
        onOpaqueDecl = const Set.empty
      }

refsInShape :: ResolvedMappedShape -> Set MappedKey
refsInShape =
  foldMappedShape
    MappedShapeAlgebra
      { onRecord = \_ _ fields -> Set.unions (map (refsInExpr . (.valueType)) fields),
        onEnum = const Set.empty,
        onUnion = \_ arms -> Set.unions (map (maybe Set.empty refsInExpr . (.payload)) arms),
        onBare = refsInExpr
      }

refsInExpr :: ResolvedTypeExpr -> Set MappedKey
refsInExpr =
  foldTypeExpr
    TypeExprAlgebra
      { onText = Set.empty,
        onInt = Set.empty,
        onInteger = Set.empty,
        onBool = Set.empty,
        onNatural = Set.empty,
        onTime = Set.empty,
        onDay = Set.empty,
        onJson = Set.empty,
        onOptional = id,
        onList = id,
        onMap = id,
        onKeyedMap = \_ -> id,
        onRef = Set.singleton,
        onNominal = const Set.empty
      }

nominalRefsInExpr :: ResolvedTypeExpr -> Set Name
nominalRefsInExpr =
  foldTypeExpr
    TypeExprAlgebra
      { onText = Set.empty,
        onInt = Set.empty,
        onInteger = Set.empty,
        onBool = Set.empty,
        onNatural = Set.empty,
        onTime = Set.empty,
        onDay = Set.empty,
        onJson = Set.empty,
        onOptional = id,
        onList = id,
        onMap = id,
        onKeyedMap = \leaf value -> Set.insert ((.name) leaf) value,
        onRef = const Set.empty,
        onNominal = Set.singleton . (.name)
      }

directNominalRefs :: ResolvedMappedDecl -> Set Name
directNominalRefs =
  foldMappedDecl
    MappedDeclAlgebra
      { onStructuralDecl = \_ shape ->
          foldMappedShape
            MappedShapeAlgebra
              { onRecord = \_ _ fields -> Set.unions (map (nominalRefsInExpr . (.valueType)) fields),
                onEnum = const Set.empty,
                onUnion = \_ arms -> Set.unions (map (maybe Set.empty nominalRefsInExpr . (.payload)) arms),
                onBare = nominalRefsInExpr
              }
            shape,
        onOpaqueDecl = const Set.empty
      }

nominalsReachableFrom :: Map MappedKey ResolvedMappedDecl -> MappedKey -> ResolvedMappedDecl -> Set Name
nominalsReachableFrom declarations _ declaration = go Set.empty Set.empty [declaration]
  where
    go _ names [] = names
    go visited names (current : rest) =
      let names' = names <> directNominalRefs current
          nextKeys = Set.toList (directRefs current `Set.difference` visited)
          next = [value | key <- nextKeys, Just value <- [Map.lookup key declarations]]
       in go (visited <> Set.fromList nextKeys) names' (next <> rest)

reachableFrom :: Map MappedKey ResolvedMappedDecl -> MappedKey -> ResolvedMappedDecl -> Set MappedKey
reachableFrom declarations origin declaration = go Set.empty (Set.toList (directRefs declaration))
  where
    go visited [] = Set.delete origin visited
    go visited (key : rest)
      | key `Set.member` visited = go visited rest
      | otherwise =
          let next = maybe [] (Set.toList . directRefs) (Map.lookup key declarations)
           in go (Set.insert key visited) (next ++ rest)

data CollectedRoot
  = CollectedMapped !UseSite ![PathSeg]
  | CollectedNominal !NominalRootSite
  | CollectedNone

data RootReference
  = MappedRootReference !MappedKey ![PathSeg]
  | NominalRootReference !Name ![PathSeg]

collectUseSites :: Map Name MappedKey -> Map Name NominalLeaf -> Set Name -> Spec -> [Either TypeGraphError CollectedRoot]
collectUseSites keyByName nominalByName enumNames spec =
  map Right (concatMap aggregateSites aggregates)
    <> map Right (concatMap contractSites contracts)
    <> concatMap workqueueSites workqueues
    <> concatMap readModelSites readModels
  where
    aggregates = [aggregate | NAggregate aggregate <- (.nodes) spec]
    contracts = [contract | NContract contract <- (.nodes) spec]
    workqueues = [workqueue | NWorkqueue workqueue <- (.nodes) spec]
    readModels = [readModel | NReadModel readModel <- (.nodes) spec]
    aggregateSites aggregate =
      [ aggregateSite
          (RootCommandField ((.name) aggregate) ((.name) command) ((.name) field))
          ((.loc) field)
          expression
      | command <- (.commands) aggregate,
        field <- (.fields) command,
        expression <- maybeToList ((.valueType) field)
      ]
        ++ [ aggregateSite
               (RootEventField ((.name) aggregate) ((.name) event) ((.name) field))
               ((.loc) field)
               expression
           | event <- (.events) aggregate,
             field <- eventFields aggregate event,
             expression <- maybeToList ((.valueType) field)
           ]
        ++ [ aggregateSite
               (RootRegister ((.name) aggregate) ((.name) register))
               ((.loc) register)
               ((.valueType) register)
           | register <- (.regs) aggregate
           ]

    contractSites contract =
      [ CollectedNominal
          ( NominalRootSite
              (RootContractField ((.name) contract) ((.name) event) ((.name) field))
              nominalName
              []
          )
      | event <- (.events) contract,
        field <- (.fields) event,
        CDeclaredId nominalName <- [(.valueType) field],
        Just NominalLeaf {kind = NominalIdLeaf {}} <- [Map.lookup nominalName nominalByName]
      ]

    -- Aggregate validation owns unresolved and enum references.  This graph
    -- projection records only the mapped/nominal roots it can resolve without
    -- changing those established diagnostics.
    aggregateSite rootRef loc expression =
      case resolveExpr keyByName nominalByName enumNames "aggregate consumer" loc expression of
        Right resolved -> case rootReference resolved of
          Just (MappedRootReference key segments) -> CollectedMapped (UseSite rootRef key) segments
          Just (NominalRootReference name segments) -> CollectedNominal (NominalRootSite rootRef name segments)
          Nothing -> CollectedNone
        Left _ -> CollectedNone

    workqueueSites workqueue =
      [ consumerSite
          ("workqueue '" <> (.name) workqueue <> "' payload field '" <> (.name) field <> "'")
          ((.loc) field)
          (RootWorkqueueField ((.name) workqueue) ((.name) field))
          expression
      | field <- (.payload) workqueue,
        TypedQueueExpression expression <- [(.valueType) field]
      ]

    readModelSites readModel = case (.queryTypes) readModel of
      Nothing -> []
      Just ReadModelQueryTypes {input, result, inputLoc, resultLoc} ->
        [ consumerSite
            ("readmodel '" <> (.name) readModel <> "' query input")
            inputLoc
            (RootReadModelQueryInput ((.name) readModel))
            input,
          consumerSite
            ("readmodel '" <> (.name) readModel <> "' query result")
            resultLoc
            (RootReadModelQueryResult ((.name) readModel))
            result
        ]

    consumerSite owner loc rootRef expression =
      case resolveExpr keyByName nominalByName enumNames owner loc expression of
        Left (TGUnresolvedRef _ missing _) -> Left (TGUnresolvedConsumerRef owner missing loc)
        Left other -> Left other
        Right resolved -> case rootReference resolved of
          Nothing -> Right CollectedNone
          Just (MappedRootReference key segments) -> Right (CollectedMapped (UseSite rootRef key) segments)
          Just (NominalRootReference name segments) -> Right (CollectedNominal (NominalRootSite rootRef name segments))

    rootReference = \case
      RText -> Nothing
      RInt -> Nothing
      RInteger -> Nothing
      RBool -> Nothing
      RNatural -> Nothing
      RTime -> Nothing
      RDay -> Nothing
      RJson -> Nothing
      ROptional value -> prepend SegOptional (rootReference value)
      RList value -> prepend SegElem (rootReference value)
      RMap value -> prepend SegMapValue (rootReference value)
      RKeyedMap _ value -> prepend SegMapValue (rootReference value)
      RRef key -> Just (MappedRootReference key [])
      RNominal leaf -> Just (NominalRootReference ((.name) leaf) [])
    prepend segment = fmap $ \case
      MappedRootReference key segments -> MappedRootReference key (segment : segments)
      NominalRootReference name segments -> NominalRootReference name (segment : segments)

    eventFields aggregate event = case (.body) event of
      EventFields fields -> fields
      EventFromCommand commandName ->
        concat [(.fields) command | command <- (.commands) aggregate, (.name) command == commandName]

    maybeToList = maybe [] pure

usePaths :: TypeGraph -> Name -> [UsePath]
usePaths graph targetName = case Map.lookup (MappedKey targetName) ((.declarations) graph) of
  Nothing -> []
  Just _ ->
    [ UsePath ((.root) site) segments
    | site <- (.useSites) graph,
      segments <- sitePaths site
    ]
  where
    target = MappedKey targetName
    sitePaths site
      | siteKey site == target = [[SegDecl (unMappedKey target)] <> rootSegments site]
      | otherwise =
          map
            (\segments -> [SegDecl (unMappedKey (siteKey site))] <> rootSegments site <> segments)
            (pathsFromDecl Set.empty (siteKey site))

    rootSegments = useSiteSegments graph

    pathsFromDecl visited current
      | current `Set.member` visited = []
      | otherwise = case Map.lookup current ((.declarations) graph) of
          Nothing -> []
          Just declaration ->
            foldMappedDecl
              MappedDeclAlgebra
                { onStructuralDecl = \_ shape -> pathsInShape (Set.insert current visited) shape,
                  onOpaqueDecl = const []
                }
              declaration

    pathsInShape visited =
      foldMappedShape
        MappedShapeAlgebra
          { onRecord = \_ _ fields ->
              concat
                [ map (SegField ((.haskell) field) ((.key) field) :) (pathsInExpr visited ((.valueType) field))
                | field <- fields
                ],
            onEnum = const [],
            onUnion = \_ arms ->
              concat
                [ map (SegArm ((.ctor) arm) ((.tag) arm) :) (maybe [] (pathsInExpr visited) ((.payload) arm))
                | arm <- arms
                ],
            onBare = pathsInExpr visited
          }

    pathsInExpr visited = \case
      RText -> []
      RInt -> []
      RInteger -> []
      RBool -> []
      RNatural -> []
      RTime -> []
      RDay -> []
      RJson -> []
      ROptional value -> map (SegOptional :) (pathsInExpr visited value)
      RList value -> map (SegElem :) (pathsInExpr visited value)
      RMap value -> map (SegMapValue :) (pathsInExpr visited value)
      RKeyedMap _ value -> map (SegMapValue :) (pathsInExpr visited value)
      RRef key
        | key == target -> [[SegDecl (unMappedKey key)]]
        | otherwise -> map (SegDecl (unMappedKey key) :) (pathsFromDecl visited key)
      RNominal _ -> []

nominalUsePaths :: TypeGraph -> Name -> [UsePath]
nominalUsePaths graph targetName
  | Map.notMember targetName ((.nominalLeaves) graph) = []
  | otherwise = mappedPaths <> directPaths
  where
    mappedPaths =
      [ UsePath
          ((.root) site)
          ( [SegDecl (unMappedKey (siteKey site))]
              <> useSiteSegments graph site
              <> segments
          )
      | site <- (.useSites) graph,
        segments <- pathsFromDecl Set.empty (siteKey site)
      ]
    directPaths =
      [ UsePath ((.root) site) ([SegNominal targetName] <> (.segments) site)
      | site <- (.nominalRootSites) graph,
        (.nominal) site == targetName
      ]

    pathsFromDecl visited current
      | current `Set.member` visited = []
      | otherwise = case Map.lookup current ((.declarations) graph) of
          Nothing -> []
          Just declaration ->
            foldMappedDecl
              MappedDeclAlgebra
                { onStructuralDecl = \_ shape -> pathsInShape (Set.insert current visited) shape,
                  onOpaqueDecl = const []
                }
              declaration

    pathsInShape visited =
      foldMappedShape
        MappedShapeAlgebra
          { onRecord = \_ _ fields ->
              concat
                [ map (SegField ((.haskell) field) ((.key) field) :) (pathsInExpr visited ((.valueType) field))
                | field <- fields
                ],
            onEnum = const [],
            onUnion = \_ arms ->
              concat
                [ map (SegArm ((.ctor) arm) ((.tag) arm) :) (maybe [] (pathsInExpr visited) ((.payload) arm))
                | arm <- arms
                ],
            onBare = pathsInExpr visited
          }

    pathsInExpr visited = \case
      RText -> []
      RInt -> []
      RInteger -> []
      RBool -> []
      RNatural -> []
      RTime -> []
      RDay -> []
      RJson -> []
      ROptional value -> map (SegOptional :) (pathsInExpr visited value)
      RList value -> map (SegElem :) (pathsInExpr visited value)
      RMap value -> map (SegMapValue :) (pathsInExpr visited value)
      RKeyedMap leaf value ->
        [ [SegMapKey, SegNominal targetName]
        | (.name) leaf == targetName
        ]
          <> map (SegMapValue :) (pathsInExpr visited value)
      RRef key -> map (SegDecl (unMappedKey key) :) (pathsFromDecl visited key)
      RNominal leaf
        | (.name) leaf == targetName -> [[SegNominal targetName]]
        | otherwise -> []

siteKey :: UseSite -> MappedKey
siteKey = (.mappedKey)

-- | Container path segments attached to a consumer root before its first
-- mapped declaration reference.
useSiteSegments :: TypeGraph -> UseSite -> [PathSeg]
useSiteSegments graph site = Map.findWithDefault [] site ((.rootSegments) graph)

renderUsePath :: UsePath -> Text
renderUsePath (UsePath root segments) = renderRoot root <> T.concat (map renderSegment segments)
  where
    renderRoot (RootCommandField aggregate command field) =
      aggregate <> " command " <> command <> " ." <> field
    renderRoot (RootEventField aggregate event field) =
      aggregate <> " event " <> event <> " ." <> field
    renderRoot (RootRegister aggregate register) =
      aggregate <> " register " <> register
    renderRoot (RootWorkqueueField workqueue field) =
      "workqueue " <> workqueue <> " payload ." <> field
    renderRoot (RootReadModelQueryInput readModel) =
      "readmodel " <> readModel <> " query input"
    renderRoot (RootReadModelQueryResult readModel) =
      "readmodel " <> readModel <> " query result"
    renderRoot (RootContractField contract event field) =
      "contract " <> contract <> " event " <> event <> " ." <> field

    renderSegment (SegField haskellName wireName)
      | haskellName == wireName = " ." <> haskellName
      | otherwise = " ." <> haskellName <> " as " <> quoted wireName
    renderSegment (SegArm _ wireTag) = " arm " <> quoted wireTag
    renderSegment SegElem = " []"
    renderSegment SegMapKey = " {key}"
    renderSegment SegMapValue = " {}"
    renderSegment SegOptional = " optional"
    renderSegment (SegDecl name) = " : " <> name
    renderSegment (SegNominal name) = " : " <> name
    quoted value = T.pack (show value)

data TypeExprAlgebra a = TypeExprAlgebra
  { onText :: a,
    onInt :: a,
    onInteger :: a,
    onBool :: a,
    onNatural :: a,
    onTime :: a,
    onDay :: a,
    onJson :: a,
    onOptional :: a -> a,
    onList :: a -> a,
    onMap :: a -> a,
    onKeyedMap :: NominalLeaf -> a -> a,
    onRef :: MappedKey -> a,
    onNominal :: NominalLeaf -> a
  }

foldTypeExpr :: TypeExprAlgebra a -> ResolvedTypeExpr -> a
foldTypeExpr algebra = \case
  RText -> (.onText) algebra
  RInt -> (.onInt) algebra
  RInteger -> (.onInteger) algebra
  RBool -> (.onBool) algebra
  RNatural -> (.onNatural) algebra
  RTime -> (.onTime) algebra
  RDay -> (.onDay) algebra
  RJson -> (.onJson) algebra
  ROptional value -> (.onOptional) algebra (foldTypeExpr algebra value)
  RList value -> (.onList) algebra (foldTypeExpr algebra value)
  RMap value -> (.onMap) algebra (foldTypeExpr algebra value)
  RKeyedMap key value -> (.onKeyedMap) algebra key (foldTypeExpr algebra value)
  RRef key -> (.onRef) algebra key
  RNominal leaf -> (.onNominal) algebra leaf

data MappedShapeAlgebra a = MappedShapeAlgebra
  { onRecord :: Name -> UnknownFields -> [ResolvedWireField] -> a,
    onEnum :: [WireEnum] -> a,
    onUnion :: UnionEncoding -> [ResolvedWireArm] -> a,
    onBare :: ResolvedTypeExpr -> a
  }

foldMappedShape :: MappedShapeAlgebra a -> ResolvedMappedShape -> a
foldMappedShape algebra = \case
  RRecord constructor unknownFields fields -> (.onRecord) algebra constructor unknownFields fields
  REnum entries -> (.onEnum) algebra entries
  RUnion encoding arms -> (.onUnion) algebra encoding arms
  RBare expression -> (.onBare) algebra expression

data MappedDeclAlgebra a = MappedDeclAlgebra
  { onStructuralDecl :: StructuralDecl -> ResolvedMappedShape -> a,
    onOpaqueDecl :: OpaqueDecl -> a
  }

foldMappedDecl :: MappedDeclAlgebra a -> ResolvedMappedDecl -> a
foldMappedDecl algebra = \case
  ResolvedStructural declaration shape -> (.onStructuralDecl) algebra declaration shape
  ResolvedOpaque declaration -> (.onOpaqueDecl) algebra declaration

wireFingerprint :: TypeGraph -> Name -> Text
wireFingerprint = wireFingerprintForCalendarDayPolicy calendarDayCodecPolicyIdentity

-- | Compatibility-analysis seam for proving that a calendar-day policy bump
-- changes persisted wire identity. Production callers use 'wireFingerprint',
-- which always selects the released Keiro policy.
wireFingerprintForCalendarDayPolicy :: Text -> TypeGraph -> Name -> Text
wireFingerprintForCalendarDayPolicy calendarDayPolicy graph name = fnv1a64 (wireDecl Set.empty (MappedKey name))
  where
    declarations = (.declarations) graph

    wireDecl visited key
      | key `Set.member` visited = "recursive"
      | otherwise = case Map.lookup key declarations of
          Nothing -> error ("keiro-dsl internal invariant: wire fingerprint references missing mapped declaration " <> T.unpack (unMappedKey key))
          Just declaration ->
            foldMappedDecl
              MappedDeclAlgebra
                { onStructuralDecl = \_ shape -> wireShape (Set.insert key visited) shape,
                  onOpaqueDecl = \opaque ->
                    "opaque(" <> atom (unCodecIdentity ((.codecIdentity) opaque)) <> "," <> atom (unCodecVersion ((.codecVersion) opaque)) <> ")"
                }
              declaration

    wireShape visited =
      foldMappedShape
        MappedShapeAlgebra
          { onRecord = \_ unknownFields fields ->
              "record(" <> renderUnknown unknownFields <> ";" <> T.intercalate ";" (map (wireField visited) (sortOn (.key) fields)) <> ")",
            onEnum = \entries ->
              "enum(" <> T.intercalate ";" (map (atom . (.tag)) (sortOn (.tag) entries)) <> ")",
            onUnion = \encoding arms ->
              "union("
                <> atom ((.tagField) encoding)
                <> ","
                <> atom ((.contentsField) encoding)
                <> ","
                <> renderUnknown ((.unknownFields) encoding)
                <> ";"
                <> T.intercalate ";" (map (wireArm visited) (sortOn (.tag) arms))
                <> ")",
            onBare = wireExpr visited
          }

    wireField visited field =
      atom ((.key) field)
        <> ":"
        <> wireExpr visited ((.valueType) field)
        <> ":"
        <> renderPresence ((.presence) field)
        <> ":"
        <> maybe "none" (renderDefault field) ((.onMissing) field)

    wireArm visited arm = atom ((.tag) arm) <> maybe ":unit" ((":" <>) . wireExpr visited) ((.payload) arm)

    wireExpr visited = \case
      RText -> "text"
      RInt -> "int"
      RInteger -> "integer"
      RBool -> "bool"
      RNatural -> "natural"
      RTime -> "time"
      RDay -> "calendar-day(" <> calendarDayPolicy <> ")"
      RJson -> "json"
      ROptional value -> "optional(" <> wireExpr visited value <> ")"
      RList value -> "list(" <> wireExpr visited value <> ")"
      RMap value -> "map(" <> wireExpr visited value <> ")"
      RKeyedMap key value -> "map(key=" <> nominalWireToken key <> ";" <> wireExpr visited value <> ")"
      RRef key -> wireDecl visited key
      RNominal leaf -> nominalWireToken leaf

    renderDefault field (OmCtor constructor) =
      case (.valueType) field of
        RRef key -> case Map.lookup key declarations of
          Just (ResolvedStructural _ (REnum entries)) ->
            maybe ("ctor:" <> atom constructor) ("enum:" <>) (lookup constructor [((.ctor) entry, atom ((.tag) entry)) | entry <- entries])
          _ -> "ctor:" <> atom constructor
        RNominal leaf -> case (.kind) leaf of
          NominalEnumLeaf constructors ->
            maybe ("ctor:" <> atom constructor) ("enum:" <>) (lookup constructor [(constructorName, atom wire) | (constructorName, wire) <- NE.toList constructors])
          NominalIdLeaf {} -> "ctor:" <> atom constructor
          NominalScalarLeaf {} -> "ctor:" <> atom constructor
        _ -> "ctor:" <> atom constructor
    renderDefault _ value = T.pack (show value)

    renderUnknown RejectUnknown = "reject"
    renderUnknown IgnoreUnknown = "ignore"
    renderPresence PRequired = "required"
    renderPresence POptional = "optional"
    atom value = T.pack (show value)

nominalWireFingerprint :: NominalLeaf -> Text
nominalWireFingerprint = fnv1a64 . nominalWireToken

nominalWireToken :: NominalLeaf -> Text
nominalWireToken leaf = case (.kind) leaf of
  NominalIdLeaf prefix -> "nominal-id(" <> prefix <> "," <> nominalIdDomainVersion <> ")"
  NominalEnumLeaf constructors ->
    "nominal-enum(" <> T.intercalate ";" (sort (map snd (NE.toList constructors))) <> ")"
  NominalScalarLeaf representation -> "nominal-scalar(" <> scalarToken representation <> ")"
  where
    scalarToken = \case
      NominalText -> "Text"
      NominalInt -> "Int"
      NominalNatural -> "Natural"
      NominalBool -> "Bool"
      NominalTime -> "Time"

-- Kept byte-identical to Keiro.Dsl.IdDomain.enforcedIdDomainVersion.  This
-- low-level graph module cannot import IdDomain because that module reads
-- CheckedService, whose analysis contains this graph.
nominalIdDomainVersion :: Text
nominalIdDomainVersion = "keiro-dsl/id-domain/typeid-v7/1"

fnv1a64 :: Text -> Text
fnv1a64 input =
  let offsetBasis = 14695981039346656037 :: Word64
      prime = 1099511628211 :: Word64
      digest = T.foldl' (\hash char -> (hash `xor` fromIntegral (ord char)) * prime) offsetBasis input
      hexadecimal = showHex digest ""
   in T.pack (replicate (16 - length hexadecimal) '0' <> hexadecimal)

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
  Just (initial, rest) -> asciiUpper initial && T.all asciiAlphaNumOrUnderscore rest
  Nothing -> False

lowerIdentifierSafe :: Text -> Bool
lowerIdentifierSafe name = case T.uncons name of
  Just (initial, rest) -> asciiLower initial && T.all asciiAlphaNumOrUnderscore rest && name `Set.notMember` haskellKeywords
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
