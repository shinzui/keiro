{- | The harness engine. From an aggregate spec it emits a @-- \@generated@ test
module that __pins the filled holes' behaviour__ — the project's actual
determinism guarantee, since the scaffolder no longer produces the transducer
body by construction. The emitted module exposes @harnessAssertions ::
[(String, Bool)]@, a list of labelled checks a driver runs (failing on any
@False@, naming the assertion). The checks are:

  1. keiki's @validateTransducer defaultValidationOptions@ on the filled
     transducer is empty (no hidden inputs / nondeterminism / dead edges);
  2. a /clock-free/ assertion baked from the spec (TIME IS INJECTED, NOT
     SAMPLED) — @False@ would mean a guard\/write sampled a wall clock;
  3. a golden wire round-trip per event (@decode . encode == id@);
  4. a behavioural /accept/ check per transition out of the initial state:
     stepping a sample command lands on the declared @goto@ vertex. This is the
     check a wrong guard fails — flipping @./=@ to @.==@ in the filled body turns
     it red while leaving the scaffold untouched.
-}
module Keiro.Dsl.Harness (
    harnessFor,
    harnessProcess,
) where

import Data.Text (Text)
import Data.Text qualified as T
import Keiro.Dsl.Grammar
import Keiro.Dsl.Scaffold

{- | Emit the harness test module for one aggregate. Like 'scaffoldAggregate',
it takes the 'Spec' for the shared id\/enum declarations.
-}
harnessFor :: Context -> Spec -> Aggregate -> [ScaffoldModule]
harnessFor ctx spec agg =
    [ ScaffoldModule
        { modulePath = T.unpack (T.replace "." "/" (aGenPrefix a) <> "/Harness.hs")
        , moduleText = emitHarness a
        , kind = Generated
        }
    ]
  where
    a = resolveAgg ctx spec agg

{- | Emit a self-contained, firewall-clean facts harness for a process manager,
pinning the spec's deterministic decisions: the time-injection formula, the
deterministic timer-id and fired-event-id derivation strings, the runtime-owned
dispatch-id (no user id), and the dispatch\/fire disposition tables (incl. the
@on-reject => Fired@ benign inversion). It exposes
@processHarnessFacts :: [(String, Bool)]@ over pure values, so it compiles and
runs without the effectful\/hasql runtime. (Behavioural conformance of the
/filled/ ProcessManager against the live runtime is the M5 step.)
-}
harnessProcess :: Context -> ProcessNode -> [ScaffoldModule]
harnessProcess ctx p =
    [ ScaffoldModule
        { modulePath = T.unpack (T.replace "." "/" genPrefix <> "/ProcessHarness.hs")
        , moduleText = emitProcessHarness genPrefix p
        , kind = Generated
        }
    ]
  where
    ctxPascal = pascalFromKebab' (contextName ctx)
    root = case moduleRoot ctx of r | T.null r -> ""; r -> r <> "."
    genPrefix = root <> "Generated." <> ctxPascal <> "." <> procId p

emitProcessHarness :: Text -> ProcessNode -> Text
emitProcessHarness genPrefix p =
    nl
        [ "{-# LANGUAGE OverloadedStrings #-}"
        , generatedBanner
        , "module " <> genPrefix <> ".ProcessHarness (processHarnessValues) where"
        , ""
        , "-- | (label, value): the spec's deterministic process/timer decisions, "
        , "-- lowered to plain values so a driver can assert them against a committed"
        , "-- expectation. The driver's expectation is hand-written (not generated), so a"
        , "-- spec change that alters a decision diverges from it and turns a specific"
        , "-- assertion red — the spec->behaviour pin. (Live-runtime behavioural"
        , "-- conformance of the filled ProcessManager is the M5 step.)"
        , "processHarnessValues :: [(String, String)]"
        , "processHarnessValues ="
        , "  [ (\"fireAtField\", " <> hs (faField (tmFireAt timer)) <> ")"
        , "  , (\"timerIdPrefix\", " <> hs (idePrefix (tmId timer)) <> ")"
        , "  , (\"firedEventIdPrefix\", " <> hs (idePrefix (fireFiredEventId timer')) <> ")"
        , "  , (\"dispatchIdUserField\", \"none\")"
        , "  , (\"onReject\", " <> hs (showFireOutcome (onReject fd)) <> ")"
        , "  , (\"onFailed\", " <> hs (showDisp (onFailed (firstDispDisposition p))) <> ")"
        , "  , (\"maxAttempts\", " <> hs (tInt (tmMaxAttempts timer)) <> ")"
        , "  ]"
        ]
  where
    timer = procTimer p
    timer' = tmFire timer
    fd = fireDisposition timer'
    hs = tshow

firstDispDisposition :: ProcessNode -> DispatchDisposition
firstDispDisposition p = case hDispatch (procHandle p) of
    (d : _) -> dispDisposition d
    [] -> DispatchDisposition DAckOk DAckOk DRetry

showFireOutcome :: FireOutcome -> Text
showFireOutcome OFired = "Fired"
showFireOutcome ORetry = "Retry"

showDisp :: Disp -> Text
showDisp DAckOk = "AckOk"
showDisp DRetry = "Retry"
showDisp (DDeadLetter _) = "DeadLetter"

-- A local copy (Scaffold's pascalFromKebab is not exported).
pascalFromKebab' :: Text -> Text
pascalFromKebab' = T.concat . map cap . T.splitOn "-"
  where
    cap t = case T.uncons t of
        Just (c, rest) -> T.cons (T.head (T.toUpper (T.singleton c))) rest
        Nothing -> t

emitHarness :: Agg -> Text
emitHarness a =
    nl $
        [ "{-# LANGUAGE OverloadedStrings #-}"
        , generatedBanner
        , "module " <> aGenPrefix a <> ".Harness (harnessAssertions) where"
        , ""
        , "import " <> aGenPrefix a <> ".Domain"
        , "import " <> aGenPrefix a <> ".Codec (encode" <> nm <> "Event, parse" <> nm <> "Event" <> codecValueImport <> ")"
        , "import " <> aHolePrefix a <> ".Holes (" <> lowerFirst nm <> "Transducer)"
        , "import Keiki.Core (defaultValidationOptions, step, validateTransducer)"
        , codecDecodeRawImport
        , ""
        , "-- | (label, passed). A driver runs these and exits non-zero on any False,"
        , "-- naming the failing assertion. Filling a hole wrongly turns a specific"
        , "-- entry False; the scaffold cannot."
        , "harnessAssertions :: [(String, Bool)]"
        , "harnessAssertions ="
        , "  [ (\"validateTransducer is empty\", null (validateTransducer defaultValidationOptions " <> lowerFirst nm <> "Transducer))"
        , "  , (\"clock-free: spec samples no wall clock\", " <> clockFreeLit <> ")"
        ]
            ++ [ "  , (\"golden round-trip: " <> rcName e <> "\", roundTrips sampleEvent" <> rcName e <> ")"
               | e <- aEvents a
               ]
            ++ [ "  , (\"accepts " <> tCommand t <> " from " <> initialVertex a <> "\", accept" <> tCommand t <> ")"
               | t <- initialTransitions a
               ]
            ++ [ "  , (\"upcaster wired: a v" <> tInt m <> " " <> rcName e <> " payload decodes through the chain\", upcasts" <> rcName e <> ")"
               | e <- upcastEvents
               , Just m <- [rcUpcastFrom e]
               ]
            ++ [ "  ]"
               , ""
               , "roundTrips :: " <> nm <> "Event -> Bool"
               , "roundTrips e = parse" <> nm <> "Event (encode" <> nm <> "Event e) == Right e"
               ]
            ++ concatMap (sampleEventDecl a) (aEvents a)
            ++ concatMap (acceptDecl a) (initialTransitions a)
            ++ concatMap (upcastDecl a) upcastEvents
  where
    nm = aName a
    -- Bake the clock-free result computed from the spec at scaffold time.
    clockFreeLit = if specIsClockFree a then "True" else "False"
    upcastEvents = [e | e <- aEvents a, rcUpcastFrom e /= Nothing]
    codecValueImport = if null upcastEvents then "" else ", " <> lowerFirst nm <> "Codec"
    codecDecodeRawImport = if null upcastEvents then "" else "import Keiro.Codec (decodeRaw)"

{- | A wiring-proof assertion: feed a current-shape payload tagged at the
upcaster's source version through @decodeRaw@, which runs the upcaster chain
then @decode@. Red while the upcaster hole returns @Left@; green once filled.
(The grammar records only the current event shape, not the per-version field
delta, so this proves the chain is wired and the hole must be filled rather
than re-deriving the exact old payload.)
-}
upcastDecl :: Agg -> ResolvedCtor -> [Text]
upcastDecl a e = case rcUpcastFrom e of
    Nothing -> []
    Just m ->
        [ ""
        , "upcasts" <> rcName e <> " :: Bool"
        , "upcasts" <> rcName e <> " ="
        , "  either (const False) (const True)"
        , "    (decodeRaw " <> lowerFirst (aName a) <> "Codec " <> tInt m <> " (encode" <> aName a <> "Event sampleEvent" <> rcName e <> "))"
        ]

tInt :: Int -> Text
tInt = T.pack . show

-- | Render a Text as a Haskell string literal (quoted, escaped).
tshow :: Text -> Text
tshow = T.pack . show

nl :: [Text] -> Text
nl = T.intercalate "\n"

specIsClockFree :: Agg -> Bool
specIsClockFree a = not (any transitionSamplesClock (aTransitions a))
  where
    clockAtoms = ["now", "currentTime", "wallClock", "today", "utcNow"]
    transitionSamplesClock t =
        let exprs = maybe [] pure (tGuard t) ++ map snd (tWrites t)
         in any (\e -> any (`elem` clockAtoms) (exprNames e)) exprs

exprNames :: Expr -> [Text]
exprNames (EOr x y) = exprNames x ++ exprNames y
exprNames (EAnd x y) = exprNames x ++ exprNames y
exprNames (ECmp _ x y) = exprNames x ++ exprNames y
exprNames (EAtom (AName n)) = [n]
exprNames (EAtom (ABool _)) = []

initialTransitions :: Agg -> [Transition]
initialTransitions a = case map stName (aStates a) of
    (s0 : _) -> [t | t <- aTransitions a, tSource t == s0]
    [] -> []

{- | @sampleEvent<Ctor> :: <Agg>Event@ — a sample built from per-field sample
values (enum→first constructor, Bool→False, id→placeholder, Text→\"sample\").
-}
sampleEventDecl :: Agg -> ResolvedCtor -> [Text]
sampleEventDecl a e =
    [ ""
    , "sampleEvent" <> rcName e <> " :: " <> aName a <> "Event"
    , "sampleEvent" <> rcName e <> " = " <> ctorExpr a e
    ]

acceptDecl :: Agg -> Transition -> [Text]
acceptDecl a t =
    [ ""
    , "accept" <> tCommand t <> " :: Bool"
    , "accept" <> tCommand t <> " ="
    , "  case step " <> lowerFirst (aName a) <> "Transducer (" <> initialVertex a <> ", initial" <> aName a <> "Regs) " <> cmdSample <> " of"
    , "    Just (v, _, _) -> v == " <> vertexCtor a (tGoto t)
    , "    Nothing -> False"
    ]
  where
    cmdSample = case [c | c <- aCommands a, rcName c == tCommand t] of
        (c : _) -> "(" <> ctorExpr a c <> ")"
        [] -> "(error \"no command\")"

-- | @(<Ctor> (<Ctor>Data v1 v2 …))@ with positional sample field values.
ctorExpr :: Agg -> ResolvedCtor -> Text
ctorExpr a rc =
    "(" <> rcName rc <> " (" <> rcName rc <> "Data" <> args <> "))"
  where
    args = T.concat [" " <> sampleValue a ty | (_, ty) <- rcFields rc]

sampleValue :: Agg -> Text -> Text
sampleValue a ty = case fieldCat a ty of
    IdCat -> "(" <> ty <> " \"sample\")"
    EnumCat -> maybe ("(error \"no enum ctor\")") id (firstEnumCtor a ty)
    OtherCat
        | ty == "Bool" -> "False"
        | ty == "Text" -> "\"sample\""
        | otherwise -> "(error \"sample: unsupported type " <> ty <> "\")"
