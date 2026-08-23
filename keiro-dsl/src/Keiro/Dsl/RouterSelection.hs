{-# OPTIONS_GHC -Werror=incomplete-patterns #-}

-- | Checked language-5 router selection semantics.
--
-- The parser AST deliberately retains unsupported policy names and unresolved
-- expressions so check can produce stable, located diagnostics. Values exported
-- from this module have crossed the mapped-type boundary: every path is total,
-- every scalar has one type, command mappings are complete, and the recipient
-- set has a positive bound.
module Keiro.Dsl.RouterSelection
  ( CheckedReadModelQuery (..),
    CheckedMappedExpr (..),
    CheckedMappedType (..),
    SelectionScalarType (..),
    SelectionRoot (..),
    CheckedSelectionPathSegment (..),
    CheckedScalarExpr (..),
    CheckedScalarNode (..),
    CheckedSelectionOrder (..),
    CheckedSelectionDedupe (..),
    CheckedEmptySelectionPolicy (..),
    CheckedSelectionFailurePolicy (..),
    CheckedRedeliveryPolicy (..),
    CheckedPartialDispatchPolicy (..),
    CheckedRouterSelection (..),
    RouterSelectionDiagnosticCode (..),
    RouterSelectionDiagnostic (..),
    checkRouterSelection,
    routerSelectionFingerprint,
  )
where

import Crypto.Hash.SHA256 qualified as SHA256
import Data.ByteString qualified as BS
import Data.List (find, sort)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as Text
import GHC.Generics (Generic)
import Keiro.Dsl.AggregateType
import Keiro.Dsl.Grammar
import Keiro.Dsl.LanguageVersion (LanguageFeature (DeclarativeRouterSelectionSyntax), languageSupportsFeature)
import Keiro.Dsl.SemanticContract (EffectiveLanguageContract (..))
import Keiro.Dsl.TypeGraph
import Numeric (showHex)
import Numeric.Natural (Natural)

data CheckedReadModelQuery = CheckedReadModelQuery
  { name :: !Name,
    inputType :: !ResolvedTypeExpr,
    resultType :: !ResolvedTypeExpr
  }
  deriving stock (Eq, Show, Generic)

data CheckedMappedExpr = CheckedMappedExpr
  { root :: !SelectionRoot,
    valueType :: !ResolvedTypeExpr
  }
  deriving stock (Eq, Show, Generic)

data CheckedMappedType = CheckedMappedType
  { key :: !MappedKey,
    constructor :: !Name,
    fields :: ![ResolvedWireField]
  }
  deriving stock (Eq, Show, Generic)

data SelectionScalarType
  = SelectionText
  | SelectionInt
  | SelectionInteger
  | SelectionBool
  | SelectionNatural
  | SelectionTime
  deriving stock (Eq, Ord, Show, Enum, Bounded, Generic)

data SelectionRoot = SelectionInput | SelectionRow
  deriving stock (Eq, Ord, Show, Generic)

data CheckedSelectionPathSegment = CheckedSelectionPathSegment
  { field :: !Name,
    wireKey :: !Text,
    owner :: !MappedKey
  }
  deriving stock (Eq, Ord, Show, Generic)

data CheckedScalarExpr = CheckedScalarExpr
  { valueType :: !SelectionScalarType,
    node :: !CheckedScalarNode,
    loc :: !Loc
  }
  deriving stock (Eq, Show, Generic)

data CheckedScalarNode
  = CheckedPath !SelectionRoot ![CheckedSelectionPathSegment]
  | CheckedTextLiteral !Text
  | CheckedIntegralLiteral !Integer
  | CheckedBoolLiteral !Bool
  | CheckedCompare !CmpOp !CheckedScalarExpr !CheckedScalarExpr
  | CheckedAnd !CheckedScalarExpr !CheckedScalarExpr
  | CheckedOr !CheckedScalarExpr !CheckedScalarExpr
  deriving stock (Eq, Show, Generic)

data CheckedSelectionOrder = CheckedOrderByTargetStream
  deriving stock (Eq, Ord, Show, Generic)

data CheckedSelectionDedupe = CheckedDedupeByTargetStream
  deriving stock (Eq, Ord, Show, Generic)

data CheckedEmptySelectionPolicy
  = CheckedEmptyAck
  | CheckedEmptyRetry
  | CheckedEmptyDeadLetter
  | CheckedEmptyHalt
  deriving stock (Eq, Ord, Show, Generic)

data CheckedSelectionFailurePolicy
  = CheckedFailureRetry
  | CheckedFailureDeadLetter
  | CheckedFailureHalt
  deriving stock (Eq, Ord, Show, Generic)

data CheckedRedeliveryPolicy = CheckedStableUnion
  deriving stock (Eq, Ord, Show, Generic)

data CheckedPartialDispatchPolicy = CheckedRetainSuccesses
  deriving stock (Eq, Ord, Show, Generic)

data CheckedRouterSelection = CheckedRouterSelection
  { identity :: !Text,
    version :: !Natural,
    query :: !CheckedReadModelQuery,
    inputBinding :: !CheckedMappedExpr,
    rowBinding :: !CheckedMappedType,
    key :: !CheckedScalarExpr,
    predicate :: !CheckedScalarExpr,
    recipient :: !CheckedScalarExpr,
    commandFields :: !(Map Name CheckedScalarExpr),
    target :: !Name,
    command :: !Name,
    limit :: !Natural,
    order :: !CheckedSelectionOrder,
    dedupe :: !CheckedSelectionDedupe,
    emptyPolicy :: !CheckedEmptySelectionPolicy,
    failurePolicy :: !CheckedSelectionFailurePolicy,
    redeliveryPolicy :: !CheckedRedeliveryPolicy,
    partialPolicy :: !CheckedPartialDispatchPolicy,
    fingerprint :: !Text,
    useSites :: ![UseSite]
  }
  deriving stock (Eq, Show, Generic)

data RouterSelectionDiagnosticCode
  = SelectionNotDeclarative
  | SelectionCapabilityUnavailable
  | SelectionIdentityEmpty
  | SelectionVersionInvalid
  | SelectionQueryUnknown
  | SelectionQueryContractMissing
  | SelectionQueryInputBindingInvalid
  | SelectionQueryInputTypeMismatch
  | SelectionQueryResultNotList
  | SelectionQueryRowNotStructural
  | SelectionExpressionRootUnknown
  | SelectionExpressionFieldUnknown
  | SelectionExpressionFieldOptional
  | SelectionExpressionTypeMismatch
  | SelectionPredicateNotBool
  | SelectionRecipientNotText
  | SelectionOperatorUnsupported
  | SelectionRecipientLimitMissing
  | SelectionRecipientLimitInvalid
  | SelectionOrderUnsupported
  | SelectionDedupeUnsupported
  | SelectionFailureAckForbidden
  | SelectionRedeliveryUnsupported
  | SelectionPartialDispatchUnsupported
  | SelectionTargetAmbiguous
  | SelectionCommandUnknown
  | SelectionCommandMappingDuplicate
  | SelectionCommandMappingIncomplete
  | SelectionCommandMappingTypeMismatch
  deriving stock (Eq, Ord, Show, Enum, Bounded, Generic)

data RouterSelectionDiagnostic = RouterSelectionDiagnostic
  { loc :: !Loc,
    code :: !RouterSelectionDiagnosticCode,
    message :: !Text
  }
  deriving stock (Eq, Show, Generic)

checkRouterSelection :: EffectiveLanguageContract -> TypeGraph -> Spec -> RouterNode -> Either (NonEmpty RouterSelectionDiagnostic) CheckedRouterSelection
checkRouterSelection languageContract graph spec router = case (.source) ((.resolve) router) of
  ResolveReadModel {} -> selectionFailure ((.loc) ((.resolve) router)) SelectionNotDeclarative "custom-unverified router selection has no checked declarative contract"
  ResolveHole -> selectionFailure ((.loc) ((.resolve) router)) SelectionNotDeclarative "custom-unverified router selection has no checked declarative contract"
  ResolveDeclarative declaration -> checkDeclaration declaration
  where
    symbols = aggregateSymbolsFromGraph graph spec

    checkDeclaration declaration = do
      requireFeature declaration
      identity <- requireIdentity declaration
      version <- requirePositive ((.versionLoc) declaration) SelectionVersionInvalid "selection version" ((.version) declaration)
      recipientLimit <- case (.limit) declaration of
        Nothing -> selectionFailure ((.loc) declaration) SelectionRecipientLimitMissing "declarative router selection requires a positive max-recipients"
        Just (value, valueLoc) -> requirePositive valueLoc SelectionRecipientLimitInvalid "max-recipients" value
      order <- requireExact ((.orderLoc) declaration) SelectionOrderUnsupported "order" "target-stream" CheckedOrderByTargetStream ((.order) declaration)
      dedupe <- requireExact ((.dedupeLoc) declaration) SelectionDedupeUnsupported "dedupe" "target-stream" CheckedDedupeByTargetStream ((.dedupe) declaration)
      emptyPolicy <- checkEmptyPolicy declaration
      failurePolicy <- checkFailurePolicy declaration
      redelivery <- requireExact ((.redeliveryLoc) declaration) SelectionRedeliveryUnsupported "redelivery" "stable-union" CheckedStableUnion ((.redelivery) declaration)
      partial <- requireExact ((.partialLoc) declaration) SelectionPartialDispatchUnsupported "partial" "retain-successes" CheckedRetainSuccesses ((.partial) declaration)
      (query, inputBinding, rowBinding) <- checkQuery declaration
      keyExpression <- resolveSelectionExpr graph ((.valueType) inputBinding) rowBinding Nothing (EPath ((.loc) ((.input) router)) UnqualifiedRoot ["input", (.field) ((.key) router)])
      requireScalarType ((.loc) ((.input) router)) SelectionQueryInputBindingInvalid "router key" SelectionText keyExpression
      predicate <- resolveSelectionExpr graph ((.valueType) inputBinding) rowBinding Nothing ((.predicate) declaration)
      requireScalarType (exprLoc ((.predicate) declaration)) SelectionPredicateNotBool "where predicate" SelectionBool predicate
      recipient <- resolveSelectionExpr graph ((.valueType) inputBinding) rowBinding Nothing ((.recipient) declaration)
      requireScalarType (exprLoc ((.recipient) declaration)) SelectionRecipientNotText "recipient expression" SelectionText recipient
      (targetAggregate, targetCommand) <- resolveTargetCommand
      commandFields <- checkCommandMappings graph inputBinding rowBinding targetAggregate targetCommand
      let initial =
            CheckedRouterSelection
              { identity = identity,
                version = version,
                query = query,
                inputBinding = inputBinding,
                rowBinding = rowBinding,
                key = keyExpression,
                predicate = predicate,
                recipient = recipient,
                commandFields = commandFields,
                target = (.target) router,
                command = (.command) ((.dispatch) router),
                limit = recipientLimit,
                order = order,
                dedupe = dedupe,
                emptyPolicy = emptyPolicy,
                failurePolicy = failurePolicy,
                redeliveryPolicy = redelivery,
                partialPolicy = partial,
                fingerprint = "",
                useSites = queryUseSites ((.query) declaration)
              }
      pure (setRouterSelectionFingerprint (routerSelectionFingerprint initial) initial)

    requireFeature declaration
      | languageSupportsFeature ((.contractLanguageVersion) languageContract) DeclarativeRouterSelectionSyntax = Right ()
      | otherwise = selectionFailure ((.loc) declaration) SelectionCapabilityUnavailable "declarative router selection requires language keiro-dsl 5"

    setRouterSelectionFingerprint fingerprint selection =
      CheckedRouterSelection
        { identity = selection.identity,
          version = selection.version,
          query = selection.query,
          inputBinding = selection.inputBinding,
          rowBinding = selection.rowBinding,
          key = selection.key,
          predicate = selection.predicate,
          recipient = selection.recipient,
          commandFields = selection.commandFields,
          target = selection.target,
          command = selection.command,
          limit = selection.limit,
          order = selection.order,
          dedupe = selection.dedupe,
          emptyPolicy = selection.emptyPolicy,
          failurePolicy = selection.failurePolicy,
          redeliveryPolicy = selection.redeliveryPolicy,
          partialPolicy = selection.partialPolicy,
          fingerprint,
          useSites = selection.useSites
        }

    requireIdentity declaration
      | T.null (T.strip ((.identity) declaration)) = selectionFailure ((.identityLoc) declaration) SelectionIdentityEmpty "selection identity must not be empty"
      | otherwise = Right ((.identity) declaration)

    checkEmptyPolicy declaration = case (.emptyPolicy) declaration of
      SelectionAck -> Right CheckedEmptyAck
      SelectionRetry -> Right CheckedEmptyRetry
      SelectionDeadLetter -> Right CheckedEmptyDeadLetter
      SelectionHalt -> Right CheckedEmptyHalt

    checkFailurePolicy declaration = case (.failurePolicy) declaration of
      SelectionAck -> selectionFailure ((.failurePolicyLoc) declaration) SelectionFailureAckForbidden "selection failure cannot acknowledge the source message"
      SelectionRetry -> Right CheckedFailureRetry
      SelectionDeadLetter -> Right CheckedFailureDeadLetter
      SelectionHalt -> Right CheckedFailureHalt

    checkQuery declaration = do
      readModel <- case find ((== (.query) declaration) . (.name)) readModels of
        Nothing -> selectionFailure ((.queryLoc) declaration) SelectionQueryUnknown ("selection query names undeclared readmodel '" <> (.query) declaration <> "'")
        Just value -> Right value
      queryTypesDeclaration <- maybe (selectionFailure ((.queryLoc) declaration) SelectionQueryContractMissing ("readmodel '" <> (.name) readModel <> "' has no typed query input/result contract")) Right ((.queryTypes) readModel)
      if (.queryInput) declaration == "input"
        then pure ()
        else selectionFailure ((.queryInputLoc) declaration) SelectionQueryInputBindingInvalid "selection query input must be the router input binding `input`"
      queryInput <- liftTypeGraph ((.queryLoc) declaration) (resolveTypeExpression graph ("readmodel " <> (.name) readModel <> " query input") ((.inputLoc) queryTypesDeclaration) ((.input) queryTypesDeclaration))
      queryResult <- liftTypeGraph ((.queryLoc) declaration) (resolveTypeExpression graph ("readmodel " <> (.name) readModel <> " query result") ((.resultLoc) queryTypesDeclaration) ((.result) queryTypesDeclaration))
      routerInputExpression <- maybe (selectionFailure ((.loc) ((.input) router)) SelectionQueryInputBindingInvalid "declarative router input must name its mapped query-input type with `input Name : Type`") Right ((.valueType) ((.input) router))
      routerInput <- liftTypeGraph ((.loc) ((.input) router)) (resolveTypeExpression graph ("router " <> (.id) router <> " input") ((.loc) ((.input) router)) routerInputExpression)
      if routerInput == queryInput
        then pure ()
        else selectionFailure ((.loc) ((.input) router)) SelectionQueryInputTypeMismatch ("router input type does not match readmodel '" <> (.name) readModel <> "' query input")
      _ <- structuralRecord ((.loc) ((.input) router)) SelectionQueryInputBindingInvalid "router query input" routerInput
      rowBinding <- case queryResult of
        RList rowType -> structuralRecord ((.resultLoc) queryTypesDeclaration) SelectionQueryRowNotStructural "query result row" rowType
        _ -> selectionFailure ((.resultLoc) queryTypesDeclaration) SelectionQueryResultNotList "declarative router query result must be List Row"
      pure
        ( CheckedReadModelQuery ((.name) readModel) queryInput queryResult,
          CheckedMappedExpr SelectionInput queryInput,
          rowBinding
        )

    structuralRecord diagnosticLoc diagnosticCode owner = \case
      RRef key -> case Map.lookup key ((.declarations) graph) of
        Just (ResolvedStructural _ (RRecord constructor _ fields)) -> Right (CheckedMappedType key constructor fields)
        _ -> selectionFailure diagnosticLoc diagnosticCode (owner <> " must be a mapped structural record")
      _ -> selectionFailure diagnosticLoc diagnosticCode (owner <> " must be a mapped structural record")

    resolveTargetCommand = case [aggregate | NAggregate aggregate <- (.nodes) spec, (.name) aggregate == (.target) router] of
      [aggregate] -> case [command | command <- (.commands) aggregate, (.name) command == (.command) ((.dispatch) router)] of
        [command] -> Right (aggregate, command)
        _ -> selectionFailure ((.loc) ((.dispatch) router)) SelectionCommandUnknown ("target aggregate '" <> (.target) router <> "' has no unique command '" <> (.command) ((.dispatch) router) <> "'")
      _ -> selectionFailure ((.loc) router) SelectionTargetAmbiguous ("declarative router target '" <> (.target) router <> "' does not identify exactly one aggregate")

    checkCommandMappings selectionGraph inputBinding rowBinding aggregate command = do
      let bindings = (.fields) ((.dispatch) router)
          duplicateNames = duplicates (map (.name) bindings)
          expectedNames = sort (map (.name) ((.fields) command))
          actualNames = sort (map (.name) bindings)
      case duplicateNames of
        duplicateName : _ -> selectionFailure ((.loc) ((.dispatch) router)) SelectionCommandMappingDuplicate ("dispatch field '" <> duplicateName <> "' is mapped more than once")
        [] -> pure ()
      if expectedNames == actualNames
        then pure ()
        else selectionFailure ((.loc) ((.dispatch) router)) SelectionCommandMappingIncomplete ("dispatch mapping must bind every field of command '" <> (.name) command <> "' exactly once")
      Map.fromList <$> traverse (checkBinding selectionGraph inputBinding rowBinding aggregate bindings) ((.fields) command)

    checkBinding selectionGraph inputBinding rowBinding aggregate bindings field = do
      binding <- case find ((== (.name) field) . (.name)) bindings of
        Just value -> Right value
        Nothing -> selectionFailure ((.loc) ((.dispatch) router)) SelectionCommandMappingIncomplete ("missing dispatch mapping for field '" <> (.name) field <> "'")
      expression <- resolveBinding selectionGraph inputBinding rowBinding ((.loc) ((.dispatch) router)) binding
      expectedAggregateType <- case inferAggregateFieldType symbols aggregate CommandFieldUse field of
        Left _ -> selectionFailure ((.loc) field) SelectionCommandMappingTypeMismatch ("command field '" <> (.name) field <> "' has no selection-compatible scalar type")
        Right value -> Right value
      expected <- maybe (selectionFailure ((.loc) field) SelectionCommandMappingTypeMismatch ("command field '" <> (.name) field <> "' is not a supported scalar selection target")) Right (selectionTypeFromAggregate expectedAggregateType)
      requireScalarType ((.loc) expression) SelectionCommandMappingTypeMismatch ("command field '" <> (.name) field <> "'") expected expression
      pure ((.name) field, expression)

    queryUseSites queryName =
      [ useSite
      | useSite <- (.useSites) graph,
        case useSite of
          RootReadModelQueryInput name _ -> name == queryName
          RootReadModelQueryResult name _ -> name == queryName
          _ -> False
      ]

    readModels = [readModel | NReadModel readModel <- (.nodes) spec]

resolveBinding :: TypeGraph -> CheckedMappedExpr -> CheckedMappedType -> Loc -> FieldBinding -> Either (NonEmpty RouterSelectionDiagnostic) CheckedScalarExpr
resolveBinding graph inputBinding rowBinding diagnosticLoc binding =
  resolveSelectionExpr graph ((.valueType) inputBinding) rowBinding Nothing expression
  where
    expression = case (.value) binding of
      Nothing -> EPath diagnosticLoc UnqualifiedRoot ["input", (.name) binding]
      Just value
        | Just literal <- quotedValue value -> ELiteral diagnosticLoc (LiteralText literal)
        | otherwise -> EPath diagnosticLoc UnqualifiedRoot (T.splitOn "." value)
    quotedValue value
      | T.length value >= 2,
        T.head value == '"',
        T.last value == '"' =
          Just (T.init (T.tail value))
      | otherwise = Nothing

resolveSelectionExpr :: TypeGraph -> ResolvedTypeExpr -> CheckedMappedType -> Maybe SelectionScalarType -> Expr -> Either (NonEmpty RouterSelectionDiagnostic) CheckedScalarExpr
resolveSelectionExpr graph inputType rowType expected expression = case expression of
  EPath loc UnqualifiedRoot (rootName : fields) -> do
    (root, rootType) <- case rootName of
      "input" -> Right (SelectionInput, inputType)
      "row" -> Right (SelectionRow, RRef ((.key) rowType))
      _ -> selectionFailure loc SelectionExpressionRootUnknown ("selection expression root must be input or row, found '" <> rootName <> "'")
    if null fields
      then selectionFailure loc SelectionExpressionTypeMismatch "a whole mapped value is not a scalar expression"
      else do
        (scalarType, path) <- resolvePath graph loc rootType fields
        requireExpected loc expected scalarType
        pure (CheckedScalarExpr scalarType (CheckedPath root path) loc)
  EPath loc _ _ -> selectionFailure loc SelectionExpressionRootUnknown "selection expressions do not admit aggregate reg/cmd roots"
  ELiteral loc (LiteralText value) -> literal loc SelectionText (CheckedTextLiteral value)
  ELiteral loc (LiteralIntegral value) -> case expected of
    Just SelectionNatural
      | value < 0 -> selectionFailure loc SelectionExpressionTypeMismatch "Natural selection literal must not be negative"
      | otherwise -> literal loc SelectionNatural (CheckedIntegralLiteral value)
    Just expectedType | expectedType `elem` [SelectionInt, SelectionInteger] -> literal loc expectedType (CheckedIntegralLiteral value)
    _ -> selectionFailure loc SelectionExpressionTypeMismatch "integral selection literal needs an Int, Integer, or Natural operand"
  ELiteral loc (LiteralBool value) -> literal loc SelectionBool (CheckedBoolLiteral value)
  ELiteral loc LiteralQualified {} -> selectionFailure loc SelectionOperatorUnsupported "qualified enum literals are not admitted in declarative router selection"
  ELiteral loc LiteralId {} -> selectionFailure loc SelectionOperatorUnsupported "nominal ID literals are not admitted in declarative router selection"
  EAtom (ABool value) -> literal noLoc SelectionBool (CheckedBoolLiteral value)
  EAtom (AName name) -> selectionFailure noLoc SelectionExpressionRootUnknown ("selection expression root must be input or row, found '" <> name <> "'")
  EAnd left right -> booleanNode CheckedAnd left right
  EOr left right -> booleanNode CheckedOr left right
  ECmp operator left right -> comparisonNode operator left right
  EAdd loc _ _ -> unsupportedArithmetic loc
  ESubtract loc _ _ -> unsupportedArithmetic loc
  EMultiply loc _ _ -> unsupportedArithmetic loc
  where
    literal loc scalarType node = do
      requireExpected loc expected scalarType
      pure (CheckedScalarExpr scalarType node loc)

    booleanNode constructor left right = do
      checkedLeft <- resolveSelectionExpr graph inputType rowType (Just SelectionBool) left
      checkedRight <- resolveSelectionExpr graph inputType rowType (Just SelectionBool) right
      let loc = exprLoc expression
      requireExpected loc expected SelectionBool
      pure (CheckedScalarExpr SelectionBool (constructor checkedLeft checkedRight) loc)

    comparisonNode operator left right = do
      (checkedLeft, checkedRight) <- case left of
        ELiteral _ LiteralIntegral {} -> do
          rightValue <- resolveSelectionExpr graph inputType rowType Nothing right
          leftValue <- resolveSelectionExpr graph inputType rowType (Just ((.valueType) rightValue)) left
          pure (leftValue, rightValue)
        _ -> do
          leftValue <- resolveSelectionExpr graph inputType rowType Nothing left
          rightValue <- resolveSelectionExpr graph inputType rowType (Just ((.valueType) leftValue)) right
          pure (leftValue, rightValue)
      if (.valueType) checkedLeft == (.valueType) checkedRight
        then pure ()
        else selectionFailure (exprLoc expression) SelectionExpressionTypeMismatch "comparison operands have different scalar types"
      if comparisonAdmitted operator ((.valueType) checkedLeft)
        then pure ()
        else selectionFailure (exprLoc expression) SelectionOperatorUnsupported ("comparison operator is not admitted for " <> scalarTypeText ((.valueType) checkedLeft))
      requireExpected (exprLoc expression) expected SelectionBool
      pure (CheckedScalarExpr SelectionBool (CheckedCompare operator checkedLeft checkedRight) (exprLoc expression))

    unsupportedArithmetic loc = selectionFailure loc SelectionOperatorUnsupported "arithmetic operators are not admitted in declarative router selection"

resolvePath :: TypeGraph -> Loc -> ResolvedTypeExpr -> [Name] -> Either (NonEmpty RouterSelectionDiagnostic) (SelectionScalarType, [CheckedSelectionPathSegment])
resolvePath graph diagnosticLoc = go []
  where
    go segments currentType remaining = case remaining of
      [] -> case selectionTypeFromResolved currentType of
        Just scalarType -> Right (scalarType, reverse segments)
        Nothing -> selectionFailure diagnosticLoc SelectionExpressionTypeMismatch "selection path does not end at a supported scalar"
      name : rest -> case currentType of
        RRef owner -> case Map.lookup owner ((.declarations) graph) of
          Just (ResolvedStructural _ (RRecord _ _ fields)) -> case find ((== name) . (.haskell)) fields of
            Nothing -> selectionFailure diagnosticLoc SelectionExpressionFieldUnknown ("mapped record '" <> unMappedKey owner <> "' has no field '" <> name <> "'")
            Just field
              | (.presence) field /= PRequired -> selectionFailure diagnosticLoc SelectionExpressionFieldOptional ("field '" <> name <> "' is optional; selection paths must be total")
              | ROptional {} <- (.valueType) field -> selectionFailure diagnosticLoc SelectionExpressionFieldOptional ("field '" <> name <> "' is nullable; selection paths must be total")
              | otherwise -> go (CheckedSelectionPathSegment name ((.key) field) owner : segments) ((.valueType) field) rest
          _ -> selectionFailure diagnosticLoc SelectionQueryRowNotStructural ("mapped type '" <> unMappedKey owner <> "' is not a structural record")
        _ -> selectionFailure diagnosticLoc SelectionExpressionFieldUnknown ("cannot project field '" <> name <> "' through a scalar value")

requirePositive :: Loc -> RouterSelectionDiagnosticCode -> Text -> Natural -> Either (NonEmpty RouterSelectionDiagnostic) Natural
requirePositive diagnosticLoc diagnosticCode owner value
  | value > 0 = Right value
  | otherwise = selectionFailure diagnosticLoc diagnosticCode (owner <> " must be positive")

requireExact :: Loc -> RouterSelectionDiagnosticCode -> Text -> Name -> value -> Name -> Either (NonEmpty RouterSelectionDiagnostic) value
requireExact diagnosticLoc diagnosticCode owner admitted checked actual
  | actual == admitted = Right checked
  | otherwise = selectionFailure diagnosticLoc diagnosticCode (owner <> " must be " <> admitted <> ", found " <> actual)

requireExpected :: Loc -> Maybe SelectionScalarType -> SelectionScalarType -> Either (NonEmpty RouterSelectionDiagnostic) ()
requireExpected _ Nothing _ = Right ()
requireExpected diagnosticLoc (Just expected) actual
  | expected == actual = Right ()
  | otherwise = selectionFailure diagnosticLoc SelectionExpressionTypeMismatch ("expected " <> scalarTypeText expected <> ", found " <> scalarTypeText actual)

requireScalarType :: Loc -> RouterSelectionDiagnosticCode -> Text -> SelectionScalarType -> CheckedScalarExpr -> Either (NonEmpty RouterSelectionDiagnostic) ()
requireScalarType diagnosticLoc diagnosticCode owner expected expression
  | (.valueType) expression == expected = Right ()
  | otherwise = selectionFailure diagnosticLoc diagnosticCode (owner <> " must have type " <> scalarTypeText expected <> ", found " <> scalarTypeText ((.valueType) expression))

liftTypeGraph :: Loc -> Either TypeGraphError value -> Either (NonEmpty RouterSelectionDiagnostic) value
liftTypeGraph diagnosticLoc = either (\err -> selectionFailure diagnosticLoc SelectionExpressionTypeMismatch ("mapped type could not be resolved: " <> T.pack (show err))) Right

selectionTypeFromResolved :: ResolvedTypeExpr -> Maybe SelectionScalarType
selectionTypeFromResolved = \case
  RText -> Just SelectionText
  RInt -> Just SelectionInt
  RInteger -> Just SelectionInteger
  RBool -> Just SelectionBool
  RNatural -> Just SelectionNatural
  RTime -> Just SelectionTime
  RJson -> Nothing
  ROptional {} -> Nothing
  RList {} -> Nothing
  RMap {} -> Nothing
  RRef {} -> Nothing

selectionTypeFromAggregate :: ResolvedAggregateType -> Maybe SelectionScalarType
selectionTypeFromAggregate = \case
  AggregateText -> Just SelectionText
  AggregateInt -> Just SelectionInt
  AggregateInteger -> Just SelectionInteger
  AggregateBool -> Just SelectionBool
  AggregateTime -> Just SelectionTime
  AggregateNatural -> Just SelectionNatural
  AggregateNominal {} -> Nothing
  AggregateVertex {} -> Nothing
  AggregateMapped {} -> Nothing

comparisonAdmitted :: CmpOp -> SelectionScalarType -> Bool
comparisonAdmitted operator scalarType = case operator of
  OpEq -> True
  OpNeq -> True
  OpLt -> ordered
  OpLe -> ordered
  OpGt -> ordered
  OpGe -> ordered
  where
    ordered = scalarType `elem` [SelectionInt, SelectionInteger, SelectionNatural, SelectionTime]

scalarTypeText :: SelectionScalarType -> Text
scalarTypeText = \case
  SelectionText -> "Text"
  SelectionInt -> "Int"
  SelectionInteger -> "Integer"
  SelectionBool -> "Bool"
  SelectionNatural -> "Natural"
  SelectionTime -> "Time"

selectionFailure :: Loc -> RouterSelectionDiagnosticCode -> Text -> Either (NonEmpty RouterSelectionDiagnostic) value
selectionFailure diagnosticLoc diagnosticCode diagnosticMessage = Left (RouterSelectionDiagnostic diagnosticLoc diagnosticCode diagnosticMessage :| [])

duplicates :: (Ord value) => [value] -> [value]
duplicates values = Map.keys (Map.filter (> (1 :: Int)) (Map.fromListWith (+) [(value, 1 :: Int) | value <- values]))

-- | SHA-256 over a length-prefixed encoding of checked semantic evidence.
-- Locations, comments, formatting, identity, declared version, and the digest
-- field itself are intentionally absent.
routerSelectionFingerprint :: CheckedRouterSelection -> Text
routerSelectionFingerprint = hexDigest . SHA256.hash . Text.encodeUtf8 . canonicalSelection

canonicalSelection :: CheckedRouterSelection -> Text
canonicalSelection selection =
  tuple
    [ atom "keiro-dsl/router-selection/1",
      atom ((.name) ((.query) selection)),
      canonicalResolvedType ((.inputType) ((.query) selection)),
      canonicalResolvedType ((.resultType) ((.query) selection)),
      canonicalScalar ((.key) selection),
      canonicalScalar ((.predicate) selection),
      canonicalScalar ((.recipient) selection),
      tuple [tuple [atom name, canonicalScalar expression] | (name, expression) <- Map.toAscList ((.commandFields) selection)],
      atom ((.target) selection),
      atom ((.command) selection),
      atom (T.pack (show ((.limit) selection))),
      atom "order:target-stream",
      atom "dedupe:target-stream",
      atom ("empty:" <> T.pack (show ((.emptyPolicy) selection))),
      atom ("failure:" <> T.pack (show ((.failurePolicy) selection))),
      atom "redelivery:stable-union",
      atom "partial:retain-successes"
    ]

canonicalScalar :: CheckedScalarExpr -> Text
canonicalScalar expression = tuple [atom (scalarTypeText ((.valueType) expression)), node ((.node) expression)]
  where
    node = \case
      CheckedPath root segments -> tuple (atom (T.pack (show root)) : map segment segments)
      CheckedTextLiteral value -> tuple [atom "text", atom value]
      CheckedIntegralLiteral value -> tuple [atom "integral", atom (T.pack (show value))]
      CheckedBoolLiteral value -> tuple [atom "bool", atom (if value then "true" else "false")]
      CheckedCompare operator left right -> tuple [atom (T.pack (show operator)), canonicalScalar left, canonicalScalar right]
      CheckedAnd left right -> tuple [atom "and", canonicalScalar left, canonicalScalar right]
      CheckedOr left right -> tuple [atom "or", canonicalScalar left, canonicalScalar right]
    segment value = tuple [atom (unMappedKey ((.owner) value)), atom ((.field) value), atom ((.wireKey) value)]

canonicalResolvedType :: ResolvedTypeExpr -> Text
canonicalResolvedType = \case
  RText -> atom "Text"
  RInt -> atom "Int"
  RInteger -> atom "Integer"
  RBool -> atom "Bool"
  RNatural -> atom "Natural"
  RTime -> atom "Time"
  RJson -> atom "Json"
  ROptional value -> tuple [atom "Optional", canonicalResolvedType value]
  RList value -> tuple [atom "List", canonicalResolvedType value]
  RMap value -> tuple [atom "Map", canonicalResolvedType value]
  RRef key -> tuple [atom "Ref", atom (unMappedKey key)]

tuple :: [Text] -> Text
tuple values = "[" <> T.concat values <> "]"

atom :: Text -> Text
atom value = T.pack (show (T.length value)) <> ":" <> value

hexDigest :: BS.ByteString -> Text
hexDigest = T.pack . concatMap byteHex . BS.unpack
  where
    byteHex byte = case showHex byte "" of
      [digit] -> ['0', digit]
      digits -> digits
