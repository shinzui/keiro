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
import Keiro.Dsl.SemanticContract (EffectiveLanguageContract, effectiveContractLanguageVersion)
import Keiro.Dsl.TypeGraph
import Numeric (showHex)
import Numeric.Natural (Natural)

data CheckedReadModelQuery = CheckedReadModelQuery
  { checkedQueryName :: !Name,
    checkedQueryInputType :: !ResolvedTypeExpr,
    checkedQueryResultType :: !ResolvedTypeExpr
  }
  deriving stock (Eq, Show, Generic)

data CheckedMappedExpr = CheckedMappedExpr
  { checkedMappedExprRoot :: !SelectionRoot,
    checkedMappedExprType :: !ResolvedTypeExpr
  }
  deriving stock (Eq, Show, Generic)

data CheckedMappedType = CheckedMappedType
  { checkedMappedTypeKey :: !MappedKey,
    checkedMappedTypeConstructor :: !Name,
    checkedMappedTypeFields :: ![ResolvedWireField]
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
  { checkedPathField :: !Name,
    checkedPathWireKey :: !Text,
    checkedPathOwner :: !MappedKey
  }
  deriving stock (Eq, Ord, Show, Generic)

data CheckedScalarExpr = CheckedScalarExpr
  { checkedScalarType :: !SelectionScalarType,
    checkedScalarNode :: !CheckedScalarNode,
    checkedScalarLoc :: !Loc
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
  { checkedIdentity :: !Text,
    checkedVersion :: !Natural,
    checkedQuery :: !CheckedReadModelQuery,
    checkedInputBinding :: !CheckedMappedExpr,
    checkedRowBinding :: !CheckedMappedType,
    checkedKey :: !CheckedScalarExpr,
    checkedPredicate :: !CheckedScalarExpr,
    checkedRecipient :: !CheckedScalarExpr,
    checkedCommandFields :: !(Map Name CheckedScalarExpr),
    checkedTarget :: !Name,
    checkedCommand :: !Name,
    checkedLimit :: !Natural,
    checkedOrder :: !CheckedSelectionOrder,
    checkedDedupe :: !CheckedSelectionDedupe,
    checkedEmptyPolicy :: !CheckedEmptySelectionPolicy,
    checkedFailurePolicy :: !CheckedSelectionFailurePolicy,
    checkedRedeliveryPolicy :: !CheckedRedeliveryPolicy,
    checkedPartialPolicy :: !CheckedPartialDispatchPolicy,
    checkedFingerprint :: !Text,
    checkedUseSites :: ![UseSite]
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
  { selectionDiagnosticLoc :: !Loc,
    selectionDiagnosticCode :: !RouterSelectionDiagnosticCode,
    selectionDiagnosticMessage :: !Text
  }
  deriving stock (Eq, Show, Generic)

checkRouterSelection :: EffectiveLanguageContract -> TypeGraph -> Spec -> RouterNode -> Either (NonEmpty RouterSelectionDiagnostic) CheckedRouterSelection
checkRouterSelection languageContract graph spec router = case rvSource (rtResolve router) of
  ResolveReadModel {} -> selectionFailure (rvLoc (rtResolve router)) SelectionNotDeclarative "custom-unverified router selection has no checked declarative contract"
  ResolveHole -> selectionFailure (rvLoc (rtResolve router)) SelectionNotDeclarative "custom-unverified router selection has no checked declarative contract"
  ResolveDeclarative declaration -> checkDeclaration declaration
  where
    symbols = aggregateSymbolsFromGraph graph spec

    checkDeclaration declaration = do
      requireFeature declaration
      identity <- requireIdentity declaration
      version <- requirePositive (rsVersionLoc declaration) SelectionVersionInvalid "selection version" (rsVersion declaration)
      recipientLimit <- case rsLimit declaration of
        Nothing -> selectionFailure (rsLoc declaration) SelectionRecipientLimitMissing "declarative router selection requires a positive max-recipients"
        Just (value, valueLoc) -> requirePositive valueLoc SelectionRecipientLimitInvalid "max-recipients" value
      order <- requireExact (rsOrderLoc declaration) SelectionOrderUnsupported "order" "target-stream" CheckedOrderByTargetStream (rsOrder declaration)
      dedupe <- requireExact (rsDedupeLoc declaration) SelectionDedupeUnsupported "dedupe" "target-stream" CheckedDedupeByTargetStream (rsDedupe declaration)
      emptyPolicy <- checkEmptyPolicy declaration
      failurePolicy <- checkFailurePolicy declaration
      redelivery <- requireExact (rsRedeliveryLoc declaration) SelectionRedeliveryUnsupported "redelivery" "stable-union" CheckedStableUnion (rsRedelivery declaration)
      partial <- requireExact (rsPartialLoc declaration) SelectionPartialDispatchUnsupported "partial" "retain-successes" CheckedRetainSuccesses (rsPartial declaration)
      (query, inputBinding, rowBinding) <- checkQuery declaration
      keyExpression <- resolveSelectionExpr graph (checkedMappedExprType inputBinding) rowBinding Nothing (EPath (inLoc (rtInput router)) UnqualifiedRoot ["input", corrField (rtKey router)])
      requireScalarType (inLoc (rtInput router)) SelectionQueryInputBindingInvalid "router key" SelectionText keyExpression
      predicate <- resolveSelectionExpr graph (checkedMappedExprType inputBinding) rowBinding Nothing (rsPredicate declaration)
      requireScalarType (exprLoc (rsPredicate declaration)) SelectionPredicateNotBool "where predicate" SelectionBool predicate
      recipient <- resolveSelectionExpr graph (checkedMappedExprType inputBinding) rowBinding Nothing (rsRecipient declaration)
      requireScalarType (exprLoc (rsRecipient declaration)) SelectionRecipientNotText "recipient expression" SelectionText recipient
      (targetAggregate, targetCommand) <- resolveTargetCommand
      commandFields <- checkCommandMappings graph inputBinding rowBinding targetAggregate targetCommand
      let initial =
            CheckedRouterSelection
              { checkedIdentity = identity,
                checkedVersion = version,
                checkedQuery = query,
                checkedInputBinding = inputBinding,
                checkedRowBinding = rowBinding,
                checkedKey = keyExpression,
                checkedPredicate = predicate,
                checkedRecipient = recipient,
                checkedCommandFields = commandFields,
                checkedTarget = rtTarget router,
                checkedCommand = rdCommand (rtDispatch router),
                checkedLimit = recipientLimit,
                checkedOrder = order,
                checkedDedupe = dedupe,
                checkedEmptyPolicy = emptyPolicy,
                checkedFailurePolicy = failurePolicy,
                checkedRedeliveryPolicy = redelivery,
                checkedPartialPolicy = partial,
                checkedFingerprint = "",
                checkedUseSites = queryUseSites (rsQuery declaration)
              }
      pure initial {checkedFingerprint = routerSelectionFingerprint initial}

    requireFeature declaration
      | languageSupportsFeature (effectiveContractLanguageVersion languageContract) DeclarativeRouterSelectionSyntax = Right ()
      | otherwise = selectionFailure (rsLoc declaration) SelectionCapabilityUnavailable "declarative router selection requires language keiro-dsl 5"

    requireIdentity declaration
      | T.null (T.strip (rsIdentity declaration)) = selectionFailure (rsIdentityLoc declaration) SelectionIdentityEmpty "selection identity must not be empty"
      | otherwise = Right (rsIdentity declaration)

    checkEmptyPolicy declaration = case rsEmptyPolicy declaration of
      SelectionAck -> Right CheckedEmptyAck
      SelectionRetry -> Right CheckedEmptyRetry
      SelectionDeadLetter -> Right CheckedEmptyDeadLetter
      SelectionHalt -> Right CheckedEmptyHalt

    checkFailurePolicy declaration = case rsFailurePolicy declaration of
      SelectionAck -> selectionFailure (rsFailurePolicyLoc declaration) SelectionFailureAckForbidden "selection failure cannot acknowledge the source message"
      SelectionRetry -> Right CheckedFailureRetry
      SelectionDeadLetter -> Right CheckedFailureDeadLetter
      SelectionHalt -> Right CheckedFailureHalt

    checkQuery declaration = do
      readModel <- case find ((== rsQuery declaration) . rmName) readModels of
        Nothing -> selectionFailure (rsQueryLoc declaration) SelectionQueryUnknown ("selection query names undeclared readmodel '" <> rsQuery declaration <> "'")
        Just value -> Right value
      queryTypesDeclaration <- maybe (selectionFailure (rsQueryLoc declaration) SelectionQueryContractMissing ("readmodel '" <> rmName readModel <> "' has no typed query input/result contract")) Right (queryTypes readModel)
      if rsQueryInput declaration == "input"
        then pure ()
        else selectionFailure (rsQueryInputLoc declaration) SelectionQueryInputBindingInvalid "selection query input must be the router input binding `input`"
      queryInput <- liftTypeGraph (rsQueryLoc declaration) (resolveTypeExpression graph ("readmodel " <> rmName readModel <> " query input") (inputLoc queryTypesDeclaration) (input queryTypesDeclaration))
      queryResult <- liftTypeGraph (rsQueryLoc declaration) (resolveTypeExpression graph ("readmodel " <> rmName readModel <> " query result") (resultLoc queryTypesDeclaration) (result queryTypesDeclaration))
      routerInputExpression <- maybe (selectionFailure (inLoc (rtInput router)) SelectionQueryInputBindingInvalid "declarative router input must name its mapped query-input type with `input Name : Type`") Right (inType (rtInput router))
      routerInput <- liftTypeGraph (inLoc (rtInput router)) (resolveTypeExpression graph ("router " <> rtId router <> " input") (inLoc (rtInput router)) routerInputExpression)
      if routerInput == queryInput
        then pure ()
        else selectionFailure (inLoc (rtInput router)) SelectionQueryInputTypeMismatch ("router input type does not match readmodel '" <> rmName readModel <> "' query input")
      _ <- structuralRecord (inLoc (rtInput router)) SelectionQueryInputBindingInvalid "router query input" routerInput
      rowBinding <- case queryResult of
        RList rowType -> structuralRecord (resultLoc queryTypesDeclaration) SelectionQueryRowNotStructural "query result row" rowType
        _ -> selectionFailure (resultLoc queryTypesDeclaration) SelectionQueryResultNotList "declarative router query result must be List Row"
      pure
        ( CheckedReadModelQuery (rmName readModel) queryInput queryResult,
          CheckedMappedExpr SelectionInput queryInput,
          rowBinding
        )

    structuralRecord diagnosticLoc diagnosticCode owner = \case
      RRef key -> case Map.lookup key (tgDeclarations graph) of
        Just (ResolvedStructural _ (RRecord constructor _ fields)) -> Right (CheckedMappedType key constructor fields)
        _ -> selectionFailure diagnosticLoc diagnosticCode (owner <> " must be a mapped structural record")
      _ -> selectionFailure diagnosticLoc diagnosticCode (owner <> " must be a mapped structural record")

    resolveTargetCommand = case [aggregate | NAggregate aggregate <- specNodes spec, aggName aggregate == rtTarget router] of
      [aggregate] -> case [command | command <- aggCommands aggregate, cmdName command == rdCommand (rtDispatch router)] of
        [command] -> Right (aggregate, command)
        _ -> selectionFailure (rdLoc (rtDispatch router)) SelectionCommandUnknown ("target aggregate '" <> rtTarget router <> "' has no unique command '" <> rdCommand (rtDispatch router) <> "'")
      _ -> selectionFailure (rtLoc router) SelectionTargetAmbiguous ("declarative router target '" <> rtTarget router <> "' does not identify exactly one aggregate")

    checkCommandMappings selectionGraph inputBinding rowBinding aggregate command = do
      let bindings = rdFields (rtDispatch router)
          duplicateNames = duplicates (map fbName bindings)
          expectedNames = sort (map aggregateFieldName (cmdFields command))
          actualNames = sort (map fbName bindings)
      case duplicateNames of
        duplicateName : _ -> selectionFailure (rdLoc (rtDispatch router)) SelectionCommandMappingDuplicate ("dispatch field '" <> duplicateName <> "' is mapped more than once")
        [] -> pure ()
      if expectedNames == actualNames
        then pure ()
        else selectionFailure (rdLoc (rtDispatch router)) SelectionCommandMappingIncomplete ("dispatch mapping must bind every field of command '" <> cmdName command <> "' exactly once")
      Map.fromList <$> traverse (checkBinding selectionGraph inputBinding rowBinding aggregate bindings) (cmdFields command)

    checkBinding selectionGraph inputBinding rowBinding aggregate bindings field = do
      binding <- case find ((== aggregateFieldName field) . fbName) bindings of
        Just value -> Right value
        Nothing -> selectionFailure (rdLoc (rtDispatch router)) SelectionCommandMappingIncomplete ("missing dispatch mapping for field '" <> aggregateFieldName field <> "'")
      expression <- resolveBinding selectionGraph inputBinding rowBinding (rdLoc (rtDispatch router)) binding
      expectedAggregateType <- case inferAggregateFieldType symbols aggregate CommandFieldUse field of
        Left _ -> selectionFailure (aggregateFieldLoc field) SelectionCommandMappingTypeMismatch ("command field '" <> aggregateFieldName field <> "' has no selection-compatible scalar type")
        Right value -> Right value
      expected <- maybe (selectionFailure (aggregateFieldLoc field) SelectionCommandMappingTypeMismatch ("command field '" <> aggregateFieldName field <> "' is not a supported scalar selection target")) Right (selectionTypeFromAggregate expectedAggregateType)
      requireScalarType (checkedScalarLoc expression) SelectionCommandMappingTypeMismatch ("command field '" <> aggregateFieldName field <> "'") expected expression
      pure (aggregateFieldName field, expression)

    queryUseSites queryName =
      [ useSite
      | useSite <- tgUseSites graph,
        case useSite of
          RootReadModelQueryInput name _ -> name == queryName
          RootReadModelQueryResult name _ -> name == queryName
          _ -> False
      ]

    readModels = [readModel | NReadModel readModel <- specNodes spec]

resolveBinding :: TypeGraph -> CheckedMappedExpr -> CheckedMappedType -> Loc -> FieldBinding -> Either (NonEmpty RouterSelectionDiagnostic) CheckedScalarExpr
resolveBinding graph inputBinding rowBinding diagnosticLoc binding =
  resolveSelectionExpr graph (checkedMappedExprType inputBinding) rowBinding Nothing expression
  where
    expression = case fbValue binding of
      Nothing -> EPath diagnosticLoc UnqualifiedRoot ["input", fbName binding]
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
      "row" -> Right (SelectionRow, RRef (checkedMappedTypeKey rowType))
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
          leftValue <- resolveSelectionExpr graph inputType rowType (Just (checkedScalarType rightValue)) left
          pure (leftValue, rightValue)
        _ -> do
          leftValue <- resolveSelectionExpr graph inputType rowType Nothing left
          rightValue <- resolveSelectionExpr graph inputType rowType (Just (checkedScalarType leftValue)) right
          pure (leftValue, rightValue)
      if checkedScalarType checkedLeft == checkedScalarType checkedRight
        then pure ()
        else selectionFailure (exprLoc expression) SelectionExpressionTypeMismatch "comparison operands have different scalar types"
      if comparisonAdmitted operator (checkedScalarType checkedLeft)
        then pure ()
        else selectionFailure (exprLoc expression) SelectionOperatorUnsupported ("comparison operator is not admitted for " <> scalarTypeText (checkedScalarType checkedLeft))
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
      fieldName : rest -> case currentType of
        RRef owner -> case Map.lookup owner (tgDeclarations graph) of
          Just (ResolvedStructural _ (RRecord _ _ fields)) -> case find ((== fieldName) . rwfHaskell) fields of
            Nothing -> selectionFailure diagnosticLoc SelectionExpressionFieldUnknown ("mapped record '" <> unMappedKey owner <> "' has no field '" <> fieldName <> "'")
            Just field
              | rwfPresence field /= PRequired -> selectionFailure diagnosticLoc SelectionExpressionFieldOptional ("field '" <> fieldName <> "' is optional; selection paths must be total")
              | ROptional {} <- rwfType field -> selectionFailure diagnosticLoc SelectionExpressionFieldOptional ("field '" <> fieldName <> "' is nullable; selection paths must be total")
              | otherwise -> go (CheckedSelectionPathSegment fieldName (rwfKey field) owner : segments) (rwfType field) rest
          _ -> selectionFailure diagnosticLoc SelectionQueryRowNotStructural ("mapped type '" <> unMappedKey owner <> "' is not a structural record")
        _ -> selectionFailure diagnosticLoc SelectionExpressionFieldUnknown ("cannot project field '" <> fieldName <> "' through a scalar value")

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
  | checkedScalarType expression == expected = Right ()
  | otherwise = selectionFailure diagnosticLoc diagnosticCode (owner <> " must have type " <> scalarTypeText expected <> ", found " <> scalarTypeText (checkedScalarType expression))

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
      atom (checkedQueryName (checkedQuery selection)),
      canonicalResolvedType (checkedQueryInputType (checkedQuery selection)),
      canonicalResolvedType (checkedQueryResultType (checkedQuery selection)),
      canonicalScalar (checkedKey selection),
      canonicalScalar (checkedPredicate selection),
      canonicalScalar (checkedRecipient selection),
      tuple [tuple [atom fieldName, canonicalScalar expression] | (fieldName, expression) <- Map.toAscList (checkedCommandFields selection)],
      atom (checkedTarget selection),
      atom (checkedCommand selection),
      atom (T.pack (show (checkedLimit selection))),
      atom "order:target-stream",
      atom "dedupe:target-stream",
      atom ("empty:" <> T.pack (show (checkedEmptyPolicy selection))),
      atom ("failure:" <> T.pack (show (checkedFailurePolicy selection))),
      atom "redelivery:stable-union",
      atom "partial:retain-successes"
    ]

canonicalScalar :: CheckedScalarExpr -> Text
canonicalScalar expression = tuple [atom (scalarTypeText (checkedScalarType expression)), node (checkedScalarNode expression)]
  where
    node = \case
      CheckedPath root segments -> tuple (atom (T.pack (show root)) : map segment segments)
      CheckedTextLiteral value -> tuple [atom "text", atom value]
      CheckedIntegralLiteral value -> tuple [atom "integral", atom (T.pack (show value))]
      CheckedBoolLiteral value -> tuple [atom "bool", atom (if value then "true" else "false")]
      CheckedCompare operator left right -> tuple [atom (T.pack (show operator)), canonicalScalar left, canonicalScalar right]
      CheckedAnd left right -> tuple [atom "and", canonicalScalar left, canonicalScalar right]
      CheckedOr left right -> tuple [atom "or", canonicalScalar left, canonicalScalar right]
    segment value = tuple [atom (unMappedKey (checkedPathOwner value)), atom (checkedPathField value), atom (checkedPathWireKey value)]

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
