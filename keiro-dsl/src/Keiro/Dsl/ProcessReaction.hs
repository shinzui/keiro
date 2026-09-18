{-# OPTIONS_GHC -Werror=incomplete-patterns #-}

-- | Checked Language 6 process-reaction semantics.
module Keiro.Dsl.ProcessReaction
  ( CheckedProcessReaction (..),
    CheckedReactionArm (..),
    CheckedReactionGuard (..),
    CheckedFollowUp (..),
    CheckedReactionTimer (..),
    ProcessReactionDiagnosticCode (..),
    ProcessReactionDiagnostic (..),
    checkProcessReaction,
    processReactionFingerprint,
    processReactionFingerprintFrom,
  )
where

import Crypto.Hash.SHA256 qualified as SHA256
import Data.ByteString qualified as BS
import Data.List (find, group, sort)
import Data.List.NonEmpty (NonEmpty (..))
import Data.List.NonEmpty qualified as NE
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as Text
import Data.Word (Word8)
import Keiro.Dsl.AggregateType
import Keiro.Dsl.CanonicalEncoding (canonicalReactionSurface)
import Keiro.Dsl.Grammar
import Keiro.Dsl.NominalType (NominalRepresentation (..), ResolvedNominalType (..))
import Keiro.Dsl.SemanticContract (EffectiveLanguageContract)
import Keiro.Dsl.TypeGraph (TypeGraph)
import Numeric (showHex)
import Numeric.Natural (Natural)

data CheckedReactionGuard
  = CheckedUnconditional
  | CheckedWhen !Expr
  | CheckedOtherwise
  deriving stock (Eq, Show)

newtype CheckedFollowUp = CheckedFollowUp {syntax :: FollowUp}
  deriving stock (Eq, Show)

data CheckedReactionArm = CheckedReactionArm
  { input :: !Name,
    ordinal :: !Int,
    guard :: !CheckedReactionGuard,
    body :: !ArmBody
  }
  deriving stock (Eq, Show)

newtype CheckedReactionTimer = CheckedReactionTimer {syntax :: ReactionTimerNode}
  deriving stock (Eq, Show)

data CheckedProcessReaction = CheckedProcessReaction
  { version :: !Natural,
    inputs :: !(NonEmpty InputDecl),
    arms :: ![CheckedReactionArm],
    timers :: ![CheckedReactionTimer],
    fingerprint :: !Text,
    verification :: !Text,
    holeObligations :: ![Text]
  }
  deriving stock (Eq, Show)

data ProcessReactionDiagnosticCode
  = ProcessReactionUnknownInput
  | ProcessInputDuplicateDeclaration
  | ProcessTimerDuplicateName
  | ProcessReactionGuardNotBoolean
  | ProcessStateAccessUnsupported
  | ProcessReactionInputUnhandled
  | ProcessReactionDuplicateInput
  | ProcessReactionOtherwiseMissing
  | ProcessReactionOtherwiseUnreachable
  | ProcessTimerPrefixCollision
  | ProcessScheduleUnknownTimer
  | ProcessCancelUnknownTimer
  | ProcessSchedulePayloadIncomplete
  | ProcessTimerPolicyMissing
  | ProcessTimerPolicyUnused
  | ProcessAcceptedArmRequiresEvent
  | ProcessSilentArmMissing
  | ProcessAcceptedArmUnverified
  | ProcessBindingTypeMismatch
  deriving stock (Eq, Ord, Show, Enum, Bounded)

data ProcessReactionDiagnostic = ProcessReactionDiagnostic
  { loc :: !Loc,
    code :: !ProcessReactionDiagnosticCode,
    message :: !Text
  }
  deriving stock (Eq, Show)

checkProcessReaction :: EffectiveLanguageContract -> TypeGraph -> Spec -> ProcessNode -> Either (NonEmpty ProcessReactionDiagnostic) CheckedProcessReaction
checkProcessReaction _languageContract graph spec process = case (.body) process of
  LegacyProcessBody {} -> failure ((.loc) process) ProcessReactionUnknownInput "legacy process has no checked reaction body"
  ReactionProcessBody reaction -> do
    let symbols = aggregateSymbolsFromGraph graph spec
        inputList = NE.toList ((.inputs) reaction)
        inputNames = map (.name) inputList
        reactionList = NE.toList ((.reactions) reaction)
        reactionNames = map (.on) reactionList
        timerList = (.timers) reaction
        timerNames = map (.name) timerList
    requireNoDuplicate ProcessInputDuplicateDeclaration "input" ((.loc) process) inputNames
    requireNoDuplicate ProcessTimerDuplicateName "timer" ((.loc) process) timerNames
    requireNoDuplicate ProcessReactionDuplicateInput "on block" ((.loc) process) reactionNames
    case [node | node <- reactionList, (.on) node `notElem` inputNames] of
      node : _ -> failure ((.loc) node) ProcessReactionUnknownInput ("reaction names undeclared input '" <> (.on) node <> "'")
      [] -> pure ()
    case [input | input <- inputList, (.name) input `notElem` reactionNames] of
      input : _ -> failure ((.loc) input) ProcessReactionInputUnhandled ("input '" <> (.name) input <> "' has no on block")
      [] -> pure ()
    checkTimerPolicy reaction
    checkPrefixCollisions timerList
    checkedArms <- concat <$> traverse (checkReaction symbols inputList timerList) reactionList
    traverse_ (checkTimer symbols) timerList
    let holes =
          [ (.agg) ((.saga) process) <> "." <> (.command) advance <> " accepted-event proof"
          | arm <- checkedArms,
            ArmActions {advance = Just advance} <- [(.body) arm],
            Just _ <- [(.accepted) advance],
            armUnverified arm
          ]
        initial =
          CheckedProcessReaction
            { version = (.version) reaction,
              inputs = (.inputs) reaction,
              arms = checkedArms,
              timers = map CheckedReactionTimer timerList,
              fingerprint = "",
              verification = if null holes then "generated-declarative" else "custom-unverified",
              holeObligations = holes
            }
    pure initial {fingerprint = processReactionFingerprintFrom reaction}
  where
    aggregates = [aggregate | NAggregate aggregate <- (.nodes) spec]

    checkReaction symbols inputList timerList reactionNode = do
      input <- case find ((== (.on) reactionNode) . (.name)) inputList of
        Nothing -> failure ((.loc) reactionNode) ProcessReactionUnknownInput "reaction input is undeclared"
        Just value -> Right value
      checkTotality reactionNode
      traverse (checkArm symbols input timerList) (zip [0 ..] (NE.toList ((.arms) reactionNode)))

    checkTotality reactionNode = do
      let armList = NE.toList ((.arms) reactionNode)
          guards = map (.guard) armList
          otherwiseIndexes = [index | (index, OtherwiseArm) <- zip [0 ..] guards]
      case otherwiseIndexes of
        index : _ | index /= length guards - 1 -> failure ((.loc) (armList !! index)) ProcessReactionOtherwiseUnreachable "otherwise must be the final arm"
        _ -> pure ()
      if any isWhen guards && null otherwiseIndexes
        then failure ((.loc) reactionNode) ProcessReactionOtherwiseMissing "guarded reactions must end in otherwise"
        else pure ()
      where
        isWhen WhenArm {} = True
        isWhen _ = False

    checkArm symbols input timerList (ordinal, arm) = do
      checkedGuard <- case (.guard) arm of
        UnconditionalArm -> Right CheckedUnconditional
        OtherwiseArm -> Right CheckedOtherwise
        WhenArm expression -> checkGuard symbols input expression >> Right (CheckedWhen expression)
      checkArmBody symbols input timerList ((.body) arm)
      pure CheckedReactionArm {input = (.name) input, ordinal, guard = checkedGuard, body = (.body) arm}

    checkArmBody _ _ _ NoAction = Right ()
    checkArmBody symbols input timerList ArmActions {advance, followUps} = do
      maybe (pure ()) (checkAdvance symbols input) advance
      traverse_ (checkFollowUp symbols input timerList) followUps
      case advance >>= (.accepted) of
        Nothing -> pure ()
        Just acceptedFollowUps -> traverse_ (checkFollowUp symbols input timerList) acceptedFollowUps

    checkAdvance symbols input advance = do
      sagaAggregate <- requireAggregate ((.loc) advance) ((.agg) ((.saga) process))
      command <- requireCommand ((.loc) advance) sagaAggregate ((.command) advance)
      checkBindings symbols input sagaAggregate command ((.loc) advance) ((.fields) advance)
      case (.accepted) advance of
        Nothing -> pure ()
        Just _ -> do
          if (.silentNoAction) advance
            then pure ()
            else failure ((.loc) advance) ProcessSilentArmMissing "accepted follow-ups require silent no-action"
          let matching = [transition | transition <- (.transitions) sagaAggregate, (.command) transition == (.command) advance, (.mode) transition == TmLive]
          case [transition | transition <- matching, (.implementation) transition == HoleImplementation] of
            _ : _ -> failure ((.loc) advance) ProcessAcceptedArmUnverified "accepted follow-ups cannot be verified for a hole-owned saga transition"
            [] -> pure ()
          case [transition | transition <- matching, accepts transition && null ((.emits) transition)] of
            _ : _ -> failure ((.loc) advance) ProcessAcceptedArmRequiresEvent "every accepting saga transition must emit an event before it can guard accepted follow-ups"
            [] -> pure ()

    accepts transition = case (.outcome) transition of
      Just OutcomeRejected {} -> False
      Just OutcomeNoOp {} -> False
      Just OutcomeAccepted {} -> True
      Nothing -> True

    checkFollowUp symbols input timerList = \case
      FollowDispatch dispatch -> do
        aggregate <- requireAggregate ((.loc) dispatch) ((.target) dispatch)
        command <- requireCommand ((.loc) dispatch) aggregate ((.command) dispatch)
        checkBindings symbols input aggregate command ((.loc) dispatch) ((.fields) dispatch)
      FollowSchedule schedule -> case find ((== (.timer) schedule) . (.name)) timerList of
        Nothing -> failure ((.loc) schedule) ProcessScheduleUnknownTimer ("schedule names undeclared timer '" <> (.timer) schedule <> "'")
        Just timer -> do
          checkSchedulePayload symbols input timer schedule
          requireInputType symbols input ((.loc) schedule) ((.field) ((.fireAt) schedule)) >>= requireExactType ((.loc) schedule) AggregateTime
      FollowCancel timerName loc ->
        if timerName `elem` map (.name) timerList
          then Right ()
          else failure loc ProcessCancelUnknownTimer ("cancel names undeclared timer '" <> timerName <> "'")

    checkSchedulePayload symbols input timer schedule = do
      let required = [name | PayloadTyped name _ <- (.payload) timer]
          actual = map (.name) ((.bindings) schedule)
      case [name | name <- required, name `notElem` actual] of
        name : _ -> failure ((.loc) schedule) ProcessSchedulePayloadIncomplete ("schedule omits typed payload field '" <> name <> "'")
        [] -> pure ()
      traverse_ (checkPayloadBinding symbols input timer) ((.bindings) schedule)

    checkPayloadBinding symbols input timer binding = case find ((== (.name) binding) . payloadName) ((.payload) timer) of
      Nothing -> pure ()
      Just PayloadConstant {} -> pure ()
      Just (PayloadTyped _ maybeType) -> do
        actual <- bindingType symbols input ((.loc) timer) binding
        expected <- resolveType symbols ((.loc) timer) (maybe TText nameTypeExpr maybeType)
        requireSame ((.loc) timer) expected actual

    checkTimer symbols timer = do
      aggregate <- requireAggregate ((.loc) timer) ((.target) ((.fire) timer))
      command <- requireCommand ((.loc) timer) aggregate ((.command) ((.fire) timer))
      checkTimerFireBindings symbols timer aggregate command

    checkTimerFireBindings symbols timer aggregate command =
      traverse_ (checkOne command) ((.fields) ((.fire) timer))
      where
        checkOne commandDecl binding = case find ((== (.name) binding) . (.name)) ((.fields) commandDecl) of
          Nothing -> pure ()
          Just field -> do
            expected <- mapType ((.loc) timer) (inferAggregateFieldType symbols aggregate CommandFieldUse field)
            actual <- case (.value) binding of
              Just "timer.id" -> Right AggregateText
              _ -> case find ((== (.name) binding) . payloadName) ((.payload) timer) of
                Just (PayloadTyped _ maybeType) -> resolveType symbols ((.loc) timer) (maybe TText nameTypeExpr maybeType)
                Just PayloadConstant {} -> Right AggregateText
                Nothing -> Right AggregateText
            requireSame ((.loc) timer) expected actual

    checkBindings symbols input aggregate command loc bindings =
      traverse_ checkOne bindings
      where
        checkOne binding = case find ((== (.name) binding) . (.name)) ((.fields) command) of
          Nothing -> pure ()
          Just field -> do
            expected <- mapType loc (inferAggregateFieldType symbols aggregate CommandFieldUse field)
            actual <- bindingType symbols input loc binding
            requireSame loc expected actual

    checkGuard symbols input expression = do
      valueType <- guardType symbols input expression
      requireExactType (exprLoc expression) AggregateBool valueType

    guardType symbols input = \case
      EAnd left right -> booleanPair left right
      EOr left right -> booleanPair left right
      ECmp operator left right -> do
        leftType <- guardType symbols input left
        rightType <- guardType symbols input right
        requireSame (exprLoc left) leftType rightType
        if operator `elem` [OpLt, OpLe, OpGt, OpGe] && leftType `notElem` [AggregateText, AggregateInt, AggregateInteger, AggregateNatural, AggregateTime]
          then failure (exprLoc left) ProcessReactionGuardNotBoolean "ordering comparison requires Text, a number, or Time"
          else Right AggregateBool
      EPath loc UnqualifiedRoot ["input", field] -> requireInputType symbols input loc field
      EPath loc _ _ -> failure loc ProcessStateAccessUnsupported "reaction guards may read only input.<field>; saga/register/command state is unsupported"
      ELiteral _ (LiteralBool _) -> Right AggregateBool
      ELiteral _ (LiteralText _) -> Right AggregateText
      ELiteral _ (LiteralIntegral _) -> Right AggregateInteger
      ELiteral loc (LiteralQualified typeName constructor) -> do
        resolved <- resolveType symbols loc (TRef typeName)
        case resolved of
          AggregateNominal nominal -> case (.representation) nominal of
            EnumRepresentation constructors | constructor `elem` map fst (NE.toList constructors) -> Right resolved
            _ -> failure loc ProcessReactionGuardNotBoolean "qualified literal is not a constructor of the declared enum"
          _ -> failure loc ProcessReactionGuardNotBoolean "qualified literal must name a declared enum"
      ELiteral loc LiteralId {} -> failure loc ProcessReactionGuardNotBoolean "id constructor literals are not supported in reaction guards"
      EAdd loc _ _ -> failure loc ProcessReactionGuardNotBoolean "arithmetic is not supported in reaction guards"
      ESubtract loc _ _ -> failure loc ProcessReactionGuardNotBoolean "arithmetic is not supported in reaction guards"
      EMultiply loc _ _ -> failure loc ProcessReactionGuardNotBoolean "arithmetic is not supported in reaction guards"
      EAtom (ABool _) -> Right AggregateBool
      EAtom (AName _) -> failure noLoc ProcessStateAccessUnsupported "bare names are not supported in reaction guards; use input.<field>"
      where
        booleanPair left right = do
          leftType <- guardType symbols input left
          rightType <- guardType symbols input right
          requireExactType (exprLoc left) AggregateBool leftType
          requireExactType (exprLoc right) AggregateBool rightType
          Right AggregateBool

    requireInputType symbols input loc field = case find ((== field) . (.name)) ((.fields) input) of
      Nothing -> failure loc ProcessStateAccessUnsupported ("input '" <> (.name) input <> "' has no field '" <> field <> "'")
      Just declaration -> resolveType symbols loc (maybe TText nameTypeExpr ((.valueType) declaration))

    bindingType symbols input loc binding = case (.value) binding of
      Nothing -> requireInputType symbols input loc ((.name) binding)
      Just value
        | isQuoted value -> Right AggregateText
        | Just field <- T.stripPrefix "input." value -> requireInputType symbols input loc field
        | value == "timer.id" -> Right AggregateText
        | otherwise -> requireInputType symbols input loc value

    requireAggregate loc name = case [aggregate | aggregate <- aggregates, (.name) aggregate == name] of
      aggregate : _ -> Right aggregate
      [] -> failure loc ProcessBindingTypeMismatch ("aggregate '" <> name <> "' is unavailable for reaction type checking")

    requireCommand loc aggregate name = case [command | command <- (.commands) aggregate, (.name) command == name] of
      command : _ -> Right command
      [] -> failure loc ProcessBindingTypeMismatch ("aggregate '" <> (.name) aggregate <> "' has no command '" <> name <> "'")

    resolveType symbols loc expression = mapType loc (resolveAggregateType symbols loc CommandFieldUse expression)
    mapType loc = either (const (failure loc ProcessBindingTypeMismatch "type is not supported by process reactions")) Right
    requireSame loc expected actual
      | expected == actual = Right ()
      | otherwise = failure loc ProcessBindingTypeMismatch ("binding type mismatch: expected " <> aggregateCanonicalName expected <> ", got " <> aggregateCanonicalName actual)
    requireExactType loc expected actual
      | expected == actual = Right ()
      | otherwise = failure loc ProcessReactionGuardNotBoolean "reaction guard must have Boolean type"
    isQuoted value = T.length value >= 2 && T.head value == '"' && T.last value == '"'
    nameTypeExpr = \case
      "Text" -> TText
      "Int" -> TInt
      "Integer" -> TInteger
      "Bool" -> TBool
      "Natural" -> TNatural
      "Time" -> TTime
      name -> TRef name
    payloadName (PayloadConstant name _) = name
    payloadName (PayloadTyped name _) = name
    armUnverified arm = case (.body) arm of
      ArmActions {advance = Just advance} -> case (.accepted) advance of
        Just _ -> any (\aggregate -> (.agg) ((.saga) process) == (.name) aggregate && any (\transition -> (.command) transition == (.command) advance && (.implementation) transition == HoleImplementation) ((.transitions) aggregate)) aggregates
        Nothing -> False
      _ -> False

checkTimerPolicy :: ReactionBody -> Either (NonEmpty ProcessReactionDiagnostic) ()
checkTimerPolicy reaction = case ((.timerPolicy) reaction, (.timers) reaction) of
  (Nothing, _ : _) -> failure ((.versionLoc) reaction) ProcessTimerPolicyMissing "a process with timers requires a timers policy"
  (Just policy, []) -> failure ((.loc) policy) ProcessTimerPolicyUnused "a timer-free process must not declare a timers policy"
  _ -> Right ()

checkPrefixCollisions :: [ReactionTimerNode] -> Either (NonEmpty ProcessReactionDiagnostic) ()
checkPrefixCollisions timers =
  case duplicates (map ((.prefix) . (.id)) timers <> map ((.prefix) . (.firedEventId) . (.fire)) timers) of
    prefix : _ ->
      failure
        (maybe noLoc (.loc) (find (ownsPrefix prefix) timers))
        ProcessTimerPrefixCollision
        ("timer identity prefix is reused: " <> prefix)
    [] -> Right ()
  where
    ownsPrefix prefix timer = (.prefix) ((.id) timer) == prefix || (.prefix) ((.firedEventId) ((.fire) timer)) == prefix

processReactionFingerprint :: CheckedProcessReaction -> Text
processReactionFingerprint = (.fingerprint)

processReactionFingerprintFrom :: ReactionBody -> Text
processReactionFingerprintFrom reaction = hex (BS.unpack (SHA256.hash (Text.encodeUtf8 canonical)))
  where
    canonical = canonicalReactionSurface reaction

hex :: (Foldable f) => f Word8 -> Text
hex = T.pack . concatMap twoHex . foldr (:) []
  where
    twoHex byte = case showHex byte "" of
      [digit] -> ['0', digit]
      digits -> digits

failure :: Loc -> ProcessReactionDiagnosticCode -> Text -> Either (NonEmpty ProcessReactionDiagnostic) a
failure loc code message = Left (ProcessReactionDiagnostic loc code message :| [])

requireNoDuplicate :: ProcessReactionDiagnosticCode -> Text -> Loc -> [Name] -> Either (NonEmpty ProcessReactionDiagnostic) ()
requireNoDuplicate code label loc names = case duplicates names of
  name : _ -> failure loc code (label <> " '" <> name <> "' is declared more than once")
  [] -> Right ()

duplicates :: (Ord a) => [a] -> [a]
duplicates = foldr collect [] . group . sort
  where
    collect (value : _ : _) rest = value : rest
    collect _ rest = rest

traverse_ :: (Applicative f) => (a -> f b) -> [a] -> f ()
traverse_ action = foldr (\value rest -> action value *> rest) (pure ())
