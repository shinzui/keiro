{-# OPTIONS_GHC -Werror=incomplete-patterns #-}

{- | Canonical aggregate type resolution and capability policy.

Parsing a 'TypeExpr' only establishes syntax. This module decides whether that
type is legal at an aggregate use site, canonicalizes aliases, validates
register initials, and supplies total Haskell lowering for admitted values.
-}
module Keiro.Dsl.AggregateType (
    AggregateUseSite (..),
    AggregateCapability (..),
    ResolvedAggregateType (..),
    AggregateSymbols,
    aggregateSymbols,
    AggregateTypeErrorReason (..),
    AggregateTypeError (..),
    resolveAggregateType,
    inferAggregateFieldType,
    aggregateCapability,
    aggregateCanonicalName,
    typeExprCanonicalName,
    aggregateHaskellType,
    aggregateImports,
    aggregatePackages,
    aggregateSampleHaskell,
    ResolvedRegisterInitial (..),
    resolveRegisterInitial,
    renderRegisterInitial,
    registerInitialCanonicalName,
) where

import Control.Applicative ((<|>))
import Data.Char (toUpper)
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
    | AggregateBool
    | AggregateTime
    | AggregateNatural
    | AggregateId !Name
    | AggregateEnum !Name
    | AggregateVertex !Name
    | AggregateMapped !MappedKey
    deriving stock (Eq, Ord, Show)

data AggregateSymbols = AggregateSymbols
    { symbolIds :: !(Set Name)
    , symbolEnums :: !(Map Name [Name])
    , symbolVertices :: !(Map Name [Name])
    , symbolMapped :: !(Map MappedKey ResolvedMappedDecl)
    , symbolMappedNames :: !(Set Name)
    }

aggregateSymbols :: Spec -> AggregateSymbols
aggregateSymbols spec =
    AggregateSymbols
        { symbolIds = Set.fromList (map idName (specIds spec))
        , symbolEnums = Map.fromList [(enumName declaration, map fst (enumCtors declaration)) | declaration <- specEnums spec]
        , symbolVertices =
            Map.fromList
                [ (aggName aggregate <> "Vertex", map stName (aggStates aggregate))
                | NAggregate aggregate <- specNodes spec
                ]
        , symbolMapped = either (const Map.empty) tgDeclarations (resolveTypeGraph spec)
        , symbolMappedNames = Set.fromList (map mappedName (specMapped spec))
        }
  where
    mappedName MappedStructural{msName = name} = name
    mappedName MappedOpaque{moName = name} = name

data AggregateTypeErrorReason
    = UnknownAggregateType !Name
    | UnsupportedAggregateShape !TypeExpr
    | UnsupportedAggregateCapability !ResolvedAggregateType
    | InvalidRegisterInitial !ResolvedAggregateType !Text
    deriving stock (Eq, Show)

data AggregateTypeError = AggregateTypeError
    { aggregateTypeErrorLoc :: !Loc
    , aggregateTypeErrorUseSite :: !AggregateUseSite
    , aggregateTypeErrorReason :: !AggregateTypeErrorReason
    }
    deriving stock (Eq, Show)

resolveAggregateType :: AggregateSymbols -> Loc -> AggregateUseSite -> TypeExpr -> Either AggregateTypeError ResolvedAggregateType
resolveAggregateType symbols loc useSite expression = do
    resolved <- case expression of
        TText -> pure AggregateText
        TInt -> pure AggregateInt
        TBool -> pure AggregateBool
        TNatural -> pure AggregateNatural
        TTime -> pure AggregateTime
        TJson -> unsupportedShape
        TOptional{} -> unsupportedShape
        TList{} -> unsupportedShape
        TMap{} -> unsupportedShape
        TRef name
            | name `Set.member` symbolIds symbols -> pure (AggregateId name)
            | Map.member name (symbolEnums symbols) -> pure (AggregateEnum name)
            | Map.member name (symbolVertices symbols) -> pure (AggregateVertex name)
            | name `Set.member` symbolMappedNames symbols -> pure (AggregateMapped (MappedKey name))
            | otherwise -> Left (AggregateTypeError loc useSite (UnknownAggregateType name))
    case aggregateCapability useSite resolved of
        Unsupported -> Left (AggregateTypeError loc useSite (UnsupportedAggregateCapability resolved))
        SolverVisible -> pure resolved
        OpaqueOnly -> pure resolved
  where
    unsupportedShape = Left (AggregateTypeError loc useSite (UnsupportedAggregateShape expression))

inferAggregateFieldType :: AggregateSymbols -> Aggregate -> AggregateUseSite -> AggregateField -> Either AggregateTypeError ResolvedAggregateType
inferAggregateFieldType symbols aggregate useSite field =
    resolveAggregateType symbols (aggregateFieldLoc field) useSite inferred
  where
    inferred = case aggregateFieldType field of
        Just expression -> expression
        Nothing -> case [regType register | register <- aggRegs aggregate, regName register == aggregateFieldName field] of
            expression : _ -> expression
            [] ->
                let candidate = pascal (aggregateFieldName field)
                 in if candidate `Set.member` symbolIds symbols
                        || Map.member candidate (symbolEnums symbols)
                        || Map.member candidate (symbolVertices symbols)
                        || candidate `Set.member` symbolMappedNames symbols
                        then TRef candidate
                        else TText

aggregateCapability :: AggregateUseSite -> ResolvedAggregateType -> AggregateCapability
aggregateCapability useSite resolved = case useSite of
    EqualityGuardUse -> case resolved of
        AggregateMapped{} -> Unsupported
        _ -> solverVisibility resolved
    OrderingGuardUse -> case resolved of
        AggregateInt -> SolverVisible
        AggregateTime -> SolverVisible
        AggregateNatural -> SolverVisible
        AggregateText -> Unsupported
        AggregateBool -> Unsupported
        AggregateId{} -> Unsupported
        AggregateEnum{} -> Unsupported
        AggregateVertex{} -> Unsupported
        AggregateMapped{} -> Unsupported
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
    AggregateBool -> SolverVisible
    AggregateTime -> SolverVisible
    AggregateNatural -> SolverVisible
    AggregateId{} -> OpaqueOnly
    AggregateEnum{} -> OpaqueOnly
    AggregateVertex{} -> OpaqueOnly
    AggregateMapped{} -> OpaqueOnly

aggregateCanonicalName :: ResolvedAggregateType -> Text
aggregateCanonicalName resolved = case resolved of
    AggregateText -> "Text"
    AggregateInt -> "Int"
    AggregateBool -> "Bool"
    AggregateTime -> "Time"
    AggregateNatural -> "Natural"
    AggregateId name -> name
    AggregateEnum name -> name
    AggregateVertex name -> name
    AggregateMapped key -> unMappedKey key

typeExprCanonicalName :: TypeExpr -> Text
typeExprCanonicalName expression = case expression of
    TText -> "Text"
    TInt -> "Int"
    TBool -> "Bool"
    TNatural -> "Natural"
    TTime -> "Time"
    TJson -> "Json"
    TOptional value -> "Optional(" <> typeExprCanonicalName value <> ")"
    TList value -> "List(" <> typeExprCanonicalName value <> ")"
    TMap value -> "Map(" <> typeExprCanonicalName value <> ")"
    TRef name -> name

aggregateHaskellType :: AggregateSymbols -> ResolvedAggregateType -> Text
aggregateHaskellType symbols resolved = case resolved of
    AggregateTime -> "UTCTime"
    AggregateMapped key -> case Map.lookup key (symbolMapped symbols) of
        Just declaration -> renderHaskellSource (mappedHaskell declaration)
        Nothing -> unMappedKey key
    _ -> aggregateCanonicalName resolved
  where
    mappedHaskell (ResolvedStructural declaration _) = sdHaskell declaration
    mappedHaskell (ResolvedOpaque declaration) = odHaskell declaration
    renderHaskellSource source = hsModule source <> "." <> hsType source

aggregateImports :: AggregateSymbols -> ResolvedAggregateType -> Set Text
aggregateImports symbols resolved = case resolved of
    AggregateTime ->
        Set.fromList
            [ "Data.Time.Calendar (fromGregorian)"
            , "Data.Time.Clock (UTCTime(..), picosecondsToDiffTime)"
            ]
    AggregateNatural -> Set.singleton "Numeric.Natural (Natural)"
    AggregateMapped key -> case Map.lookup key (symbolMapped symbols) of
        Just declaration -> Set.singleton (hsModule (mappedHaskell declaration) <> " qualified")
        Nothing -> Set.empty
    _ -> Set.empty
  where
    mappedHaskell (ResolvedStructural declaration _) = sdHaskell declaration
    mappedHaskell (ResolvedOpaque declaration) = odHaskell declaration

aggregatePackages :: AggregateSymbols -> ResolvedAggregateType -> Set Text
aggregatePackages symbols resolved = case resolved of
    AggregateTime -> Set.singleton "time"
    AggregateMapped key -> case Map.lookup key (symbolMapped symbols) of
        Just declaration -> Set.singleton (hsPackage (mappedHaskell declaration))
        Nothing -> Set.empty
    _ -> Set.empty
  where
    mappedHaskell (ResolvedStructural declaration _) = sdHaskell declaration
    mappedHaskell (ResolvedOpaque declaration) = odHaskell declaration

aggregateSampleHaskell :: AggregateSymbols -> Text -> ResolvedAggregateType -> Text
aggregateSampleHaskell symbols fieldName resolved = case resolved of
    AggregateText -> tshow ("sample-" <> fieldName)
    AggregateInt -> "0"
    AggregateBool -> "False"
    AggregateTime -> "(UTCTime (fromGregorian 2026 1 2) (picosecondsToDiffTime 11045123456789012))"
    AggregateNatural -> "0"
    AggregateId name -> "(" <> name <> " \"sample\")"
    AggregateEnum name -> firstConstructor name
    AggregateVertex name -> firstConstructor name
    AggregateMapped key -> case Map.lookup key (symbolMapped symbols) of
        Just declaration -> "(snd (NonEmpty.head (fixtureCases " <> unQualifiedValueName (mappedFixtures declaration) <> ")))"
        Nothing -> unMappedKey key <> ".sample"
  where
    firstConstructor name = case Map.lookup name (symbolEnums symbols) <|> Map.lookup name (symbolVertices symbols) of
        Just (constructor : _) -> constructor
        _ -> name
    mappedFixtures (ResolvedStructural declaration _) = sdFixtures declaration
    mappedFixtures (ResolvedOpaque declaration) = odFixtures declaration

data ResolvedRegisterInitial
    = InitialText !Text
    | InitialInt !Int
    | InitialBool !Bool
    | InitialTime !UTCTime
    | InitialNatural !Natural
    | InitialId !Name
    | InitialNamed !ResolvedAggregateType !Name
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
    AggregateId name -> case syntax of
        RegInitBare "placeholder" -> pure (InitialId name)
        _ -> invalid "ID initials must use placeholder"
    AggregateEnum name -> namedInitial name (Map.lookup name (symbolEnums symbols))
    AggregateVertex name -> namedInitial name (Map.lookup name (symbolVertices symbols))
    AggregateMapped key -> case syntax of
        RegInitBare "initial" -> case Map.lookup key (symbolMapped symbols) >>= mappedInitial of
            Just value -> pure (InitialMapped key value)
            Nothing -> invalid "mapped register type must declare an initial symbol"
        _ -> invalid "mapped register initials must use the bare initial token"
  where
    invalid detail = Left (AggregateTypeError loc RegisterUse (InvalidRegisterInitial resolved detail))
    namedInitial name constructors = case syntax of
        RegInitBare constructor | maybe False (constructor `elem`) constructors -> pure (InitialNamed resolved constructor)
        _ -> invalid ("initial must name a constructor of " <> name)
    mappedInitial (ResolvedStructural declaration _) = sdInitial declaration
    mappedInitial (ResolvedOpaque declaration) = odInitial declaration

renderRegisterInitial :: ResolvedRegisterInitial -> Text
renderRegisterInitial initial = case initial of
    InitialText value -> tshow value
    InitialInt value -> T.pack (show value)
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
    InitialMapped _ value -> unQualifiedValueName value

registerInitialCanonicalName :: ResolvedRegisterInitial -> Text
registerInitialCanonicalName initial = case initial of
    InitialText value -> tshow value
    InitialInt value -> T.pack (show value)
    InitialBool value -> if value then "True" else "False"
    InitialTime{} -> renderRegisterInitial initial
    InitialNatural value -> T.pack (show value)
    InitialId{} -> "placeholder"
    InitialNamed _ constructor -> constructor
    InitialMapped{} -> "initial"

pascal :: Text -> Text
pascal value = case T.uncons value of
    Just (first, rest) -> T.cons (toUpper first) rest
    Nothing -> value

tshow :: Text -> Text
tshow = T.pack . show
