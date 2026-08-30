{-# OPTIONS_GHC -Werror=incomplete-patterns #-}

-- | Canonical aggregate type resolution and capability policy.
--
-- Parsing a 'TypeExpr' only establishes syntax. This module decides whether that
-- type is legal at an aggregate use site, canonicalizes aliases, validates
-- register initials, and supplies total Haskell lowering for admitted values.
module Keiro.Dsl.AggregateType
  ( AggregateUseSite (..),
    AggregateCapability (..),
    ResolvedAggregateType (..),
    AggregateSymbols,
    aggregateSymbols,
    aggregateSymbolsFromGraph,
    aggregateSymbolsFromGraphResult,
    AggregateTypeErrorReason (..),
    AggregateTypeError (..),
    resolveAggregateType,
    inferAggregateFieldType,
    aggregateCapability,
    aggregateCanonicalName,
    typeExprCanonicalName,
    AggregateHaskellSource,
    aggregateConsumerHaskellSource,
    aggregateSourceReferences,
    aggregateSourceStaticImports,
    renderAggregateHaskellSource,
    aggregatePackages,
    aggregateSampleHaskell,
    ResolvedRegisterInitial (..),
    resolveRegisterInitial,
    renderRegisterInitial,
    registerInitialCanonicalName,
  )
where

import Data.List.NonEmpty qualified as NE
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time.Calendar (toGregorian)
import Data.Time.Clock (UTCTime (..), diffTimeToPicoseconds)
import Data.Time.Format.ISO8601 (iso8601ParseM)
import Keiro.Dsl.Grammar
import Keiro.Dsl.HaskellImport
import Keiro.Dsl.HaskellName qualified as HaskellName
import Keiro.Dsl.NominalType
import Keiro.Dsl.TypeGraph
import Numeric.Natural (Natural)
import Text.Read (readMaybe)

data AggregateUseSite
  = CommandFieldUse
  | EventFieldUse
  | RegisterUse
  | EqualityGuardUse
  | OrderingGuardUse
  | WholeValueWriteUse
  | CodecUse
  | SnapshotUse
  | HarnessSampleUse
  | HaskellLoweringUse
  deriving stock (Eq, Ord, Show, Enum, Bounded)

-- | Whether a use is solver-visible, legal but opaque, or unsupported.
data AggregateCapability = SolverVisible | OpaqueOnly | Unsupported
  deriving stock (Eq, Ord, Show, Enum, Bounded)

data ResolvedAggregateType
  = AggregateText
  | AggregateInt
  | AggregateInteger
  | AggregateBool
  | AggregateTime
  | AggregateNatural
  | AggregateNominal !ResolvedNominalType
  | AggregateVertex !Name
  | AggregateMapped !MappedKey
  deriving stock (Eq, Ord, Show)

data AggregateSymbols = AggregateSymbols
  { nominals :: !(Map Name ResolvedNominalType),
    vertices :: !(Map Name [Name]),
    mapped :: !(Map MappedKey ResolvedMappedDecl)
  }

aggregateSymbols :: Spec -> AggregateSymbols
aggregateSymbols spec =
  aggregateSymbolsFromGraphResult (resolveTypeGraph spec) spec

aggregateSymbolsFromGraph :: TypeGraph -> Spec -> AggregateSymbols
aggregateSymbolsFromGraph graph = aggregateSymbolsFromDeclarations ((.declarations) graph)

aggregateSymbolsFromGraphResult :: Either (NE.NonEmpty TypeGraphError) TypeGraph -> Spec -> AggregateSymbols
aggregateSymbolsFromGraphResult graphResult =
  aggregateSymbolsFromDeclarations (either (const Map.empty) (.declarations) graphResult)

aggregateSymbolsFromDeclarations :: Map MappedKey ResolvedMappedDecl -> Spec -> AggregateSymbols
aggregateSymbolsFromDeclarations mappedDeclarations spec =
  AggregateSymbols
    { nominals = either (const Map.empty) nominalTypes (resolveNominalTypes spec),
      vertices =
        Map.fromList
          [ ((.name) aggregate <> "Vertex", map (.name) ((.states) aggregate))
          | NAggregate aggregate <- (.nodes) spec
          ],
      mapped = mappedDeclarations
    }

data AggregateTypeErrorReason
  = UnknownAggregateType !Name
  | UnsupportedAggregateShape !TypeExpr
  | UnsupportedAggregateCapability !ResolvedAggregateType
  | InvalidRegisterInitial !ResolvedAggregateType !Text
  deriving stock (Eq, Show)

data AggregateTypeError = AggregateTypeError
  { loc :: !Loc,
    useSite :: !AggregateUseSite,
    reason :: !AggregateTypeErrorReason
  }
  deriving stock (Eq, Show)

resolveAggregateType :: AggregateSymbols -> Loc -> AggregateUseSite -> TypeExpr -> Either AggregateTypeError ResolvedAggregateType
resolveAggregateType symbols loc useSite expression = do
  resolved <- case expression of
    TText -> pure AggregateText
    TInt -> pure AggregateInt
    TInteger -> pure AggregateInteger
    TBool -> pure AggregateBool
    TNatural -> pure AggregateNatural
    TTime -> pure AggregateTime
    TJson -> unsupportedShape
    TOptional {} -> unsupportedShape
    TList {} -> unsupportedShape
    TMap {} -> unsupportedShape
    TRef name
      | Just nominal <- Map.lookup name ((.nominals) symbols) -> pure (AggregateNominal nominal)
      | Map.member name ((.vertices) symbols) -> pure (AggregateVertex name)
      | Map.member (MappedKey name) ((.mapped) symbols) -> pure (AggregateMapped (MappedKey name))
      | otherwise -> Left (AggregateTypeError loc useSite (UnknownAggregateType name))
  case aggregateCapability useSite resolved of
    Unsupported -> Left (AggregateTypeError loc useSite (UnsupportedAggregateCapability resolved))
    SolverVisible -> pure resolved
    OpaqueOnly -> pure resolved
  where
    unsupportedShape = Left (AggregateTypeError loc useSite (UnsupportedAggregateShape expression))

inferAggregateFieldType :: AggregateSymbols -> Aggregate -> AggregateUseSite -> AggregateField -> Either AggregateTypeError ResolvedAggregateType
inferAggregateFieldType symbols aggregate useSite field =
  resolveAggregateType symbols ((.loc) field) useSite inferred
  where
    inferred = case (.valueType) field of
      Just expression -> expression
      Nothing -> case [(.valueType) register | register <- (.regs) aggregate, (.name) register == (.name) field] of
        expression : _ -> expression
        [] ->
          let candidate = pascal ((.name) field)
           in if Map.member candidate ((.nominals) symbols)
                || Map.member candidate ((.vertices) symbols)
                || Map.member (MappedKey candidate) ((.mapped) symbols)
                then TRef candidate
                else TText

aggregateCapability :: AggregateUseSite -> ResolvedAggregateType -> AggregateCapability
aggregateCapability useSite resolved = case useSite of
  EqualityGuardUse -> case resolved of
    AggregateMapped {} -> Unsupported
    AggregateNominal nominal -> case (.representation) nominal of
      ScalarRepresentation {} -> SolverVisible
      IdRepresentation {} -> SolverVisible
      EnumRepresentation {} -> SolverVisible
    _ -> solverVisibility resolved
  OrderingGuardUse -> case resolved of
    AggregateInt -> SolverVisible
    AggregateInteger -> SolverVisible
    AggregateTime -> SolverVisible
    AggregateNatural -> SolverVisible
    AggregateNominal nominal -> nominalOrderingCapability nominal
    AggregateText -> Unsupported
    AggregateBool -> Unsupported
    AggregateVertex {} -> Unsupported
    AggregateMapped {} -> Unsupported
  CommandFieldUse -> solverVisibility resolved
  EventFieldUse -> solverVisibility resolved
  RegisterUse -> solverVisibility resolved
  WholeValueWriteUse -> solverVisibility resolved
  CodecUse -> solverVisibility resolved
  SnapshotUse -> solverVisibility resolved
  HarnessSampleUse -> solverVisibility resolved
  HaskellLoweringUse -> solverVisibility resolved

solverVisibility :: ResolvedAggregateType -> AggregateCapability
solverVisibility resolved = case resolved of
  AggregateText -> SolverVisible
  AggregateInt -> SolverVisible
  AggregateInteger -> SolverVisible
  AggregateBool -> SolverVisible
  AggregateTime -> SolverVisible
  AggregateNatural -> SolverVisible
  AggregateNominal nominal -> nominalSolverVisibility nominal
  AggregateVertex {} -> OpaqueOnly
  AggregateMapped {} -> OpaqueOnly

nominalSolverVisibility :: ResolvedNominalType -> AggregateCapability
nominalSolverVisibility nominal = case (.representation) nominal of
  ScalarRepresentation {} -> SolverVisible
  IdRepresentation {} -> OpaqueOnly
  EnumRepresentation {} -> OpaqueOnly

nominalOrderingCapability :: ResolvedNominalType -> AggregateCapability
nominalOrderingCapability nominal = case (.representation) nominal of
  ScalarRepresentation NominalInt -> SolverVisible
  ScalarRepresentation NominalNatural -> SolverVisible
  ScalarRepresentation NominalTime -> SolverVisible
  ScalarRepresentation NominalText -> Unsupported
  ScalarRepresentation NominalBool -> Unsupported
  IdRepresentation {} -> Unsupported
  EnumRepresentation {} -> Unsupported

aggregateCanonicalName :: ResolvedAggregateType -> Text
aggregateCanonicalName resolved = case resolved of
  AggregateText -> "Text"
  AggregateInt -> "Int"
  AggregateInteger -> "Integer"
  AggregateBool -> "Bool"
  AggregateTime -> "Time"
  AggregateNatural -> "Natural"
  AggregateNominal nominal -> (.name) nominal
  AggregateVertex name -> name
  AggregateMapped key -> unMappedKey key

typeExprCanonicalName :: TypeExpr -> Text
typeExprCanonicalName expression = case expression of
  TText -> "Text"
  TInt -> "Int"
  TInteger -> "Integer"
  TBool -> "Bool"
  TNatural -> "Natural"
  TTime -> "Time"
  TJson -> "Json"
  TOptional value -> "Optional(" <> typeExprCanonicalName value <> ")"
  TList value -> "List(" <> typeExprCanonicalName value <> ")"
  TMap value -> "Map(" <> typeExprCanonicalName value <> ")"
  TRef name -> name

data AggregateHaskellSource = AggregateHaskellSource
  { builtin :: !(Maybe Text),
    reference :: !(Maybe HaskellReference),
    staticImports :: !(Set Text)
  }

aggregateConsumerHaskellSource :: AggregateSymbols -> ResolvedAggregateType -> AggregateHaskellSource
aggregateConsumerHaskellSource symbols resolved = case resolved of
  AggregateTime -> builtin "UTCTime" timeImports
  AggregateNatural -> builtin "Natural" (Set.singleton "Numeric.Natural (Natural)")
  AggregateNominal nominal -> case (.ownership) nominal of
    GeneratedNominal -> builtin ((.name) nominal) Set.empty
    ConsumerNominal binding -> external ((.haskell) binding)
  AggregateMapped key -> case Map.lookup key ((.mapped) symbols) of
    Just declaration -> external (mappedHaskell declaration)
    Nothing -> builtin (unMappedKey key) Set.empty
  _ -> builtin (aggregateCanonicalName resolved) Set.empty
  where
    builtin name imports = AggregateHaskellSource (Just name) Nothing imports
    external source =
      AggregateHaskellSource
        Nothing
        (Just (HaskellReference ((.moduleName) source) ((.valueType) source) TypeNamespace PreferUnqualified))
        Set.empty
    mappedHaskell (ResolvedStructural declaration _) = (.haskell) declaration
    mappedHaskell (ResolvedOpaque declaration) = (.haskell) declaration
    timeImports =
      Set.singleton "Data.Time.Clock (UTCTime)"

aggregateSourceReferences :: AggregateHaskellSource -> Set HaskellReference
aggregateSourceReferences source = maybe Set.empty Set.singleton ((.reference) source)

aggregateSourceStaticImports :: AggregateHaskellSource -> Set Text
aggregateSourceStaticImports = (.staticImports)

renderAggregateHaskellSource :: HaskellImportPlan -> AggregateHaskellSource -> Either HaskellImportError Text
renderAggregateHaskellSource plan source = case ((.builtin) source, (.reference) source) of
  (Just builtin, Nothing) -> pure builtin
  (Nothing, Just reference) -> renderPlannedReference plan reference
  _ -> error "invalid aggregate Haskell source description"

aggregatePackages :: AggregateSymbols -> ResolvedAggregateType -> Set Text
aggregatePackages symbols resolved = case resolved of
  AggregateTime -> Set.singleton "time"
  AggregateNominal nominal -> case (.ownership) nominal of
    GeneratedNominal -> Set.empty
    ConsumerNominal binding -> Set.singleton ((.package) ((.haskell) binding))
  AggregateMapped key -> case Map.lookup key ((.mapped) symbols) of
    Just declaration -> Set.singleton ((.package) (mappedHaskell declaration))
    Nothing -> Set.empty
  _ -> Set.empty
  where
    mappedHaskell (ResolvedStructural declaration _) = (.haskell) declaration
    mappedHaskell (ResolvedOpaque declaration) = (.haskell) declaration

aggregateSampleHaskell :: AggregateSymbols -> Text -> ResolvedAggregateType -> Text
aggregateSampleHaskell symbols name resolved = case resolved of
  AggregateText -> tshow ("sample-" <> name)
  AggregateInt -> "0"
  AggregateInteger -> "0"
  AggregateBool -> "False"
  AggregateTime -> "(UTCTime (fromGregorian 2026 1 2) (picosecondsToDiffTime 11045123456789012))"
  AggregateNatural -> "0"
  AggregateNominal nominal -> nominalSample nominal
  AggregateVertex name -> firstConstructor name
  AggregateMapped key -> case Map.lookup key ((.mapped) symbols) of
    Just declaration -> "(snd (NonEmpty.head (fixtureCases " <> unQualifiedValueName (mappedFixtures declaration) <> ")))"
    Nothing -> unMappedKey key <> ".sample"
  where
    firstConstructor name = case Map.lookup name ((.vertices) symbols) of
      Just (constructor : _) -> constructor
      _ -> name
    nominalSample nominal = case (.ownership) nominal of
      ConsumerNominal binding ->
        "(nominalFixtureDomain (NonEmpty.head (nominalFixtureCases "
          <> unQualifiedValueName ((.fixtures) binding)
          <> ")))"
      GeneratedNominal -> case (.representation) nominal of
        IdRepresentation {} -> "(" <> (.name) nominal <> " \"sample\")"
        EnumRepresentation constructors -> fst (NE.head constructors)
        ScalarRepresentation {} -> (.name) nominal <> ".sample"
    mappedFixtures (ResolvedStructural declaration _) = (.fixtures) declaration
    mappedFixtures (ResolvedOpaque declaration) = (.fixtures) declaration

data ResolvedRegisterInitial
  = InitialText !Text
  | InitialInt !Int
  | InitialInteger !Integer
  | InitialBool !Bool
  | InitialTime !UTCTime
  | InitialNatural !Natural
  | InitialId !Name
  | InitialNamed !ResolvedAggregateType !Name
  | InitialNominal !Name !QualifiedValueName
  | InitialMapped !MappedKey !QualifiedValueName
  deriving stock (Eq, Show)

resolveRegisterInitial :: AggregateSymbols -> Loc -> ResolvedAggregateType -> RegInitial -> Either AggregateTypeError ResolvedRegisterInitial
resolveRegisterInitial symbols loc resolved syntax = case resolved of
  AggregateText -> case syntax of
    RegInitText value -> pure (InitialText value)
    RegInitBare _ -> invalid "Text initials must be quoted"
  AggregateInt -> case syntax of
    RegInitBare value -> maybe (invalid "Int initials must be integral literals in the Haskell Int range") (pure . InitialInt) (readMaybe (T.unpack value))
    RegInitText _ -> invalid "Int initials must be unquoted integral literals"
  AggregateInteger -> case syntax of
    RegInitBare value -> maybe (invalid "Integer initials must be integral literals") (pure . InitialInteger) (readMaybe (T.unpack value))
    RegInitText _ -> invalid "Integer initials must be unquoted integral literals"
  AggregateBool -> case syntax of
    RegInitBare "True" -> pure (InitialBool True)
    RegInitBare "False" -> pure (InitialBool False)
    _ -> invalid "Bool initials must be True or False"
  AggregateTime -> case syntax of
    RegInitText value -> maybe (invalid "Time initials must be valid quoted ISO-8601 UTC timestamps") (pure . InitialTime) (iso8601ParseM (T.unpack value))
    RegInitBare _ -> invalid "Time initials must be quoted ISO-8601 UTC timestamps"
  AggregateNatural -> case syntax of
    RegInitBare value -> case readMaybe (T.unpack value) :: Maybe Integer of
      Just number | number >= 0 -> pure (InitialNatural (fromInteger number))
      _ -> invalid "Natural initials must be non-negative integral literals"
    RegInitText _ -> invalid "Natural initials must be unquoted non-negative integral literals"
  AggregateNominal nominal -> case (.ownership) nominal of
    ConsumerNominal binding -> case syntax of
      RegInitBare "initial" -> case (.initial) binding of
        Just value -> pure (InitialNominal ((.name) nominal) value)
        Nothing -> invalid "consumer-owned nominal register type must declare an initial symbol"
      _ -> invalid "consumer-owned nominal register initials must use the bare initial token"
    GeneratedNominal -> case (.representation) nominal of
      IdRepresentation {} -> case syntax of
        RegInitBare "placeholder" -> pure (InitialId ((.name) nominal))
        _ -> invalid "ID initials must use placeholder"
      EnumRepresentation constructors -> namedInitial ((.name) nominal) (Just (map fst (NE.toList constructors)))
      ScalarRepresentation {} -> invalid "generated nominal scalars are unsupported"
  AggregateVertex name -> namedInitial name (Map.lookup name ((.vertices) symbols))
  AggregateMapped key -> case syntax of
    RegInitBare "initial" -> case Map.lookup key ((.mapped) symbols) >>= mappedInitial of
      Just value -> pure (InitialMapped key value)
      Nothing -> invalid "mapped register type must declare an initial symbol"
    _ -> invalid "mapped register initials must use the bare initial token"
  where
    invalid detail = Left (AggregateTypeError loc RegisterUse (InvalidRegisterInitial resolved detail))
    namedInitial name constructors = case syntax of
      RegInitBare constructor | maybe False (constructor `elem`) constructors -> pure (InitialNamed resolved constructor)
      _ -> invalid ("initial must name a constructor of " <> name)
    mappedInitial (ResolvedStructural declaration _) = (.initial) declaration
    mappedInitial (ResolvedOpaque declaration) = (.initial) declaration

renderRegisterInitial :: ResolvedRegisterInitial -> Text
renderRegisterInitial initial = case initial of
  InitialText value -> tshow value
  InitialInt value -> T.pack (show value)
  InitialInteger value -> T.pack (show value)
  InitialBool value -> if value then "True" else "False"
  InitialTime value ->
    let (year, month, day) = toGregorian (utctDay value)
        picoseconds = diffTimeToPicoseconds (utctDayTime value)
     in "(UTCTime (fromGregorian "
          <> T.pack (show year)
          <> " "
          <> T.pack (show month)
          <> " "
          <> T.pack (show day)
          <> ") (picosecondsToDiffTime "
          <> T.pack (show picoseconds)
          <> "))"
  InitialNatural value -> T.pack (show value)
  InitialId name -> "(" <> name <> " \"\")"
  InitialNamed resolved constructor -> case resolved of
    AggregateVertex vertexType -> T.dropEnd (T.length ("Vertex" :: Text)) vertexType <> constructor
    _ -> constructor
  InitialNominal _ value -> unQualifiedValueName value
  InitialMapped _ value -> unQualifiedValueName value

registerInitialCanonicalName :: ResolvedRegisterInitial -> Text
registerInitialCanonicalName initial = case initial of
  InitialText value -> tshow value
  InitialInt value -> T.pack (show value)
  InitialInteger value -> T.pack (show value)
  InitialBool value -> if value then "True" else "False"
  InitialTime {} -> renderRegisterInitial initial
  InitialNatural value -> T.pack (show value)
  InitialId {} -> "placeholder"
  InitialNamed _ constructor -> constructor
  InitialNominal {} -> "initial"
  InitialMapped {} -> "initial"

pascal :: Text -> Text
pascal value =
  case HaskellName.deriveHaskellName HaskellName.LogicalIdentifier site of
    Right derived -> HaskellName.renderUpperCamelName ((.upperCamel) derived)
    Left _ -> value
  where
    site =
      HaskellName.NameSite
        { HaskellName.kind = HaskellName.GeneratedTypeSite,
          HaskellName.logicalName = value,
          HaskellName.owner = "aggregate-type",
          HaskellName.line = 0
        }

tshow :: Text -> Text
tshow = T.pack . show
