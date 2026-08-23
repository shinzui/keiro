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
    UseSite (..),
    PathSeg (..),
    UsePath (..),
    resolveTypeGraph,
    resolveTypeExpression,
    useSiteSegments,
    usePaths,
    renderUsePath,
    TypeExprAlgebra (..),
    foldTypeExpr,
    MappedShapeAlgebra (..),
    foldMappedShape,
    MappedDeclAlgebra (..),
    foldMappedDecl,
    wireFingerprint,
  )
where

import Data.Bifunctor (first)
import Data.Bits (xor)
import Data.Char (ord)
import Data.Either (partitionEithers)
import Data.Graph (SCC (..), stronglyConnComp)
import Data.List (sort, sortOn)
import Data.List.NonEmpty (NonEmpty (..))
import Data.List.NonEmpty qualified as NE
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (catMaybes)
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Word (Word64)
import GHC.Generics (Generic)
import Keiro.Dsl.Grammar
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
  | RJson
  | ROptional !ResolvedTypeExpr
  | RList !ResolvedTypeExpr
  | RMap !ResolvedTypeExpr
  | RRef !MappedKey
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
  | TGRecursive ![Name]
  deriving stock (Eq, Show, Generic)

data UseSite
  = RootCommandField !Name !Name !Name !MappedKey
  | RootEventField !Name !Name !Name !MappedKey
  | RootRegister !Name !Name !MappedKey
  | RootWorkqueueField !Name !Name !MappedKey
  | RootReadModelQueryInput !Name !MappedKey
  | RootReadModelQueryResult !Name !MappedKey
  deriving stock (Eq, Ord, Show, Generic)

data PathSeg
  = SegField !Name !Text
  | SegArm !Name !Text
  | SegElem
  | SegMapValue
  | SegOptional
  | SegDecl !Name
  deriving stock (Eq, Ord, Show, Generic)

data UsePath = UsePath
  { root :: !UseSite,
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
    useSites :: ![UseSite],
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
      (resolveErrors, resolvedPairs) = partitionEithers (map (resolveCheckedDecl keyByName) checked)
  rejectMany resolveErrors
  let declarations = Map.fromList resolvedPairs
  rejectMany (cycleErrors declarations)
  let reachability = Map.mapWithKey (reachableFrom declarations) declarations
      (rootErrors, rootSites) = partitionEithers (collectUseSites keyByName spec)
  rejectMany rootErrors
  pure
    TypeGraph
      { declarations = declarations,
        reachability = reachability,
        useSites = map fst (catMaybes rootSites),
        rootSegments = Map.fromList (catMaybes rootSites),
        derivedMappedConsumers = sort (derivedMappedConsumers spec),
        replayableProjectionGroups = replayableProjectionGroups spec,
        projectionOperationalIdentities = projectionOperationalIdentities spec,
        unsupportedProjectionSources = sort (unsupportedProjectionSources spec)
      }

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
    length origins > 1
  ]
  where
    builtins = ["Text", "Int", "Bool", "Natural", "Time", "UTCTime", "Json", "Optional", "List", "Map"]
    originPairs =
      [(checkedName declaration, "mapped") | declaration <- declarations]
        ++ [((.name) declaration, "id") | declaration <- (.ids) spec]
        ++ [((.name) declaration, "enum") | declaration <- (.enums) spec]
        ++ [(name, "built-in") | name <- builtins]
    allOrigins = Map.fromListWith (++) [(name, [origin]) | (name, origin) <- originPairs]

resolveCheckedDecl :: Map Name MappedKey -> CheckedMappedDecl -> Either TypeGraphError (MappedKey, ResolvedMappedDecl)
resolveCheckedDecl _ (CheckedOpaque declaration) =
  Right (MappedKey ((.name) declaration), ResolvedOpaque declaration)
resolveCheckedDecl keyByName (CheckedStructural declaration shape) = do
  resolvedShape <- resolveShape keyByName ((.name) declaration) shape
  pure (MappedKey ((.name) declaration), ResolvedStructural declaration resolvedShape)

resolveShape :: Map Name MappedKey -> Name -> MappedShape -> Either TypeGraphError ResolvedMappedShape
resolveShape keyByName owner (ShapeRecord constructor unknownFields fields) =
  RRecord constructor unknownFields <$> traverse resolveField fields
  where
    resolveField field =
      ResolvedWireField
        ((.haskell) field)
        ((.key) field)
        <$> resolveExpr keyByName owner (wireFieldLoc field) ((.valueType) field)
        <*> pure ((.presence) field)
        <*> pure ((.onMissing) field)
        <*> pure (wireFieldLoc field)
resolveShape _ _ (ShapeEnum entries) = Right (REnum entries)
resolveShape keyByName owner (ShapeUnion encoding arms) =
  RUnion encoding <$> traverse resolveArm arms
  where
    resolveArm arm =
      ResolvedWireArm
        ((.ctor) arm)
        ((.tag) arm)
        <$> traverse (resolveExpr keyByName owner ((.loc) arm)) ((.payload) arm)
        <*> pure ((.loc) arm)

resolveExpr :: Map Name MappedKey -> Name -> Loc -> TypeExpr -> Either TypeGraphError ResolvedTypeExpr
resolveExpr _ _ _ TText = Right RText
resolveExpr _ _ _ TInt = Right RInt
resolveExpr _ _ _ TInteger = Right RInteger
resolveExpr _ _ _ TBool = Right RBool
resolveExpr _ _ _ TNatural = Right RNatural
resolveExpr _ _ _ TTime = Right RTime
resolveExpr _ _ _ TJson = Right RJson
resolveExpr names owner loc (TOptional value) = ROptional <$> resolveExpr names owner loc value
resolveExpr names owner loc (TList value) = RList <$> resolveExpr names owner loc value
resolveExpr names owner loc (TMap value) = RMap <$> resolveExpr names owner loc value
resolveExpr names owner loc (TRef name) =
  maybe (Left (TGUnresolvedRef owner name loc)) (Right . RRef) (Map.lookup name names)

-- | Resolve a consumer-surface type expression against an already checked
-- graph. Emitters use this entry point instead of reconstructing declaration
-- lookup rules independently.
resolveTypeExpression :: TypeGraph -> Text -> Loc -> TypeExpr -> Either TypeGraphError ResolvedTypeExpr
resolveTypeExpression graph owner loc = resolveExpr keyByName owner loc
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
        onUnion = \_ arms -> Set.unions (map (maybe Set.empty refsInExpr . (.payload)) arms)
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
        onJson = Set.empty,
        onOptional = id,
        onList = id,
        onMap = id,
        onRef = Set.singleton
      }

reachableFrom :: Map MappedKey ResolvedMappedDecl -> MappedKey -> ResolvedMappedDecl -> Set MappedKey
reachableFrom declarations origin declaration = go Set.empty (Set.toList (directRefs declaration))
  where
    go visited [] = Set.delete origin visited
    go visited (key : rest)
      | key `Set.member` visited = go visited rest
      | otherwise =
          let next = maybe [] (Set.toList . directRefs) (Map.lookup key declarations)
           in go (Set.insert key visited) (next ++ rest)

collectUseSites :: Map Name MappedKey -> Spec -> [Either TypeGraphError (Maybe (UseSite, [PathSeg]))]
collectUseSites keyByName spec =
  map (Right . Just) (concatMap aggregateSites aggregates)
    <> concatMap workqueueSites workqueues
    <> concatMap readModelSites readModels
  where
    aggregates = [aggregate | NAggregate aggregate <- (.nodes) spec]
    workqueues = [workqueue | NWorkqueue workqueue <- (.nodes) spec]
    readModels = [readModel | NReadModel readModel <- (.nodes) spec]
    aggregateSites aggregate =
      [ (RootCommandField ((.name) aggregate) ((.name) command) ((.name) field) key, [])
      | command <- (.commands) aggregate,
        field <- (.fields) command,
        key <- maybeToList ((.valueType) field >>= typeRefName >>= (`Map.lookup` keyByName))
      ]
        ++ [ (RootEventField ((.name) aggregate) ((.name) event) ((.name) field) key, [])
           | event <- (.events) aggregate,
             field <- eventFields aggregate event,
             key <- maybeToList ((.valueType) field >>= typeRefName >>= (`Map.lookup` keyByName))
           ]
        ++ [ (RootRegister ((.name) aggregate) ((.name) register) key, [])
           | register <- (.regs) aggregate,
             key <- maybeToList (typeRefName ((.valueType) register) >>= (`Map.lookup` keyByName))
           ]

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

    consumerSite owner loc constructor expression =
      case resolveExpr keyByName owner loc expression of
        Left (TGUnresolvedRef _ missing _) -> Left (TGUnresolvedConsumerRef owner missing loc)
        Left other -> Left other
        Right resolved -> case rootReference resolved of
          Nothing -> Right Nothing
          Just (key, segments) -> Right (Just (constructor key, segments))

    rootReference = \case
      RText -> Nothing
      RInt -> Nothing
      RInteger -> Nothing
      RBool -> Nothing
      RNatural -> Nothing
      RTime -> Nothing
      RJson -> Nothing
      ROptional value -> prepend SegOptional (rootReference value)
      RList value -> prepend SegElem (rootReference value)
      RMap value -> prepend SegMapValue (rootReference value)
      RRef key -> Just (key, [])
    prepend segment = fmap (\(key, segments) -> (key, segment : segments))

    eventFields aggregate event = case (.body) event of
      EventFields fields -> fields
      EventFromCommand commandName ->
        concat [(.fields) command | command <- (.commands) aggregate, (.name) command == commandName]

    maybeToList = maybe [] pure
    typeRefName (TRef name) = Just name
    typeRefName _ = Nothing

usePaths :: TypeGraph -> Name -> [UsePath]
usePaths graph targetName = case Map.lookup (MappedKey targetName) ((.declarations) graph) of
  Nothing -> []
  Just _ ->
    [ UsePath site segments
    | site <- (.useSites) graph,
      segments <- sitePaths site
    ]
  where
    target = MappedKey targetName
    sitePaths site
      | siteKey site == target = [rootSegments site]
      | otherwise = map (rootSegments site <>) (pathsFromDecl Set.empty (siteKey site))

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
                ]
          }

    pathsInExpr visited = \case
      RText -> []
      RInt -> []
      RInteger -> []
      RBool -> []
      RNatural -> []
      RTime -> []
      RJson -> []
      ROptional value -> map (SegOptional :) (pathsInExpr visited value)
      RList value -> map (SegElem :) (pathsInExpr visited value)
      RMap value -> map (SegMapValue :) (pathsInExpr visited value)
      RRef key
        | key == target -> [[SegDecl (unMappedKey key)]]
        | otherwise -> map (SegDecl (unMappedKey key) :) (pathsFromDecl visited key)

siteKey :: UseSite -> MappedKey
siteKey (RootCommandField _ _ _ key) = key
siteKey (RootEventField _ _ _ key) = key
siteKey (RootRegister _ _ key) = key
siteKey (RootWorkqueueField _ _ key) = key
siteKey (RootReadModelQueryInput _ key) = key
siteKey (RootReadModelQueryResult _ key) = key

-- | Container path segments attached to a consumer root before its first
-- mapped declaration reference.
useSiteSegments :: TypeGraph -> UseSite -> [PathSeg]
useSiteSegments graph site = Map.findWithDefault [] site ((.rootSegments) graph)

renderUsePath :: UsePath -> Text
renderUsePath (UsePath root segments) = renderRoot root <> T.concat (map renderSegment segments)
  where
    renderRoot (RootCommandField aggregate command field key) =
      aggregate <> " command " <> command <> " ." <> field <> " : " <> unMappedKey key
    renderRoot (RootEventField aggregate event field key) =
      aggregate <> " event " <> event <> " ." <> field <> " : " <> unMappedKey key
    renderRoot (RootRegister aggregate register key) =
      aggregate <> " register " <> register <> " : " <> unMappedKey key
    renderRoot (RootWorkqueueField workqueue field key) =
      "workqueue " <> workqueue <> " payload ." <> field <> " : " <> unMappedKey key
    renderRoot (RootReadModelQueryInput readModel key) =
      "readmodel " <> readModel <> " query input : " <> unMappedKey key
    renderRoot (RootReadModelQueryResult readModel key) =
      "readmodel " <> readModel <> " query result : " <> unMappedKey key

    renderSegment (SegField haskellName wireName)
      | haskellName == wireName = " ." <> haskellName
      | otherwise = " ." <> haskellName <> " as " <> quoted wireName
    renderSegment (SegArm _ wireTag) = " arm " <> quoted wireTag
    renderSegment SegElem = " []"
    renderSegment SegMapValue = " {}"
    renderSegment SegOptional = " optional"
    renderSegment (SegDecl name) = " : " <> name
    quoted value = T.pack (show value)

data TypeExprAlgebra a = TypeExprAlgebra
  { onText :: a,
    onInt :: a,
    onInteger :: a,
    onBool :: a,
    onNatural :: a,
    onTime :: a,
    onJson :: a,
    onOptional :: a -> a,
    onList :: a -> a,
    onMap :: a -> a,
    onRef :: MappedKey -> a
  }

foldTypeExpr :: TypeExprAlgebra a -> ResolvedTypeExpr -> a
foldTypeExpr algebra = \case
  RText -> (.onText) algebra
  RInt -> (.onInt) algebra
  RInteger -> (.onInteger) algebra
  RBool -> (.onBool) algebra
  RNatural -> (.onNatural) algebra
  RTime -> (.onTime) algebra
  RJson -> (.onJson) algebra
  ROptional value -> (.onOptional) algebra (foldTypeExpr algebra value)
  RList value -> (.onList) algebra (foldTypeExpr algebra value)
  RMap value -> (.onMap) algebra (foldTypeExpr algebra value)
  RRef key -> (.onRef) algebra key

data MappedShapeAlgebra a = MappedShapeAlgebra
  { onRecord :: Name -> UnknownFields -> [ResolvedWireField] -> a,
    onEnum :: [WireEnum] -> a,
    onUnion :: UnionEncoding -> [ResolvedWireArm] -> a
  }

foldMappedShape :: MappedShapeAlgebra a -> ResolvedMappedShape -> a
foldMappedShape algebra = \case
  RRecord constructor unknownFields fields -> (.onRecord) algebra constructor unknownFields fields
  REnum entries -> (.onEnum) algebra entries
  RUnion encoding arms -> (.onUnion) algebra encoding arms

data MappedDeclAlgebra a = MappedDeclAlgebra
  { onStructuralDecl :: StructuralDecl -> ResolvedMappedShape -> a,
    onOpaqueDecl :: OpaqueDecl -> a
  }

foldMappedDecl :: MappedDeclAlgebra a -> ResolvedMappedDecl -> a
foldMappedDecl algebra = \case
  ResolvedStructural declaration shape -> (.onStructuralDecl) algebra declaration shape
  ResolvedOpaque declaration -> (.onOpaqueDecl) algebra declaration

wireFingerprint :: TypeGraph -> Name -> Text
wireFingerprint graph name = fnv1a64 (wireDecl Set.empty (MappedKey name))
  where
    declarations = (.declarations) graph

    wireDecl visited key
      | key `Set.member` visited = "recursive"
      | otherwise = case Map.lookup key declarations of
          Nothing -> "missing:" <> unMappedKey key
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
                <> ")"
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
      RJson -> "json"
      ROptional value -> "optional(" <> wireExpr visited value <> ")"
      RList value -> "list(" <> wireExpr visited value <> ")"
      RMap value -> "map(" <> wireExpr visited value <> ")"
      RRef key -> wireDecl visited key

    renderDefault field (OmCtor constructor) =
      case (.valueType) field of
        RRef key -> case Map.lookup key declarations of
          Just (ResolvedStructural _ (REnum entries)) ->
            maybe ("ctor:" <> atom constructor) ("enum:" <>) (lookup constructor [((.ctor) entry, atom ((.tag) entry)) | entry <- entries])
          _ -> "ctor:" <> atom constructor
        _ -> "ctor:" <> atom constructor
    renderDefault _ value = T.pack (show value)

    renderUnknown RejectUnknown = "reject"
    renderUnknown IgnoreUnknown = "ignore"
    renderPresence PRequired = "required"
    renderPresence POptional = "optional"
    atom value = T.pack (show value)

fnv1a64 :: Text -> Text
fnv1a64 input =
  let offsetBasis = 14695981039346656037 :: Word64
      prime = 1099511628211 :: Word64
      digest = T.foldl' (\hash char -> (hash `xor` fromIntegral (ord char)) * prime) offsetBasis input
      hexadecimal = showHex digest ""
   in T.pack (replicate (16 - length hexadecimal) '0' <> hexadecimal)
