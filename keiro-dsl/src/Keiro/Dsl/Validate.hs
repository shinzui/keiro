{- | The keiro DSL validator. A parsed 'Spec' is /valid/ only if it passes the
cross-cutting structural and hole-kind rules below. The point is to reject a
dangerous-by-omission spec — a deleted status-map, an undeclared command, a
guard atom that resolves to nothing, a wall-clock read inside a guard — /before
any Haskell is written/.

EP-1 defines the 'Diagnostic' framework and the cross-cutting rules; each later
vertical (EP-3…EP-6) appends its node-specific rules (e.g. EP-4's inbox
disposition inversions) reusing this same 'Diagnostic' type.
-}
module Keiro.Dsl.Validate (
    Severity (..),
    DiagnosticCode (..),
    Diagnostic (..),
    renderDiagnostic,
    validateSpec,
) where

import Data.List (sortOn)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Keiro.Dsl.Grammar

data Severity = Error | Warning
    deriving stock (Eq, Show)

-- | A machine-checkable code per rule, so tests match on the code, not prose.
data DiagnosticCode
    = UndeclaredCommand
    | UndeclaredEvent
    | UndeclaredState
    | UnreachableState
    | TerminalHasOutgoing
    | GuardAtomOutOfScope
    | StatusMapNotTotal
    | ClockSampled
    | -- EP-2 (evolution). The first three fire in single-spec @validateSpec@;
      -- the last two are emitted by the @diff@ path (they need a prior spec) and
      -- live here so the enum is the single registry of evolution rules.
      EvtVersionMissingUpcaster
    | DeprecatedEventStillEmitted
    | WireSchemaVersionMismatch
    | EvtFieldAddedWithoutBump
    | EvtRemovedNotDeprecated
    | -- EP-3 (process manager + durable timer).
      ProcessFireAtNotInjected
    | ProcessDispatchIdSupplied
    | ProcessUnresolvedRef
    | ProcessBenignInversion
    deriving stock (Eq, Show)

-- | A line-numbered, structured diagnostic.
data Diagnostic = Diagnostic
    { line :: !Int
    , severity :: !Severity
    , code :: !DiagnosticCode
    , message :: !Text
    }
    deriving stock (Eq, Show)

{- | Render a diagnostic in the conventional
@\<file\>:\<line\>: error[\<code\>]: \<message\>@ form.
-}
renderDiagnostic :: FilePath -> Diagnostic -> Text
renderDiagnostic file d =
    T.pack file
        <> ":"
        <> T.pack (show (line d))
        <> ": "
        <> sev
        <> "["
        <> T.pack (show (code d))
        <> "]: "
        <> message d
  where
    sev = case severity d of Error -> "error"; Warning -> "warning"

{- | Reserved wall-clock atom names. Sampling any of these inside a guard or
write breaks deterministic replay: TIME IS INJECTED, NOT SAMPLED.
-}
clockAtoms :: Set Name
clockAtoms = Set.fromList ["now", "currentTime", "wallClock", "today", "utcNow"]

{- | Validate a whole spec. An empty list means valid. Diagnostics are sorted by
line for stable, readable output.
-}
validateSpec :: Spec -> [Diagnostic]
validateSpec spec =
    sortOn line (concatMap (validateNode spec) (specNodes spec))

validateNode :: Spec -> Node -> [Diagnostic]
validateNode spec (NAggregate agg) = validateAggregate spec agg
validateNode spec (NProcess p) = validateProcess spec p
validateNode _spec (NContract _) = [] -- EP-4 M2 adds the contract/intake rules

-- | EP-3 rules for a process manager + its nested timer.
validateProcess :: Spec -> ProcessNode -> [Diagnostic]
validateProcess spec p =
    concat [noWallClock, runtimeOwnedDispatchId, crossNodeCoupling, benignInversions]
  where
    aggNames = [aggName a | NAggregate a <- specNodes spec]
    inputFields = map fieldName (inFields (procInput p))
    timeFields = [fieldName f | f <- inFields (procInput p), fieldType f == Just "Time"]
    timer = procTimer p
    pl = locLine (procLoc p)

    -- TIME IS INJECTED, NOT SAMPLED: fireAt's field must be a declared :Time
    -- input field. (FireAtExpr has no clock-sampling constructor, so this is a
    -- field-resolution + typed-as-Time check.)
    noWallClock =
        let f = faField (tmFireAt timer)
         in [ mkErr (locLine (tmLoc timer)) ProcessFireAtNotInjected $
                "timer '" <> tmName timer <> "' fireAt references '" <> f <> "', which is not a declared :Time field of input '" <> inName (procInput p) <> "'"
            | f `notElem` timeFields
            ]
                ++ [ mkErr (locLine (tmLoc timer)) ProcessFireAtNotInjected $
                        "timer '" <> tmName timer <> "' fireAt field '" <> f <> "' is not a field of input '" <> inName (procInput p) <> "'"
                   | f `notElem` inputFields
                   ]

    -- Dispatched (and fired) command ids are runtime-owned; no field binding may
    -- supply a commandId/id.
    runtimeOwnedDispatchId =
        [ mkErr pl ProcessDispatchIdSupplied $
            "dispatch to '" <> dispTarget d <> "' supplies a runtime-owned id field '" <> fbName b <> "'; remove it"
        | d <- hDispatch (procHandle p)
        , b <- dispFields d
        , fbName b `elem` (["commandId", "id"] :: [Name])
        ]
            ++ [ mkErr (locLine (tmLoc timer)) ProcessDispatchIdSupplied $
                    "timer fire supplies a runtime-owned id field '" <> fbName b <> "'; remove it"
               | b <- fireFields (tmFire timer)
               , fbName b `elem` (["commandId", "id"] :: [Name])
               ]

    -- saga / target / fire-target must resolve to declared aggregates.
    crossNodeCoupling =
        [ mkErr pl ProcessUnresolvedRef ("saga '" <> sagaAgg (procSaga p) <> "' does not resolve to a declared aggregate")
        | sagaAgg (procSaga p) `notElem` aggNames
        ]
            ++ [ mkErr pl ProcessUnresolvedRef ("target '" <> procTarget p <> "' does not resolve to a declared aggregate")
               | procTarget p `notElem` aggNames
               ]
            ++ [ mkErr (locLine (tmLoc timer)) ProcessUnresolvedRef ("timer fire target '" <> fireTarget (tmFire timer) <> "' must be the saga or the target aggregate")
               | fireTarget (tmFire timer) `notElem` [sagaAgg (procSaga p), procTarget p]
               ]

    -- Surface the dangerous benign inversions the author confirmed (warnings).
    benignInversions =
        [ Diagnostic (locLine (tmLoc timer)) Warning ProcessBenignInversion $
            "timer '" <> tmName timer <> "' maps on-reject => Fired (a CommandRejected is treated as benign success)"
        | onReject (fireDisposition (tmFire timer)) == OFired
        ]
            ++ [ Diagnostic pl Warning ProcessBenignInversion $
                    "dispatch to '" <> dispTarget d <> "' maps on-duplicate => AckOk (a duplicate is treated as benign success)"
               | d <- hDispatch (procHandle p)
               , onDuplicate (dispDisposition d) == DAckOk
               ]

validateAggregate :: Spec -> Aggregate -> [Diagnostic]
validateAggregate spec agg =
    concat
        [ declaredRefs
        , reachability
        , terminalNoOutgoing
        , guardScope
        , clockFree
        , statusMapTotality
        , evolutionRules
        ]
  where
    states = Set.fromList (map stName (aggStates agg))
    terminals = Set.fromList [stName s | s <- aggStates agg, stTerminal s]
    commandFields :: Map Name [Name]
    commandFields = Map.fromList [(cmdName c, map fieldName (cmdFields c)) | c <- aggCommands agg]
    commandNames = Map.keysSet commandFields
    eventNames = Set.fromList (map evName (aggEvents agg))
    enumCtorNames = Set.fromList [c | e <- specEnums spec, (c, _) <- enumCtors e]
    ruleNames = Set.fromList (map ruleName (specRules spec))
    registerNames = Set.fromList (map regName (aggRegs agg))

    -- Rule 1: declared-reference for command / emit / goto / source.
    declaredRefs =
        concatMap transitionRefs (aggTransitions agg)
    transitionRefs t =
        [ mkErr (locLine (tLoc t)) UndeclaredCommand $
            "transition references undeclared command '" <> tCommand t <> "'"
        | not (tCommand t `Set.member` commandNames)
        ]
            ++ [ mkErr (locLine (tLoc t)) UndeclaredState $
                    "transition source '" <> tSource t <> "' is not a declared state"
               | not (tSource t `Set.member` states)
               ]
            ++ [ mkErr (locLine (tLoc t)) UndeclaredState $
                    "transition goto '" <> tGoto t <> "' is not a declared state"
               | not (tGoto t `Set.member` states)
               ]
            ++ [ mkErr (locLine (tLoc t)) UndeclaredEvent $
                    "emit references undeclared event '" <> ev <> "'"
               | ev <- tEmits t
               , not (ev `Set.member` eventNames)
               ]

    -- Rule 2: reachability of every non-terminal state from the initial state
    -- (the first state in the list).
    reachability = case map stName (aggStates agg) of
        [] -> []
        (initial : _) ->
            let reached = bfs (Set.singleton initial) [initial]
             in [ mkErr (locLine (aggLoc agg)) UnreachableState $
                    "state '" <> stName s <> "' is not reachable from the initial state '" <> initial <> "'"
                | s <- aggStates agg
                , not (stTerminal s)
                , not (stName s `Set.member` reached)
                ]
    edgesFrom src = [tGoto t | t <- aggTransitions agg, tSource t == src]
    bfs seen [] = seen
    bfs seen (x : xs) =
        let nexts = [n | n <- edgesFrom x, not (n `Set.member` seen)]
         in bfs (foldr Set.insert seen nexts) (xs ++ nexts)

    -- Rule 3: a terminal state has no outgoing transition.
    terminalNoOutgoing =
        [ mkErr (locLine (tLoc t)) TerminalHasOutgoing $
            "terminal state '" <> tSource t <> "' has an outgoing transition"
        | t <- aggTransitions agg
        , tSource t `Set.member` terminals
        ]

    -- Rule 4: every atom in a guard or write Expr resolves to a register, a
    -- field of the transition's command, an enum constructor, a rule, or a bool.
    guardScope = concatMap transitionScope (aggTransitions agg)
    transitionScope t =
        let inScope =
                registerNames
                    `Set.union` Set.fromList (Map.findWithDefault [] (tCommand t) commandFields)
                    `Set.union` enumCtorNames
                    `Set.union` ruleNames
                    -- State names are constructors of the implicit vertex enum, so a
                    -- @write reservationState := Held@ references a state legitimately.
                    `Set.union` states
            exprs = maybe [] pure (tGuard t) ++ map snd (tWrites t)
            badAtoms =
                [ n
                | e <- exprs
                , n <- exprNames e
                , not (n `Set.member` clockAtoms) -- clock atoms reported separately
                , not (n `Set.member` inScope)
                ]
         in [ mkErr (locLine (tLoc t)) GuardAtomOutOfScope $
                "atom '" <> n <> "' in transition '" <> tSource t <> " -- " <> tCommand t <> "' resolves to no register, command field, enum constructor, or rule"
            | n <- dedup badAtoms
            ]

    -- Rule 5 (cross-cutting): no guard or write Expr samples a wall clock.
    clockFree = concatMap transitionClock (aggTransitions agg)
    transitionClock t =
        let exprs = maybe [] pure (tGuard t) ++ map snd (tWrites t)
            sampled = [n | e <- exprs, n <- exprNames e, n `Set.member` clockAtoms]
         in [ mkErr (locLine (tLoc t)) ClockSampled $
                "transition '" <> tSource t <> " -- " <> tCommand t <> "' samples the wall clock via '" <> n <> "'; time must be an injected input field, not sampled"
            | n <- dedup sampled
            ]

    -- Rule 6 (hole-kind 3, mapping): the projection's status-map must be total
    -- over the event set, unless explicitly marked partial.
    statusMapTotality = case aggProjection agg of
        Nothing -> []
        Just p ->
            let evs = map evName (aggEvents agg)
                covered ev = case projStatusMap p of
                    Nothing -> False
                    Just m
                        | mapPartial m -> True
                        | otherwise -> any (\(k, _) -> not (T.null k) && k `T.isSuffixOf` ev) (mapPairs m)
                uncovered = filter (not . covered) evs
             in [ mkErr (locLine (projLoc p)) StatusMapNotTotal $
                    "projection '" <> projTable p <> "' status-map is not total over events {" <> T.intercalate ", " uncovered <> "}"
                | not (null evs)
                , not (null uncovered)
                ]

    -- EP-2 evolution rules (single-spec; the diff path adds the cross-spec ones).
    evolutionRules = versionUpcasterRule ++ deprecatedEmitRule ++ wireVersionRule
    emittedNames = Set.fromList (concatMap tEmits (aggTransitions agg))
    maxEventVersion = maximum (1 : map evVersion (aggEvents agg))

    -- A non-initial event version must carry a contiguous upcaster (from v-1).
    versionUpcasterRule =
        [ mkErr (locLine (evLoc e)) EvtVersionMissingUpcaster $
            "event '" <> evName e <> "' version " <> tInt (evVersion e) <> " has no 'upcast from v" <> tInt (evVersion e - 1) <> "' clause"
        | e <- aggEvents agg
        , evVersion e > 1
        , maybe True ((/= evVersion e - 1) . fst) (evUpcastFrom e)
        ]

    -- A deprecated event must have left the write path.
    deprecatedEmitRule =
        [ mkErr (locLine (evLoc e)) DeprecatedEventStillEmitted $
            "deprecated event '" <> evName e <> "' is still emitted by a transition"
        | e <- aggEvents agg
        , evDeprecated e
        , evName e `Set.member` emittedNames
        ]

    -- The explicit `wire schemaVersion=` (if any) must equal the max event version.
    wireVersionRule = case aggWire agg of
        Just w
            | wireSchemaVersion w /= maxEventVersion ->
                [ Diagnostic
                    { line = locLine (aggLoc agg)
                    , severity = Warning
                    , code = WireSchemaVersionMismatch
                    , message =
                        "wire schemaVersion=" <> tInt (wireSchemaVersion w) <> " does not match the maximum event version " <> tInt maxEventVersion
                    }
                ]
        _ -> []

tInt :: Int -> Text
tInt = T.pack . show

mkErr :: Int -> DiagnosticCode -> Text -> Diagnostic
mkErr l c m = Diagnostic{line = l, severity = Error, code = c, message = m}

locLine :: Loc -> Int
locLine = unLoc

-- | The 'AName' atom names occurring anywhere in an expression.
exprNames :: Expr -> [Name]
exprNames (EOr a b) = exprNames a ++ exprNames b
exprNames (EAnd a b) = exprNames a ++ exprNames b
exprNames (ECmp _ a b) = exprNames a ++ exprNames b
exprNames (EAtom (AName n)) = [n]
exprNames (EAtom (ABool _)) = []

dedup :: (Ord a) => [a] -> [a]
dedup = Set.toList . Set.fromList
