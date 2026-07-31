{-# OPTIONS_GHC -Werror=incomplete-patterns #-}

-- | Checked, resolved consumer-owned mapped types. Parser declarations keep
-- mandatory facts optional so diagnostics can name omissions; this module is
-- the phase boundary after which missing facts and unresolved references are
-- unrepresentable.
module Keiro.Dsl.TypeGraph
  ( QualifiedValueName (..),
    CanonicalTypeId (..),
    BindingVersion (..),
    CodecIdentity (..),
    CodecVersion (..),
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
    ResolvedTypeExpr (..),
    ResolvedWireField (..),
    ResolvedWireArm (..),
    ResolvedMappedShape (..),
    ResolvedMappedDecl (..),
    TypeGraphError (..),
    TypeGraph (..),
    UseSite (..),
    PathSeg (..),
    UsePath (..),
    resolveTypeGraph,
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
import Data.List (sortOn)
import Data.List.NonEmpty (NonEmpty (..))
import Data.List.NonEmpty qualified as NE
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
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

newtype CanonicalTypeId = CanonicalTypeId {unCanonicalTypeId :: Text}
  deriving stock (Eq, Ord, Show, Generic)

newtype BindingVersion = BindingVersion {unBindingVersion :: Text}
  deriving stock (Eq, Ord, Show, Generic)

newtype CodecIdentity = CodecIdentity {unCodecIdentity :: Text}
  deriving stock (Eq, Ord, Show, Generic)

newtype CodecVersion = CodecVersion {unCodecVersion :: Text}
  deriving stock (Eq, Ord, Show, Generic)

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
  { sdName :: !Name,
    sdHaskell :: !HaskellSource,
    sdBinding :: !QualifiedValueName,
    sdBindingVersion :: !BindingVersion,
    sdCanonical :: !CanonicalTypeId,
    sdFixtures :: !QualifiedValueName,
    sdInitial :: !(Maybe QualifiedValueName),
    sdLoc :: !Loc
  }
  deriving stock (Eq, Show, Generic)

data OpaqueDecl = OpaqueDecl
  { odName :: !Name,
    odHaskell :: !HaskellSource,
    odCodecIdentity :: !CodecIdentity,
    odCodecVersion :: !CodecVersion,
    odFixtures :: !QualifiedValueName,
    odInitial :: !(Maybe QualifiedValueName),
    odLoc :: !Loc
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
          { sdName = name,
            sdHaskell = checkedHaskell,
            sdBinding = checkedBinding,
            sdBindingVersion = checkedBindingVersion,
            sdCanonical = checkedCanonical,
            sdFixtures = checkedFixtures,
            sdInitial = checkedInitial,
            sdLoc = loc
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
          { odName = name,
            odHaskell = checkedHaskell,
            odCodecIdentity = checkedCodecIdentity,
            odCodecVersion = checkedCodecVersion,
            odFixtures = checkedFixtures,
            odInitial = checkedInitial,
            odLoc = loc
          }
    )

require :: e -> Maybe a -> Either (NonEmpty e) a
require err = maybe (Left (err :| [])) Right

liftOne :: Either e a -> Either (NonEmpty e) a
liftOne = first (:| [])

newtype MappedKey = MappedKey {unMappedKey :: Name}
  deriving stock (Eq, Ord, Show, Generic)

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
  { rwfHaskell :: !Name,
    rwfKey :: !Text,
    rwfType :: !ResolvedTypeExpr,
    rwfPresence :: !Presence,
    rwfOnMissing :: !(Maybe OnMissing),
    rwfLoc :: !Loc
  }
  deriving stock (Eq, Show, Generic)

data ResolvedWireArm = ResolvedWireArm
  { rwaCtor :: !Name,
    rwaTag :: !Text,
    rwaPayload :: !(Maybe ResolvedTypeExpr),
    rwaLoc :: !Loc
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
  | TGRecursive ![Name]
  deriving stock (Eq, Show, Generic)

data UseSite
  = RootCommandField !Name !Name !Name !MappedKey
  | RootEventField !Name !Name !Name !MappedKey
  | RootRegister !Name !Name !MappedKey
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
  { upRoot :: !UseSite,
    upSegments :: ![PathSeg]
  }
  deriving stock (Eq, Ord, Show, Generic)

data TypeGraph = TypeGraph
  { tgDeclarations :: !(Map MappedKey ResolvedMappedDecl),
    tgReachability :: !(Map MappedKey (Set MappedKey)),
    tgUseSites :: ![UseSite]
  }
  deriving stock (Eq, Show, Generic)

resolveTypeGraph :: Spec -> Either (NonEmpty TypeGraphError) TypeGraph
resolveTypeGraph spec = do
  checked <- collectChecked (specMapped spec)
  rejectMany (ambiguityErrors spec checked)
  let keyByName = Map.fromList [(checkedName decl, MappedKey (checkedName decl)) | decl <- checked]
      (resolveErrors, resolvedPairs) = partitionEithers (map (resolveCheckedDecl keyByName) checked)
  rejectMany resolveErrors
  let declarations = Map.fromList resolvedPairs
  rejectMany (cycleErrors declarations)
  let reachability = Map.mapWithKey (reachableFrom declarations) declarations
  pure
    TypeGraph
      { tgDeclarations = declarations,
        tgReachability = reachability,
        tgUseSites = collectUseSites keyByName spec
      }

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
checkedName (CheckedStructural declaration _) = sdName declaration
checkedName (CheckedOpaque declaration) = odName declaration

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
        ++ [(idName declaration, "id") | declaration <- specIds spec]
        ++ [(enumName declaration, "enum") | declaration <- specEnums spec]
        ++ [(name, "built-in") | name <- builtins]
    allOrigins = Map.fromListWith (++) [(name, [origin]) | (name, origin) <- originPairs]

resolveCheckedDecl :: Map Name MappedKey -> CheckedMappedDecl -> Either TypeGraphError (MappedKey, ResolvedMappedDecl)
resolveCheckedDecl _ (CheckedOpaque declaration) =
  Right (MappedKey (odName declaration), ResolvedOpaque declaration)
resolveCheckedDecl keyByName (CheckedStructural declaration shape) = do
  resolvedShape <- resolveShape keyByName (sdName declaration) shape
  pure (MappedKey (sdName declaration), ResolvedStructural declaration resolvedShape)

resolveShape :: Map Name MappedKey -> Name -> MappedShape -> Either TypeGraphError ResolvedMappedShape
resolveShape keyByName owner (ShapeRecord constructor unknownFields fields) =
  RRecord constructor unknownFields <$> traverse resolveField fields
  where
    resolveField field =
      ResolvedWireField
        (wfHaskell field)
        (wfKey field)
        <$> resolveExpr keyByName owner (wireFieldLoc field) (wfType field)
        <*> pure (wfPresence field)
        <*> pure (wfOnMissing field)
        <*> pure (wireFieldLoc field)
resolveShape _ _ (ShapeEnum entries) = Right (REnum entries)
resolveShape keyByName owner (ShapeUnion encoding arms) =
  RUnion encoding <$> traverse resolveArm arms
  where
    resolveArm arm =
      ResolvedWireArm
        (waCtor arm)
        (waTag arm)
        <$> traverse (resolveExpr keyByName owner (waLoc arm)) (waPayload arm)
        <*> pure (waLoc arm)

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
      { onRecord = \_ _ fields -> Set.unions (map (refsInExpr . rwfType) fields),
        onEnum = const Set.empty,
        onUnion = \_ arms -> Set.unions (map (maybe Set.empty refsInExpr . rwaPayload) arms)
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

collectUseSites :: Map Name MappedKey -> Spec -> [UseSite]
collectUseSites keyByName spec = concatMap aggregateSites [aggregate | NAggregate aggregate <- specNodes spec]
  where
    aggregateSites aggregate =
      [ RootCommandField (aggName aggregate) (cmdName command) (aggregateFieldName field) key
      | command <- aggCommands aggregate,
        field <- cmdFields command,
        key <- maybeToList (aggregateFieldType field >>= typeRefName >>= (`Map.lookup` keyByName))
      ]
        ++ [ RootEventField (aggName aggregate) (evName event) (aggregateFieldName field) key
           | event <- aggEvents aggregate,
             field <- eventFields aggregate event,
             key <- maybeToList (aggregateFieldType field >>= typeRefName >>= (`Map.lookup` keyByName))
           ]
        ++ [ RootRegister (aggName aggregate) (regName register) key
           | register <- aggRegs aggregate,
             key <- maybeToList (typeRefName (regType register) >>= (`Map.lookup` keyByName))
           ]

    eventFields aggregate event = case evBody event of
      EventFields fields -> fields
      EventFromCommand commandName ->
        concat [cmdFields command | command <- aggCommands aggregate, cmdName command == commandName]

    maybeToList = maybe [] pure
    typeRefName (TRef name) = Just name
    typeRefName _ = Nothing

usePaths :: TypeGraph -> Name -> [UsePath]
usePaths graph targetName = case Map.lookup (MappedKey targetName) (tgDeclarations graph) of
  Nothing -> []
  Just _ ->
    [ UsePath site segments
    | site <- tgUseSites graph,
      segments <- sitePaths site
    ]
  where
    target = MappedKey targetName
    sitePaths site
      | siteKey site == target = [[]]
      | otherwise = pathsFromDecl Set.empty (siteKey site)

    pathsFromDecl visited current
      | current `Set.member` visited = []
      | otherwise = case Map.lookup current (tgDeclarations graph) of
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
                [ map (SegField (rwfHaskell field) (rwfKey field) :) (pathsInExpr visited (rwfType field))
                | field <- fields
                ],
            onEnum = const [],
            onUnion = \_ arms ->
              concat
                [ map (SegArm (rwaCtor arm) (rwaTag arm) :) (maybe [] (pathsInExpr visited) (rwaPayload arm))
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

renderUsePath :: UsePath -> Text
renderUsePath (UsePath root segments) = renderRoot root <> T.concat (map renderSegment segments)
  where
    renderRoot (RootCommandField aggregate command field key) =
      aggregate <> " command " <> command <> " ." <> field <> " : " <> unMappedKey key
    renderRoot (RootEventField aggregate event field key) =
      aggregate <> " event " <> event <> " ." <> field <> " : " <> unMappedKey key
    renderRoot (RootRegister aggregate register key) =
      aggregate <> " register " <> register <> " : " <> unMappedKey key

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
  RText -> onText algebra
  RInt -> onInt algebra
  RInteger -> onInteger algebra
  RBool -> onBool algebra
  RNatural -> onNatural algebra
  RTime -> onTime algebra
  RJson -> onJson algebra
  ROptional value -> onOptional algebra (foldTypeExpr algebra value)
  RList value -> onList algebra (foldTypeExpr algebra value)
  RMap value -> onMap algebra (foldTypeExpr algebra value)
  RRef key -> onRef algebra key

data MappedShapeAlgebra a = MappedShapeAlgebra
  { onRecord :: Name -> UnknownFields -> [ResolvedWireField] -> a,
    onEnum :: [WireEnum] -> a,
    onUnion :: UnionEncoding -> [ResolvedWireArm] -> a
  }

foldMappedShape :: MappedShapeAlgebra a -> ResolvedMappedShape -> a
foldMappedShape algebra = \case
  RRecord constructor unknownFields fields -> onRecord algebra constructor unknownFields fields
  REnum entries -> onEnum algebra entries
  RUnion encoding arms -> onUnion algebra encoding arms

data MappedDeclAlgebra a = MappedDeclAlgebra
  { onStructuralDecl :: StructuralDecl -> ResolvedMappedShape -> a,
    onOpaqueDecl :: OpaqueDecl -> a
  }

foldMappedDecl :: MappedDeclAlgebra a -> ResolvedMappedDecl -> a
foldMappedDecl algebra = \case
  ResolvedStructural declaration shape -> onStructuralDecl algebra declaration shape
  ResolvedOpaque declaration -> onOpaqueDecl algebra declaration

wireFingerprint :: TypeGraph -> Name -> Text
wireFingerprint graph name = fnv1a64 (wireDecl Set.empty (MappedKey name))
  where
    declarations = tgDeclarations graph

    wireDecl visited key
      | key `Set.member` visited = "recursive"
      | otherwise = case Map.lookup key declarations of
          Nothing -> "missing:" <> unMappedKey key
          Just declaration ->
            foldMappedDecl
              MappedDeclAlgebra
                { onStructuralDecl = \_ shape -> wireShape (Set.insert key visited) shape,
                  onOpaqueDecl = \opaque ->
                    "opaque(" <> atom (unCodecIdentity (odCodecIdentity opaque)) <> "," <> atom (unCodecVersion (odCodecVersion opaque)) <> ")"
                }
              declaration

    wireShape visited =
      foldMappedShape
        MappedShapeAlgebra
          { onRecord = \_ unknownFields fields ->
              "record(" <> renderUnknown unknownFields <> ";" <> T.intercalate ";" (map (wireField visited) (sortOn rwfKey fields)) <> ")",
            onEnum = \entries ->
              "enum(" <> T.intercalate ";" (map (atom . weTag) (sortOn weTag entries)) <> ")",
            onUnion = \encoding arms ->
              "union("
                <> atom (ueTagField encoding)
                <> ","
                <> atom (ueContentsField encoding)
                <> ","
                <> renderUnknown (ueUnknownFields encoding)
                <> ";"
                <> T.intercalate ";" (map (wireArm visited) (sortOn rwaTag arms))
                <> ")"
          }

    wireField visited field =
      atom (rwfKey field)
        <> ":"
        <> wireExpr visited (rwfType field)
        <> ":"
        <> renderPresence (rwfPresence field)
        <> ":"
        <> maybe "none" (renderDefault field) (rwfOnMissing field)

    wireArm visited arm = atom (rwaTag arm) <> maybe ":unit" ((":" <>) . wireExpr visited) (rwaPayload arm)

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
      case rwfType field of
        RRef key -> case Map.lookup key declarations of
          Just (ResolvedStructural _ (REnum entries)) ->
            maybe ("ctor:" <> atom constructor) ("enum:" <>) (lookup constructor [(weCtor entry, atom (weTag entry)) | entry <- entries])
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
