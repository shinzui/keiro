{-# OPTIONS_GHC -Werror=incomplete-patterns #-}

-- | The authoritative version-2 aggregate scalar-expression resolver.
--
-- The parser records syntax and exact rows. This module resolves every root,
-- required structural path, literal, and operator once, retaining the evidence
-- needed by generated Keiki lowering. It deliberately has no evaluator: Keiki's
-- structural term tree remains the one production meaning for concrete and
-- symbolic execution.
module Keiro.Dsl.Expression
  ( ExpressionEnvironment,
    expressionEnvironment,
    expressionEnvironmentFromGraph,
    expressionEnvironmentFromGraphResult,
    expressionEnvironmentWith,
    ExpectedScalarType (..),
    ScalarRootProvenance (..),
    ResolvedScalarProjection (..),
    ArithmeticEvidence (..),
    ScalarValue (..),
    TypedScalarNode (..),
    TypedScalarExpr (..),
    ExpressionDiagnosticCode (..),
    ExpressionDiagnostic (..),
    resolveScalarExpr,
    resolveGuardExpr,
    resolveWriteExpr,
  )
where

import Data.List (find)
import Data.List.NonEmpty (NonEmpty (..))
import Data.List.NonEmpty qualified as NE
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time.Clock (UTCTime)
import Data.Time.Format.ISO8601 (iso8601ParseM)
import Data.TypeID qualified as TypeID
import Keiro.Dsl.AggregateType
import Keiro.Dsl.Grammar
import Keiro.Dsl.TypeGraph

data ExpressionEnvironment = ExpressionEnvironment
  { environmentSpec :: !Spec,
    environmentAggregate :: !Aggregate,
    environmentTransition :: !Transition,
    environmentSymbols :: !AggregateSymbols,
    environmentTypeGraph :: !(Maybe TypeGraph)
  }

expressionEnvironment :: Spec -> Aggregate -> Transition -> ExpressionEnvironment
expressionEnvironment spec = expressionEnvironmentFromGraphResult (resolveTypeGraph spec) spec

expressionEnvironmentFromGraph :: TypeGraph -> Spec -> Aggregate -> Transition -> ExpressionEnvironment
expressionEnvironmentFromGraph graph = expressionEnvironmentFromGraphResult (Right graph)

expressionEnvironmentFromGraphResult :: Either (NonEmpty TypeGraphError) TypeGraph -> Spec -> Aggregate -> Transition -> ExpressionEnvironment
expressionEnvironmentFromGraphResult typeGraphResult spec aggregate transition =
  expressionEnvironmentWith
    (aggregateSymbolsFromGraphResult typeGraphResult spec)
    (either (const Nothing) Just typeGraphResult)
    spec
    aggregate
    transition

expressionEnvironmentWith :: AggregateSymbols -> Maybe TypeGraph -> Spec -> Aggregate -> Transition -> ExpressionEnvironment
expressionEnvironmentWith symbols graph spec aggregate transition =
  ExpressionEnvironment
    { environmentSpec = spec,
      environmentAggregate = aggregate,
      environmentTransition = transition,
      environmentSymbols = symbols,
      environmentTypeGraph = graph
    }

data ExpectedScalarType
  = InferScalarType
  | ExpectScalarType !ResolvedAggregateType
  deriving stock (Eq, Show)

data ScalarRootProvenance
  = ScalarRegisterRoot !Name !ResolvedAggregateType
  | ScalarCommandRoot !Name !ResolvedAggregateType
  deriving stock (Eq, Show)

data ResolvedScalarProjection = ResolvedScalarProjection
  { scalarProjectionOwner :: !MappedKey,
    scalarProjectionPointer :: !Text,
    scalarProjectionFields :: ![Name]
  }
  deriving stock (Eq, Show)

data ArithmeticEvidence
  = ExactIntegerArithmetic
  | TotalNaturalArithmetic
  deriving stock (Eq, Ord, Show)

data ScalarValue
  = ScalarTextValue !Text
  | ScalarIntValue !Int
  | ScalarIntegerValue !Integer
  | ScalarNaturalValue !Integer
  | ScalarBoolValue !Bool
  | ScalarTimeValue !UTCTime
  | ScalarEnumValue !Name !Name
  | ScalarIdValue !Name !Text
  deriving stock (Eq, Show)

data TypedScalarNode
  = TypedLiteral !ScalarValue
  | TypedRoot !ScalarRootProvenance
  | TypedProject !ScalarRootProvenance !ResolvedScalarProjection
  | TypedAdd !ArithmeticEvidence !TypedScalarExpr !TypedScalarExpr
  | TypedSubtract !ArithmeticEvidence !TypedScalarExpr !TypedScalarExpr
  | TypedMultiply !ArithmeticEvidence !TypedScalarExpr !TypedScalarExpr
  | TypedEqual !TypedScalarExpr !TypedScalarExpr
  | TypedNotEqual !TypedScalarExpr !TypedScalarExpr
  | TypedCompare !CmpOp !TypedScalarExpr !TypedScalarExpr
  | TypedAnd !TypedScalarExpr !TypedScalarExpr
  | TypedOr !TypedScalarExpr !TypedScalarExpr
  deriving stock (Eq, Show)

data TypedScalarExpr = TypedScalarExpr
  { typedScalarType :: !ResolvedAggregateType,
    typedScalarLoc :: !Loc,
    typedScalarNode :: !TypedScalarNode
  }
  deriving stock (Eq, Show)

data ExpressionDiagnosticCode
  = ScalarRootUnknown
  | ScalarRootAmbiguous
  | ScalarPathInvalid
  | ScalarPathUnsupported
  | ScalarLiteralNeedsType
  | ScalarLiteralInvalid
  | ScalarOperandTypeMismatch
  | ScalarOperatorUnsupported
  | ScalarBooleanOperandRequired
  | ScalarGuardBoolRequired
  | ScalarWriteTargetUnknown
  | ScalarWriteTypeMismatch
  deriving stock (Eq, Ord, Show)

data ExpressionDiagnostic = ExpressionDiagnostic
  { expressionDiagnosticLoc :: !Loc,
    expressionDiagnosticCode :: !ExpressionDiagnosticCode,
    expressionDiagnosticMessage :: !Text
  }
  deriving stock (Eq, Show)

resolveScalarExpr :: ExpressionEnvironment -> ExpectedScalarType -> Expr -> Either (NonEmpty ExpressionDiagnostic) TypedScalarExpr
resolveScalarExpr environment expected expression =
  checkExpected expected =<< resolve expression expected
  where
    resolve syntax wanted = case syntax of
      EOr left right -> resolveBoolean TypedOr left right
      EAnd left right -> resolveBoolean TypedAnd left right
      ECmp operator left right -> resolveComparison operator left right
      EAdd loc left right -> resolveArithmetic loc TypedAdd left right wanted
      ESubtract loc left right -> resolveArithmetic loc TypedSubtract left right wanted
      EMultiply loc left right -> resolveArithmetic loc TypedMultiply left right wanted
      EPath loc root path -> resolvePath environment loc root path
      ELiteral loc literal -> resolveLiteral environment loc wanted literal
      EAtom (ABool value) -> pure (literalExpr noLoc AggregateBool (ScalarBoolValue value))
      EAtom (AName name) -> resolvePath environment noLoc UnqualifiedRoot [name]

    resolveBoolean constructor left right = do
      (resolvedLeft, resolvedRight) <- resolveBoth (resolve left (ExpectScalarType AggregateBool)) (resolve right (ExpectScalarType AggregateBool))
      pure
        TypedScalarExpr
          { typedScalarType = AggregateBool,
            typedScalarLoc = expressionLoc left right,
            typedScalarNode = constructor resolvedLeft resolvedRight
          }

    resolveComparison operator left right = do
      (resolvedLeft, resolvedRight) <- resolvePair left right
      requireSameType resolvedLeft resolvedRight
      requireComparisonCapability operator resolvedLeft
      pure
        TypedScalarExpr
          { typedScalarType = AggregateBool,
            typedScalarLoc = expressionLoc left right,
            typedScalarNode = case operator of
              OpEq -> TypedEqual resolvedLeft resolvedRight
              OpNeq -> TypedNotEqual resolvedLeft resolvedRight
              OpLt -> TypedCompare OpLt resolvedLeft resolvedRight
              OpLe -> TypedCompare OpLe resolvedLeft resolvedRight
              OpGt -> TypedCompare OpGt resolvedLeft resolvedRight
              OpGe -> TypedCompare OpGe resolvedLeft resolvedRight
          }

    resolveArithmetic loc constructor left right wanted = do
      pair <- case wanted of
        ExpectScalarType scalarType
          | scalarType `elem` [AggregateInteger, AggregateNatural] ->
              resolveBoth (resolve left wanted) (resolve right wanted)
        _ -> resolvePair left right
      let (resolvedLeft, resolvedRight) = pair
      requireSameType resolvedLeft resolvedRight
      evidence <- arithmeticEvidence loc (typedScalarType resolvedLeft)
      pure
        TypedScalarExpr
          { typedScalarType = typedScalarType resolvedLeft,
            typedScalarLoc = loc,
            typedScalarNode = constructor evidence resolvedLeft resolvedRight
          }

    resolvePair left right
      | contextualLiteral left && not (contextualLiteral right) = do
          resolvedRight <- resolve right InferScalarType
          resolvedLeft <- resolve left (ExpectScalarType (typedScalarType resolvedRight))
          pure (resolvedLeft, resolvedRight)
      | contextualLiteral right && not (contextualLiteral left) = do
          resolvedLeft <- resolve left InferScalarType
          resolvedRight <- resolve right (ExpectScalarType (typedScalarType resolvedLeft))
          pure (resolvedLeft, resolvedRight)
      | otherwise = case (resolve left InferScalarType, resolve right InferScalarType) of
          (Right resolvedLeft, Right resolvedRight) -> Right (resolvedLeft, resolvedRight)
          (Left _, Right resolvedRight) -> do
            resolvedLeft <- resolve left (ExpectScalarType (typedScalarType resolvedRight))
            pure (resolvedLeft, resolvedRight)
          (Right resolvedLeft, Left _) -> do
            resolvedRight <- resolve right (ExpectScalarType (typedScalarType resolvedLeft))
            pure (resolvedLeft, resolvedRight)
          (Left leftErrors, Left rightErrors) -> Left (leftErrors <> rightErrors)

    resolveBoth left right = case (left, right) of
      (Right resolvedLeft, Right resolvedRight) -> Right (resolvedLeft, resolvedRight)
      (Left leftErrors, Left rightErrors) -> Left (leftErrors <> rightErrors)
      (Left errors, _) -> Left errors
      (_, Left errors) -> Left errors

    requireSameType left right
      | typedScalarType left == typedScalarType right = Right ()
      | otherwise =
          failure
            (typedScalarLoc right)
            ScalarOperandTypeMismatch
            ( "expression operands have different scalar types '"
                <> aggregateCanonicalName (typedScalarType left)
                <> "' and '"
                <> aggregateCanonicalName (typedScalarType right)
                <> "'; numeric coercion is not supported"
            )

    requireComparisonCapability operator operand =
      let useSite = case operator of
            OpEq -> EqualityGuardUse
            OpNeq -> EqualityGuardUse
            OpLt -> OrderingGuardUse
            OpLe -> OrderingGuardUse
            OpGt -> OrderingGuardUse
            OpGe -> OrderingGuardUse
       in case aggregateCapability useSite (typedScalarType operand) of
            SolverVisible -> Right ()
            OpaqueOnly -> unsupported useSite
            Unsupported -> unsupported useSite
      where
        unsupported useSite =
          failure
            (typedScalarLoc operand)
            ScalarOperatorUnsupported
            ( renderUseSite useSite
                <> " is unsupported for scalar type '"
                <> aggregateCanonicalName (typedScalarType operand)
                <> "'"
            )

    checkExpected InferScalarType resolved = Right resolved
    checkExpected (ExpectScalarType wanted) resolved
      | wanted == typedScalarType resolved = Right resolved
      | wanted == AggregateBool =
          failure
            (typedScalarLoc resolved)
            ScalarBooleanOperandRequired
            ("Boolean expression requires Bool, found '" <> aggregateCanonicalName (typedScalarType resolved) <> "'")
      | otherwise =
          failure
            (typedScalarLoc resolved)
            ScalarOperandTypeMismatch
            ( "expected scalar type '"
                <> aggregateCanonicalName wanted
                <> "', found '"
                <> aggregateCanonicalName (typedScalarType resolved)
                <> "'"
            )

resolveGuardExpr :: ExpressionEnvironment -> Expr -> Either (NonEmpty ExpressionDiagnostic) TypedScalarExpr
resolveGuardExpr environment expression =
  case resolveScalarExpr environment (ExpectScalarType AggregateBool) expression of
    Left diagnostics
      | all ((== ScalarBooleanOperandRequired) . expressionDiagnosticCode) (NE.toList diagnostics) ->
          Left
            ( fmap
                ( \diagnostic ->
                    diagnostic
                      { expressionDiagnosticCode = ScalarGuardBoolRequired,
                        expressionDiagnosticMessage = "aggregate guard must resolve to Bool; " <> expressionDiagnosticMessage diagnostic
                      }
                )
                diagnostics
            )
    other -> other

resolveWriteExpr :: ExpressionEnvironment -> Name -> Expr -> Either (NonEmpty ExpressionDiagnostic) TypedScalarExpr
resolveWriteExpr environment registerName expression =
  case find ((== registerName) . regName) (aggRegs (environmentAggregate environment)) of
    Nothing ->
      failure
        (exprLoc expression)
        ScalarWriteTargetUnknown
        ("write target '" <> registerName <> "' is not an aggregate register")
    Just register -> case resolveAggregateType (environmentSymbols environment) (regLoc register) RegisterUse (regType register) of
      Left _ -> Right unresolvedSentinel
      Right expected -> case resolveScalarExpr environment (ExpectScalarType expected) expression of
        Left diagnostics -> Left (fmap writeDiagnostic diagnostics)
        Right resolved
          | predicateValued resolved ->
              failure
                (typedScalarLoc resolved)
                ScalarOperatorUnsupported
                "comparison and Boolean operators are guard predicates and cannot be written as scalar terms"
          | otherwise -> Right resolved
        where
          writeDiagnostic diagnostic
            | expressionDiagnosticCode diagnostic == ScalarOperandTypeMismatch =
                diagnostic
                  { expressionDiagnosticCode = ScalarWriteTypeMismatch,
                    expressionDiagnosticMessage =
                      "write to register '"
                        <> registerName
                        <> "' has the wrong scalar type; "
                        <> expressionDiagnosticMessage diagnostic
                  }
            | otherwise = diagnostic
  where
    -- The aggregate type validator reports the primary type error first. This
    -- value is never scaffolded because any error prevents generation.
    unresolvedSentinel = TypedScalarExpr AggregateBool noLoc (TypedLiteral (ScalarBoolValue False))

resolvePath :: ExpressionEnvironment -> Loc -> ExprRoot -> [Name] -> Either (NonEmpty ExpressionDiagnostic) TypedScalarExpr
resolvePath environment loc root path = case path of
  [] -> failure loc ScalarRootUnknown "scalar path is empty"
  rootName : fields -> do
    provenance <- resolveRoot environment loc root rootName
    case fields of
      [] -> pure (rootExpr loc provenance)
      _ -> resolveProjectionPath environment loc provenance fields

resolveRoot :: ExpressionEnvironment -> Loc -> ExprRoot -> Name -> Either (NonEmpty ExpressionDiagnostic) ScalarRootProvenance
resolveRoot environment loc root name = case root of
  RegisterRoot -> maybe unknown (Right . registerRoot) register
  CommandRoot -> maybe unknown (Right . commandRoot) commandField
  UnqualifiedRoot -> case (register, commandField) of
    (Just _, Just _) ->
      failure
        loc
        ScalarRootAmbiguous
        ("unqualified scalar root '" <> name <> "' matches both a register and command field; use reg." <> name <> " or cmd." <> name)
    (Just value, Nothing) -> Right (registerRoot value)
    (Nothing, Just value) -> Right (commandRoot value)
    (Nothing, Nothing) -> unknown
  where
    aggregate = environmentAggregate environment
    transition = environmentTransition environment
    symbols = environmentSymbols environment
    register = find ((== name) . regName) (aggRegs aggregate)
    commandField = do
      command <- find ((== tCommand transition) . cmdName) (aggCommands aggregate)
      find ((== name) . aggregateFieldName) (cmdFields command)
    registerRoot value =
      ScalarRegisterRoot name (resolvedOrUnknown (resolveAggregateType symbols (regLoc value) RegisterUse (regType value)))
    commandRoot value =
      ScalarCommandRoot name (resolvedOrUnknown (inferAggregateFieldType symbols aggregate CommandFieldUse value))
    resolvedOrUnknown = either (const (AggregateMapped (MappedKey "<invalid>"))) id
    unknown =
      failure
        loc
        ScalarRootUnknown
        ( "scalar root '"
            <> name
            <> "' resolves to no register or field of command '"
            <> tCommand transition
            <> "'; qualify enum values as Type.Constructor"
        )

resolveProjectionPath :: ExpressionEnvironment -> Loc -> ScalarRootProvenance -> [Name] -> Either (NonEmpty ExpressionDiagnostic) TypedScalarExpr
resolveProjectionPath environment loc provenance fields = do
  owner <- case rootType provenance of
    AggregateMapped key -> Right key
    other ->
      failure
        loc
        ScalarPathInvalid
        ("cannot project fields through scalar type '" <> aggregateCanonicalName other <> "'")
  graph <- maybe (failure loc ScalarPathUnsupported "mapped structural graph is unavailable") Right (environmentTypeGraph environment)
  (resolvedType, wireKeys) <- walk graph owner fields
  if scalarLeaf resolvedType
    then
      pure
        TypedScalarExpr
          { typedScalarType = resolvedType,
            typedScalarLoc = loc,
            typedScalarNode =
              TypedProject
                provenance
                ResolvedScalarProjection
                  { scalarProjectionOwner = owner,
                    scalarProjectionPointer = T.concat ["/" <> escapePointer key | key <- wireKeys],
                    scalarProjectionFields = fields
                  }
          }
    else
      failure
        loc
        ScalarPathUnsupported
        ("path ends at unsupported non-scalar type '" <> aggregateCanonicalName resolvedType <> "'")
  where
    walk graph ownerKey remaining = case Map.lookup ownerKey (tgDeclarations graph) of
      Just (ResolvedStructural _ (RRecord _ _ recordFields)) -> selectField graph recordFields remaining
      Just ResolvedStructural {} -> failure loc ScalarPathUnsupported "scalar paths may cross required structural records only"
      Just ResolvedOpaque {} -> failure loc ScalarPathUnsupported "scalar paths cannot cross an opaque mapped declaration"
      Nothing -> failure loc ScalarPathInvalid ("unknown mapped path owner '" <> unMappedKey ownerKey <> "'")

    selectField _ _ [] = failure loc ScalarPathInvalid "scalar path is empty"
    selectField graph recordFields (fieldName : rest) = case find ((== fieldName) . rwfHaskell) recordFields of
      Nothing -> failure loc ScalarPathInvalid ("required structural field '" <> fieldName <> "' does not exist")
      Just field
        | rwfPresence field /= PRequired -> failure loc ScalarPathUnsupported ("field '" <> fieldName <> "' is optional; scalar paths must be total")
        | null rest -> (,[rwfKey field]) <$> resolvedLeaf (rwfType field)
        | RRef nextOwner <- rwfType field -> do
            (leafType, keys) <- walk graph nextOwner rest
            pure (leafType, rwfKey field : keys)
        | otherwise -> failure loc ScalarPathUnsupported ("field '" <> fieldName <> "' is not a required structural record")

    resolvedLeaf = \case
      RText -> Right AggregateText
      RInt -> Right AggregateInt
      RInteger -> Right AggregateInteger
      RBool -> Right AggregateBool
      RNatural -> Right AggregateNatural
      RTime -> Right AggregateTime
      RJson -> unsupported "Json"
      ROptional {} -> unsupported "Optional"
      RList {} -> unsupported "List"
      RMap {} -> unsupported "Map"
      RRef key -> Right (AggregateMapped key)
    unsupported name = failure loc ScalarPathUnsupported (name <> " is not a supported scalar path leaf")

resolveLiteral :: ExpressionEnvironment -> Loc -> ExpectedScalarType -> ScalarLiteral -> Either (NonEmpty ExpressionDiagnostic) TypedScalarExpr
resolveLiteral environment loc expected literal = case literal of
  LiteralBool value -> pure (literalExpr loc AggregateBool (ScalarBoolValue value))
  LiteralText value -> case expected of
    ExpectScalarType AggregateTime -> case iso8601ParseM (T.unpack value) of
      Just parsed -> pure (literalExpr loc AggregateTime (ScalarTimeValue parsed))
      Nothing -> invalid "Time literal must be a valid ISO-8601 UTC timestamp"
    ExpectScalarType AggregateText -> pure (literalExpr loc AggregateText (ScalarTextValue value))
    InferScalarType -> pure (literalExpr loc AggregateText (ScalarTextValue value))
    ExpectScalarType other -> mismatch other "quoted Text/Time"
  LiteralIntegral value -> case expected of
    ExpectScalarType AggregateInt
      | value >= fromIntegral (minBound :: Int) && value <= fromIntegral (maxBound :: Int) ->
          pure (literalExpr loc AggregateInt (ScalarIntValue (fromInteger value)))
      | otherwise -> invalid "Int literal is outside the Haskell Int range"
    ExpectScalarType AggregateInteger -> pure (literalExpr loc AggregateInteger (ScalarIntegerValue value))
    ExpectScalarType AggregateNatural
      | value >= 0 -> pure (literalExpr loc AggregateNatural (ScalarNaturalValue value))
      | otherwise -> invalid "Natural literal must be non-negative"
    InferScalarType -> failure loc ScalarLiteralNeedsType "integral literal needs an expected Int, Integer, or Natural type"
    ExpectScalarType other -> mismatch other "integral"
  LiteralQualified typeName constructor -> resolveEnumLiteral environment loc expected typeName constructor
  LiteralId typeName value -> resolveIdLiteral environment loc expected typeName value
  where
    invalid message = failure loc ScalarLiteralInvalid message
    mismatch other syntax =
      failure
        loc
        ScalarOperandTypeMismatch
        (syntax <> " literal cannot inhabit scalar type '" <> aggregateCanonicalName other <> "'")

resolveEnumLiteral :: ExpressionEnvironment -> Loc -> ExpectedScalarType -> Name -> Name -> Either (NonEmpty ExpressionDiagnostic) TypedScalarExpr
resolveEnumLiteral environment loc expected typeName constructor = case find ((== typeName) . enumName) (specEnums (environmentSpec environment)) of
  Nothing -> failure loc ScalarLiteralInvalid ("unknown enum literal type '" <> typeName <> "'")
  Just declaration
    | constructor `notElem` map fst (enumCtors declaration) ->
        failure loc ScalarLiteralInvalid ("enum '" <> typeName <> "' has no constructor '" <> constructor <> "'")
    | otherwise -> do
        resolved <- resolveDeclared typeName
        requireExpected resolved
        pure (literalExpr loc resolved (ScalarEnumValue typeName constructor))
  where
    resolveDeclared name = case resolveAggregateType (environmentSymbols environment) loc WholeValueWriteUse (TRef name) of
      Left _ -> failure loc ScalarLiteralInvalid ("enum type '" <> name <> "' is not available at this aggregate use")
      Right resolved -> Right resolved
    requireExpected resolved = case expected of
      InferScalarType -> Right ()
      ExpectScalarType wanted
        | wanted == resolved -> Right ()
        | otherwise -> failure loc ScalarOperandTypeMismatch ("enum literal has type '" <> aggregateCanonicalName resolved <> "', expected '" <> aggregateCanonicalName wanted <> "'")

resolveIdLiteral :: ExpressionEnvironment -> Loc -> ExpectedScalarType -> Name -> Text -> Either (NonEmpty ExpressionDiagnostic) TypedScalarExpr
resolveIdLiteral environment loc expected typeName value = case find ((== typeName) . idName) (specIds (environmentSpec environment)) of
  Nothing -> failure loc ScalarLiteralInvalid ("unknown ID literal type '" <> typeName <> "'")
  Just declaration -> case TypeID.parseText value of
    Left parseError -> failure loc ScalarLiteralInvalid ("invalid " <> typeName <> " literal: " <> T.pack (show parseError))
    Right parsed
      | TypeID.getPrefix parsed /= idPrefix declaration ->
          failure loc ScalarLiteralInvalid ("ID literal prefix must be '" <> idPrefix declaration <> "'")
      | otherwise -> do
          resolved <- case resolveAggregateType (environmentSymbols environment) loc WholeValueWriteUse (TRef typeName) of
            Left _ -> failure loc ScalarLiteralInvalid ("ID type '" <> typeName <> "' is not available at this aggregate use")
            Right valueType -> Right valueType
          case expected of
            InferScalarType -> pure ()
            ExpectScalarType wanted
              | wanted == resolved -> pure ()
              | otherwise -> failure loc ScalarOperandTypeMismatch ("ID literal has type '" <> aggregateCanonicalName resolved <> "', expected '" <> aggregateCanonicalName wanted <> "'")
          pure (literalExpr loc resolved (ScalarIdValue typeName value))

arithmeticEvidence :: Loc -> ResolvedAggregateType -> Either (NonEmpty ExpressionDiagnostic) ArithmeticEvidence
arithmeticEvidence _ AggregateInteger = Right ExactIntegerArithmetic
arithmeticEvidence _ AggregateNatural = Right TotalNaturalArithmetic
arithmeticEvidence loc scalarType =
  failure
    loc
    ScalarOperatorUnsupported
    ( "arithmetic is unsupported for scalar type '"
        <> aggregateCanonicalName scalarType
        <> "'; only exact Integer and total Natural arithmetic are admitted"
    )

rootType :: ScalarRootProvenance -> ResolvedAggregateType
rootType (ScalarRegisterRoot _ scalarType) = scalarType
rootType (ScalarCommandRoot _ scalarType) = scalarType

rootExpr :: Loc -> ScalarRootProvenance -> TypedScalarExpr
rootExpr loc provenance = TypedScalarExpr (rootType provenance) loc (TypedRoot provenance)

literalExpr :: Loc -> ResolvedAggregateType -> ScalarValue -> TypedScalarExpr
literalExpr loc scalarType value = TypedScalarExpr scalarType loc (TypedLiteral value)

scalarLeaf :: ResolvedAggregateType -> Bool
scalarLeaf = \case
  AggregateText -> True
  AggregateInt -> True
  AggregateInteger -> True
  AggregateBool -> True
  AggregateTime -> True
  AggregateNatural -> True
  AggregateNominal {} -> True
  AggregateVertex {} -> False
  AggregateMapped {} -> False

predicateValued :: TypedScalarExpr -> Bool
predicateValued expression = case typedScalarNode expression of
  TypedEqual {} -> True
  TypedNotEqual {} -> True
  TypedCompare {} -> True
  TypedAnd {} -> True
  TypedOr {} -> True
  TypedLiteral {} -> False
  TypedRoot {} -> False
  TypedProject {} -> False
  TypedAdd {} -> False
  TypedSubtract {} -> False
  TypedMultiply {} -> False

contextualLiteral :: Expr -> Bool
contextualLiteral = \case
  ELiteral _ LiteralIntegral {} -> True
  ELiteral _ LiteralText {} -> True
  _ -> False

expressionLoc :: Expr -> Expr -> Loc
expressionLoc left right = case exprLoc left of
  Loc 0 -> exprLoc right
  loc -> loc

escapePointer :: Text -> Text
escapePointer = T.replace "/" "~1" . T.replace "~" "~0"

renderUseSite :: AggregateUseSite -> Text
renderUseSite = \case
  EqualityGuardUse -> "equality"
  OrderingGuardUse -> "ordering"
  CommandFieldUse -> "command field"
  EventFieldUse -> "event field"
  RegisterUse -> "register"
  WholeValueWriteUse -> "whole-value write"
  CodecUse -> "JSON codec"
  SnapshotUse -> "snapshot"
  HarnessSampleUse -> "harness sample"
  HaskellLoweringUse -> "Haskell lowering"

failure :: Loc -> ExpressionDiagnosticCode -> Text -> Either (NonEmpty ExpressionDiagnostic) a
failure loc diagnosticCode diagnosticMessage =
  Left
    ( ExpressionDiagnostic
        { expressionDiagnosticLoc = loc,
          expressionDiagnosticCode = diagnosticCode,
          expressionDiagnosticMessage = diagnosticMessage
        }
        :| []
    )
