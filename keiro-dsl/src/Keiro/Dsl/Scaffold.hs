{- | The scaffold engine. Given an 'Aggregate' (and a 'Context' naming the
service and output module-namespace root), it emits the __symbol-free
deterministic layer__ as @-- \@generated@ modules plus a single create-if-absent
@Holes.hs@ holding the typed holes a human or coding agent must fill.

The load-bearing invariant of this module is the __firewall__: no @Generated@
module ever contains a keiki symbolic operator (@./=@, @.==@, @.||@, @lit@,
@B.slot@, @B.requireGuard@). Those live only in the hand-owned @Holes.hs@. A
test ('Generated' text scan) enforces it.

Scope (EP-1, recorded in the plan's Decision Log): the scaffolder does /not/
emit the symbolic transducer body — that is the @buildTransducer@ hole in
@Holes.hs@, pinned by the harness. It also does not emit the read-model SQL
(the projection @apply@), which is a DB-coupled hole delegated to @codd@/the
agent; the @Generated@ Projection module emits only the deterministic
@InlineProjection@ wiring and the pure event→status mapping. The decode emitted
here is /strict/ (every field required); lenient\/optional decode is EP-4's
concern.
-}
module Keiro.Dsl.Scaffold (
    ScaffoldModule (..),
    ModuleKind (..),
    Context (..),
    Placement (..),
    defaultContext,
    genPrefixFor,
    holePrefixFor,
    scaffoldAggregate,
    scaffoldProcess,
    scaffoldRouter,
    scaffoldContract,
    scaffoldIntake,
    scaffoldPublisher,
    scaffoldWorkqueue,
    scaffoldReadModel,
    scaffoldRefusals,
    windowSeconds,

    -- * Firewall self-check (M3)
    FirewallSurface (..),
    firewallSurface,
    firewallBreaches,

    -- * Internal resolution, shared with "Keiro.Dsl.Harness"
    Agg (..),
    ResolvedCtor (..),
    resolveAgg,
    FieldCat (..),
    fieldCat,
    vertexCtor,
    initialVertex,
    firstEnumCtor,
    lowerFirst,
    pascal,
    pascalFromKebab,
    generatedBanner,
) where

import Data.Char (isAlpha, isAlphaNum, isUpper, toLower, toUpper)
import Data.List (find)
import Data.Maybe (fromMaybe, mapMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Keiro.Dsl.FoldFingerprint (aggregateFoldFingerprint)
import Keiro.Dsl.Grammar
import Keiro.Dsl.ReadModelShape (registryNameFor, subscriptionNameFor)
import Keiro.Dsl.Validate (sagaCategoryError)
import Text.Read (readMaybe)

{- | One emitted module: its on-disk path (relative to the scaffold @--out@
directory), its full text, and whether it is overwritten every run
('Generated') or written only when absent ('HoleStub').
-}
data ScaffoldModule = ScaffoldModule
    { modulePath :: !FilePath
    , moduleText :: !Text
    , kind :: !ModuleKind
    , origin :: !Text
    }
    deriving stock (Eq, Show)

data ModuleKind
    = -- | @-- \@generated@; overwritten on every scaffold.
      Generated
    | -- | Hand-owned; created only when absent, never overwritten.
      HoleStub
    deriving stock (Eq, Show)

{- | The threading context: the spec's @context@ name, the chosen output
module-namespace root, and the placement style. Extended additively (never
re-shaped) by later verticals.
-}
data Context = Context
    { contextName :: !Text
    , moduleRoot :: !Text
    -- ^ @""@ means no namespace prefix (the historical default).
    , placement :: !Placement
    -- ^ 'GeneratedPrefix' is the historical default.
    }
    deriving stock (Eq, Show)

{- | A context with today's default placement ('GeneratedPrefix', no root prefix)
for the given @context@ name. Callers that do not care about placement (the
@parse@ path, tests) build their context with this.
-}
defaultContext :: Text -> Context
defaultContext name = Context{contextName = name, moduleRoot = "", placement = GeneratedPrefix}

{- | The generated-layer namespace for a node, honouring the root prefix and the
placement style. The 'Text' argument is the already-pascalised node name (e.g.
@Reservation@, @HospitalSurge@). For 'GeneratedPrefix' this is
@\<root\>.Generated.\<Ctx\>.\<Node\>@ (identical to the historical layout); for
'CollocatedLeaf' it is @\<root\>.\<Ctx\>.\<Node\>.Generated@.
-}
genPrefixFor :: Context -> Text -> Text
genPrefixFor ctx node = case placement ctx of
    GeneratedPrefix -> rootPrefix ctx <> "Generated." <> ctxPascalOf ctx <> "." <> node
    CollocatedLeaf -> rootPrefix ctx <> ctxPascalOf ctx <> "." <> node <> ".Generated"

{- | The hand-owned (hole) namespace for a node: @\<root\>.\<Ctx\>.\<Node\>@ —
the same for both placement styles (holes always sit beside the domain).
-}
holePrefixFor :: Context -> Text -> Text
holePrefixFor ctx node = rootPrefix ctx <> ctxPascalOf ctx <> "." <> node

-- | The root namespace prefix, dot-terminated, or @""@ when no root is set.
rootPrefix :: Context -> Text
rootPrefix ctx = case moduleRoot ctx of r | T.null r -> ""; r -> r <> "."

-- | The context name in PascalCase, e.g. @hospital-capacity@ -> @HospitalCapacity@.
ctxPascalOf :: Context -> Text
ctxPascalOf = pascalFromKebab . contextName

--------------------------------------------------------------------------------
-- Firewall self-check (M3)
--------------------------------------------------------------------------------

{- | The canonical keiki surface forbidden in generated modules. Symbolic
operators are matched as maximal Haskell symbol tokens, identifiers as complete
tokens, qualifiers by their leading module alias, and imports structurally.
-}
data FirewallSurface = FirewallSurface
    { forbiddenSymbolic :: ![Text]
    , forbiddenIdents :: ![Text]
    , forbiddenQualifiers :: ![Text]
    , forbiddenImports :: ![Text]
    , restrictedImports :: ![(Text, [Text])]
    }
    deriving stock (Eq, Show)

firewallSurface :: FirewallSurface
firewallSurface =
    FirewallSurface
        { forbiddenSymbolic = [".==", "./=", ".<", ".<=", ".>", ".>=", ".&&", ".||", ".+", ".-", ".*", "=:", "*:"]
        , forbiddenIdents = ["lit", "pnot", "tadd", "tsub", "tmul"]
        , forbiddenQualifiers = ["B"]
        , forbiddenImports = ["Keiki.Builder", "Keiki.Operators", "Keiki.Symbolic"]
        , -- Generated aggregate modules use the first two names; generated
          -- harnesses use the final three to validate and step filled holes.
          restrictedImports = [("Keiki.Core", ["RegFile", "HsPred", "defaultValidationOptions", "step", "validateTransducer"])]
        }

{- | Scan generated modules for firewall breaches, returning every offending
@(module path, token, 1-based line number)@. Only modules whose 'kind' is
'Generated' are scanned. Strings and comments are skipped, symbol runs use
maximal munch, and keiki imports are checked independently of token spelling.
-}
firewallBreaches :: [ScaffoldModule] -> [(FilePath, Text, Int)]
firewallBreaches mods =
    [ (modulePath m, breach, n)
    | m <- mods
    , kind m == Generated
    , (n, line) <- zip [1 ..] (T.lines (moduleText m))
    , breach <- lineBreaches line
    ]

lineBreaches :: Text -> [Text]
lineBreaches line = case importModule line of
    Just _ -> importBreaches line
    Nothing -> tokenBreaches (codeTokens line)
  where
    tokenBreaches = mapMaybe breachFor
    breachFor (IdentToken ident)
        | ident `elem` forbiddenIdents firewallSurface = Just ident
    breachFor (QualifiedToken qualifier)
        | qualifier `elem` forbiddenQualifiers firewallSurface = Just (qualifier <> ".*")
    breachFor (SymbolToken symbol)
        | symbol `elem` forbiddenSymbolic firewallSurface = Just symbol
    breachFor _ = Nothing

data CodeToken = IdentToken !Text | QualifiedToken !Text | SymbolToken !Text

codeTokens :: Text -> [CodeToken]
codeTokens = go . T.unpack
  where
    go [] = []
    go ('-' : '-' : _) = []
    go ('"' : rest) = go (dropString rest)
    go ('\'' : rest) = go (dropChar rest)
    go (c : rest)
        | isIdentStart c =
            let (identTail, afterIdent) = span isIdentContinue rest
                ident = T.pack (c : identTail)
             in case afterIdent of
                    '.' : next : more
                        | isUpper c && isIdentStart next ->
                            let (_member, afterMember) = span isIdentContinue more
                             in QualifiedToken ident : go afterMember
                    _ -> IdentToken ident : go afterIdent
        | isSymbolChar c =
            let (symbolTail, afterSymbol) = span isSymbolChar rest
             in SymbolToken (T.pack (c : symbolTail)) : go afterSymbol
        | otherwise = go rest
    isIdentStart c = isAlpha c || c == '_'
    isIdentContinue c = isAlphaNum c || c == '_' || c == '\''
    isSymbolChar c = c `elem` ("!#$%&*+./<=>?@\\^|-~:" :: String)
    dropString [] = []
    dropString ('\\' : _escaped : rest) = dropString rest
    dropString ('"' : rest) = rest
    dropString (_ : rest) = dropString rest
    dropChar [] = []
    dropChar ('\\' : _escaped : rest) = dropChar rest
    dropChar ('\'' : rest) = rest
    dropChar (_ : rest) = dropChar rest

importBreaches :: Text -> [Text]
importBreaches line = case importModule line of
    Nothing -> []
    Just imported
        | imported `elem` forbiddenImports firewallSurface -> ["import:" <> imported]
        | Just allowed <- lookup imported (restrictedImports firewallSurface)
        , not (hasAllowedExplicitImportList allowed line) ->
            ["import:" <> imported]
        | otherwise -> []

importModule :: Text -> Maybe Text
importModule line = case T.words (T.strip line) of
    "import" : rest -> find (T.isPrefixOf "Keiki.") rest
    _ -> Nothing

hasAllowedExplicitImportList :: [Text] -> Text -> Bool
hasAllowedExplicitImportList allowed line =
    case (T.breakOn "(" line, T.breakOnEnd ")" line) of
        ((_, open), (close, _))
            | not (T.null open) && not (T.null close) ->
                let inside = T.takeWhile (/= ')') (T.drop 1 open)
                    names = filter (not . T.null) (T.split (not . isAlphaNum) inside)
                 in all (`elem` allowed) names
        _ -> False

--------------------------------------------------------------------------------
-- Derived naming
--------------------------------------------------------------------------------

-- | Resolved, denormalized view of an aggregate used by every emitter.
data Agg = Agg
    { aContext :: !Context
    , aCtxPascal :: !Text
    , aName :: !Text
    , aLoc :: !Loc
    , aVertexType :: !Text
    , aIds :: ![IdDecl]
    , aEnums :: ![EnumDecl]
    , aRegs :: ![RegDecl]
    , aStates :: ![StateDecl]
    , aCommands :: ![ResolvedCtor]
    , aEvents :: ![ResolvedCtor]
    , aTransitions :: ![Transition]
    , aWire :: !WireSpec
    , aProjection :: !(Maybe ProjectionSpec)
    , aSnapshot :: !(Maybe SnapshotSpec)
    , aFoldFingerprint :: !Text
    , aReadModels :: ![ReadModelNode]
    , aGenPrefix :: !Text
    -- ^ e.g. @Generated.HospitalCapacity.Reservation@
    , aHolePrefix :: !Text
    -- ^ e.g. @HospitalCapacity.Reservation@
    }

-- | A command or event constructor with its fully-resolved field types.
data ResolvedCtor = ResolvedCtor
    { rcName :: !Text
    , rcFields :: ![(Text, Text)]
    -- ^ (field name, resolved Haskell type)
    , rcVersion :: !Int
    -- ^ EP-2: schema version (1 for commands and unversioned events).
    , rcUpcastFrom :: !(Maybe Int)
    -- ^ EP-2: the source version this event migrates from (the upcaster step).
    }

defaultWire :: WireSpec
defaultWire = WireSpec{wireKind = "ctorName", wireFields = "camelCase", wireSchemaVersion = 1}

resolveAgg :: Context -> Spec -> Aggregate -> Agg
resolveAgg ctx spec agg =
    Agg
        { aContext = ctx
        , aCtxPascal = ctxPascal
        , aName = nm
        , aLoc = aggLoc agg
        , aVertexType = vertexType
        , aIds = specIds spec
        , aEnums = specEnums spec
        , aRegs = aggRegs agg
        , aStates = aggStates agg
        , aCommands = map resolveCommand (aggCommands agg)
        , aEvents = map resolveEvent (aggEvents agg)
        , aTransitions = aggTransitions agg
        , aWire = fromMaybe defaultWire (aggWire agg)
        , aProjection = aggProjection agg
        , aSnapshot = aggSnapshot agg
        , aFoldFingerprint = aggregateFoldFingerprint spec agg
        , aReadModels = [readModel | NReadModel readModel <- specNodes spec]
        , aGenPrefix = genPrefixFor ctx nm
        , aHolePrefix = holePrefixFor ctx nm
        }
  where
    nm = aggName agg
    ctxPascal = pascalFromKebab (contextName ctx)
    vertexType = nm <> "Vertex"
    commandFieldTypes = [(cmdName c, cmdFields c) | c <- aggCommands agg]
    resolveCommand c = (mkCtor (cmdName c) (cmdFields c)){rcVersion = 1, rcUpcastFrom = Nothing}
    resolveEvent e =
        (mkCtor (evName e) (eventFields e))
            { rcVersion = evVersion e
            , rcUpcastFrom = fst <$> evUpcastFrom e
            }
      where
        eventFields ev = case evBody ev of
            EventFields fs -> fs
            EventFromCommand cn -> fromMaybe [] (lookup cn commandFieldTypes)
    mkCtor cn fs =
        ResolvedCtor
            { rcName = cn
            , rcFields = map (\f -> (fieldName f, resolveFieldType f)) fs
            , rcVersion = 1
            , rcUpcastFrom = Nothing
            }
    regTypes = [(regName r, regType r) | r <- aggRegs agg]
    idNames = map idName (specIds spec)
    enumNames = map enumName (specEnums spec)
    -- A bare field reuses a register's type if one shares its name; else it
    -- Pascal-cases to a declared id/enum/vertex; else falls back to Text.
    resolveFieldType f = case fieldType f of
        Just ty -> ty
        Nothing ->
            let nme = fieldName f
                pas = pascal nme
             in case lookup nme regTypes of
                    Just ty -> ty
                    Nothing
                        | pas `elem` idNames -> pas
                        | pas `elem` enumNames -> pas
                        | pas == vertexType -> pas
                        | otherwise -> "Text"

--------------------------------------------------------------------------------
-- Entry point
--------------------------------------------------------------------------------

{- | Emit all modules for one aggregate. The 'Spec' is needed for the shared
id\/enum declarations.
-}
scaffoldAggregate :: Context -> Spec -> Aggregate -> [ScaffoldModule]
scaffoldAggregate ctx spec agg =
    [ genModule a "Domain" (emitDomain a)
    , genModule a "Codec" (emitCodec a)
    , genModule a "EventStream" (emitEventStream a)
    , genModule a "Projection" (emitProjection a)
    , holeModule a (emitHoles a)
    ]
  where
    a = resolveAgg ctx spec agg

genModule :: Agg -> Text -> Text -> ScaffoldModule
genModule a name body =
    ScaffoldModule
        { modulePath = T.unpack (T.replace "." "/" (aGenPrefix a) <> "/" <> name <> ".hs")
        , moduleText = body
        , kind = Generated
        , origin = nodeOrigin "aggregate" (aName a) (aLoc a)
        }

holeModule :: Agg -> Text -> ScaffoldModule
holeModule a body =
    ScaffoldModule
        { modulePath = T.unpack (T.replace "." "/" (aHolePrefix a) <> "/" <> "Holes.hs")
        , moduleText = body
        , kind = HoleStub
        , origin = nodeOrigin "aggregate" (aName a) (aLoc a)
        }

--------------------------------------------------------------------------------
-- Integration contract (EP-4): a self-contained payload ADT + codec
--------------------------------------------------------------------------------

{- | Emit the deterministic, symbol-free contract layer: a payload ADT
(per-event records), the topic constants, the @messageType@ discriminator, and a
strict encode\/decode keyed by it. Self-contained (base\/text\/aeson), so it
compiles standalone — the cross-service schema both producer and consumer agree
on. No keiki symbolic operator (firewall holds).
-}
scaffoldContract :: Context -> ContractNode -> [ScaffoldModule]
scaffoldContract ctx c =
    [ ScaffoldModule
        { modulePath = T.unpack (T.replace "." "/" genPrefix <> "/Contract.hs")
        , moduleText = emitContractGen genPrefix c
        , kind = Generated
        , origin = nodeOrigin "contract" (ctrName c) (ctrLoc c)
        }
    ]
  where
    genPrefix = genPrefixFor ctx (pascal (ctrName c))

emitContractGen :: Text -> ContractNode -> Text
emitContractGen genPrefix c =
    nl $
        [ "{-# LANGUAGE DuplicateRecordFields #-}"
        , "{-# LANGUAGE OverloadedRecordDot #-}"
        , "{-# LANGUAGE OverloadedStrings #-}"
        , "{-# OPTIONS_GHC -Wno-unused-top-binds #-}"
        , generatedBanner
        , "module " <> genPrefix <> ".Contract"
        , "  ( " <> payloadTy <> " (..)"
        , nl ["  , " <> ceName e <> "Data (..)" | e <- ctrEvents c]
        , "  , messageTypeOf"
        , "  , encode" <> payloadTy
        , "  , parse" <> payloadTy
        , "  ) where"
        , ""
        , "import Data.Aeson (Value, object, withObject, (.:), (.=))"
        , "import Data.Aeson.Types (Parser, parseEither)"
        , "import Data.Text (Text)"
        , "import qualified Data.Text as T"
        , ""
        , "-- topic constants"
        ]
            ++ [lowerFirst alias <> "Topic :: Text\n" <> lowerFirst alias <> "Topic = " <> tshow t | (alias, t) <- ctrTopics c]
            ++ [ ""
               , "-- the closed payload set (discriminated by " <> tshow (ctrDiscriminator c) <> ")"
               ]
            ++ [emitPayloadAdt payloadTy (ctrEvents c)]
            ++ [ ""
               , "messageTypeOf :: " <> payloadTy <> " -> Text"
               , "messageTypeOf = \\case"
               ]
            ++ ["  " <> ceName e <> " {} -> " <> tshow (ceName e) | e <- ctrEvents c]
            ++ [ ""
               , "encode" <> payloadTy <> " :: " <> payloadTy <> " -> Value"
               , "encode" <> payloadTy <> " = \\case"
               ]
            ++ concatMap encodeArm (ctrEvents c)
            ++ [ ""
               , "parse" <> payloadTy <> " :: Value -> Either Text " <> payloadTy
               , "parse" <> payloadTy <> " = mapLeftText . parseEither (withObject " <> tshow payloadTy <> " go)"
               , "  where"
               , "    go o = do"
               , "      kind <- o .: " <> tshow (ctrDiscriminator c) <> " :: Parser Text"
               , "      case kind of"
               ]
            ++ concatMap decodeArm (ctrEvents c)
            ++ [ "        _ -> fail \"unknown message type\""
               , ""
               , "mapLeftText :: Either String b -> Either Text b"
               , "mapLeftText = either (Left . T.pack) Right"
               ]
  where
    payloadTy = pascal (ctrName c) <> "Payload"
    encodeArm e =
        [ "  " <> ceName e <> " payload ->"
        , "    object"
        ]
            ++ [lead i kv | (i, kv) <- zip [(0 :: Int) ..] ((tshow (ctrDiscriminator c) <> " .= (" <> tshow (ceName e) <> " :: Text)") : [tshow (cfName f) <> " .= payload." <> cfName f | f <- ceFields e])]
            ++ ["      ]"]
    lead 0 kv = "      [ " <> kv
    lead _ kv = "      , " <> kv
    decodeArm e =
        [ "        " <> tshow (ceName e) <> " ->"
        , "          " <> ceName e <> " <$> (" <> ceName e <> "Data" <> fieldApps (ceFields e) <> ")"
        ]
    fieldApps [] = ""
    fieldApps fs = " <$> " <> T.intercalate " <*> " ["o .: " <> tshow (cfName f) | f <- fs]

emitPayloadAdt :: Text -> [ContractEvent] -> Text
emitPayloadAdt tyName events =
    sectionsOf [map dataRecord events, [sumDecl]]
  where
    hsType CText = "Text"
    hsType CInt = "Int"
    hsType (CTypeId _) = "Text"
    dataRecord e =
        "data "
            <> ceName e
            <> "Data = "
            <> ceName e
            <> "Data { "
            <> T.intercalate ", " [cfName f <> " :: !" <> hsType (cfType f) | f <- ceFields e]
            <> " }\n  deriving stock (Eq, Show)"
    arm e = ceName e <> " !" <> ceName e <> "Data"
    sumDecl = case events of
        [] -> "data " <> tyName <> " = " <> tyName <> "Empty\n  deriving stock (Eq, Show)"
        (e : es) ->
            nl $
                ["data " <> tyName <> " = " <> arm e]
                    ++ ["  | " <> arm e2 | e2 <- es]
                    ++ ["  deriving stock (Eq, Show)"]

--------------------------------------------------------------------------------
-- Integration intake (EP-4): inbox disposition vs the live Keiro.Inbox runtime
--------------------------------------------------------------------------------

{- | Emit the inbox node's deterministic disposition wiring compiled against the
LIVE @Keiro.Inbox.Types@: the dedupe policy (a real 'InboxDedupePolicy') and a
disposition function over the real @InboxResult@ (Processed\/Duplicate\/
InProgress\/PreviouslyFailed). This pins the dangerous inversions
(duplicate ⇒ ackOk, previouslyFailed ⇒ deadLetter) as compiled code over the
runtime types. The handler-level decode\/dedupe\/store failures are noted but not
part of @InboxResult@. Firewall holds (no keiki symbolic operator).
-}
scaffoldIntake :: Context -> IntakeNode -> [ScaffoldModule]
scaffoldIntake ctx i =
    [ ScaffoldModule
        { modulePath = T.unpack (T.replace "." "/" genPrefix <> "/Inbox.hs")
        , moduleText = emitIntakeGen genPrefix i
        , kind = Generated
        , origin = nodeOrigin "intake" (inkName i) (inkLoc i)
        }
    ]
  where
    genPrefix = genPrefixFor ctx (pascal (inkName i))

emitIntakeGen :: Text -> IntakeNode -> Text
emitIntakeGen genPrefix i =
    nl
        [ "{-# OPTIONS_GHC -Wno-unused-top-binds #-}"
        , generatedBanner
        , "module " <> genPrefix <> ".Inbox"
        , "  ( InboxAck (..)"
        , "  , inboxDedupePolicy"
        , "  , inboxPersistence"
        , "  , inboxDisposition"
        , "  ) where"
        , ""
        , "import Keiro.Inbox.Types (InboxDedupePolicy (..), InboxPersistence (..), InboxResult (..))"
        , ""
        , "-- The dedupe policy (hole-kind 4), lowered to the live InboxDedupePolicy."
        , "inboxDedupePolicy :: InboxDedupePolicy"
        , "inboxDedupePolicy = " <> inkDedupePolicy i
        , ""
        , "{- | Success-path envelope retention passed to runInboxTransactionWith."
        , "Failures always retain their full operator-facing dead-letter envelope."
        , "Dedupe-only success rows decode with an empty payload."
        , "-}"
        , "inboxPersistence :: InboxPersistence"
        , "inboxPersistence = " <> persistenceCtor (inkPersist i)
        , ""
        , "-- The service's ack decision for each inbox classification."
        , "data InboxAck = InboxAckOk | InboxRetry | InboxDeadLetter"
        , "  deriving stock (Eq, Show)"
        , ""
        , "-- The disposition table (hole-kind 2) over the LIVE Keiro.Inbox.Types.InboxResult."
        , "-- duplicate => ackOk and previouslyFailed => deadLetter are the dangerous"
        , "-- inversions the spec states explicitly."
        , "inboxDisposition :: InboxResult a -> InboxAck"
        , "inboxDisposition r = case r of"
        , "  InboxProcessed _ -> " <> ackFor "processed"
        , "  InboxDuplicate -> " <> ackFor "duplicate"
        , "  InboxInProgress -> " <> ackFor "inProgress"
        , "  InboxPreviouslyFailed _ -> " <> ackFor "previouslyFailed"
        , ""
        , "-- handler-level failures (not InboxResult): decodeFailed => "
            <> ackText "decodeFailed"
            <> ", dedupeFailed => "
            <> ackText "dedupeFailed"
            <> ", storeFailed => "
            <> ackText "storeFailed"
        ]
  where
    act o = lookup o [(drOutcome r, drAction r) | r <- inkDisposition i]
    ackFor o = case act o of
        Just IAckOk -> "InboxAckOk"
        Just (IRetry _) -> "InboxRetry"
        Just (IDeadLetter _) -> "InboxDeadLetter"
        Nothing -> "InboxRetry"
    ackText o = case act o of
        Just IAckOk -> "ackOk"
        Just (IRetry _) -> "retry"
        Just (IDeadLetter _) -> "deadLetter"
        Nothing -> "retry"
    persistenceCtor InkPersistFull = "PersistFullEnvelope"
    persistenceCtor InkPersistDedupeOnly = "PersistDedupeOnly"

--------------------------------------------------------------------------------
-- Integration publisher (EP-4): config vs the live Keiro.Outbox runtime
--------------------------------------------------------------------------------

{- | Emit the publisher's at-least-once policy compiled against the LIVE
@Keiro.Outbox.Types@: the ordering policy (a real 'OrderingPolicy'), the backoff
curve (a real 'BackoffSchedule'), and the max-attempts ceiling. Firewall holds.
-}
scaffoldPublisher :: Context -> PublisherNode -> [ScaffoldModule]
scaffoldPublisher ctx pb =
    [ ScaffoldModule
        { modulePath = T.unpack (T.replace "." "/" genPrefix <> "/Publisher.hs")
        , moduleText = emitPublisherGen genPrefix pb
        , kind = Generated
        , origin = nodeOrigin "publisher" (pubName pb) (pubLoc pb)
        }
    ]
  where
    genPrefix = genPrefixFor ctx (pascal (pubName pb))

emitPublisherGen :: Text -> PublisherNode -> Text
emitPublisherGen genPrefix pb =
    nl
        [ "{-# OPTIONS_GHC -Wno-unused-top-binds #-}"
        , generatedBanner
        , "module " <> genPrefix <> ".Publisher"
        , "  ( publisherOrdering"
        , "  , publisherBackoff"
        , "  , publisherMaxAttempts"
        , "  ) where"
        , ""
        , "import Keiro.Outbox.Types (BackoffSchedule (..), ExponentialBackoffOptions (..), OrderingPolicy (..))"
        , ""
        , "publisherOrdering :: OrderingPolicy"
        , "publisherOrdering = " <> pubOrdering pb
        , ""
        , "publisherBackoff :: BackoffSchedule"
        , "publisherBackoff = " <> backoffExpr (pubBackoff pb)
        , ""
        , "publisherMaxAttempts :: Int"
        , "publisherMaxAttempts = " <> tshow' (pubMaxAttempts pb)
        ]
  where
    backoffExpr b = case boKind b of
        "constant" -> "ConstantBackoff " <> windowText (boWindow b)
        "exponential" ->
            "ExponentialBackoff ExponentialBackoffOptions { initial = "
                <> windowText (boWindow b)
                <> ", maxDelay = "
                <> maybe "0" windowText (boMax b)
                <> ", multiplier = "
                <> fromMaybe "0" (boMultiplier b)
                <> " }"
        _ -> "error \"keiro-dsl: unlowerable backoff kind\""

--------------------------------------------------------------------------------
-- pgmq workqueue (EP-5): a self-contained Job payload record + codec
--------------------------------------------------------------------------------

{- | Emit the deterministic, symbol-free pgmq layer: the Job payload record, the
field→wire-name JSON codec, and the captured physical\/dlq\/table name constants.
Self-contained (base\/text\/aeson). The fan-out body and the raw-SQL dedup
predicate are holes (not emitted). Firewall holds.
-}
scaffoldWorkqueue :: Context -> WorkqueueNode -> [ScaffoldModule]
scaffoldWorkqueue ctx w =
    [ ScaffoldModule
        { modulePath = T.unpack (T.replace "." "/" genPrefix <> "/Queue.hs")
        , moduleText = emitWorkqueueGen genPrefix w
        , kind = Generated
        , origin = nodeOrigin "workqueue" (wqName w) (wqLoc w)
        }
    , ScaffoldModule
        { modulePath = T.unpack (T.replace "." "/" genPrefix <> "/QueuePolicy.hs")
        , moduleText = emitQueuePolicy genPrefix w
        , kind = Generated
        , origin = nodeOrigin "workqueue" (wqName w) (wqLoc w)
        }
    ]
  where
    genPrefix = genPrefixFor ctx (pascal (wqName w))

emitWorkqueueGen :: Text -> WorkqueueNode -> Text
emitWorkqueueGen genPrefix w =
    nl $
        [ "{-# LANGUAGE OverloadedRecordDot #-}"
        , "{-# LANGUAGE OverloadedStrings #-}"
        , "{-# OPTIONS_GHC -Wno-unused-top-binds #-}"
        , generatedBanner
        , "module " <> genPrefix <> ".Queue"
        , "  ( " <> payloadTy <> " (..)"
        , "  , encode" <> payloadTy
        , "  , parse" <> payloadTy
        , "  , queuePhysical, queueDlq, queueTable"
        , groupKeyExport
        , "  ) where"
        , ""
        , "import Data.Aeson (Value, object, withObject, (.:), (.=))"
        , "import Data.Aeson.Types (parseEither)"
        , "import Data.Text (Text)"
        , "import qualified Data.Text as T"
        , ""
        , "queuePhysical, queueDlq, queueTable :: Text"
        , "queuePhysical = " <> tshow (wqPhysical w)
        , "queueDlq = " <> tshow (wqDlq w)
        , "queueTable = " <> tshow (wqTable w)
        , ""
        ]
            ++ groupKeyLines
            ++ [ "data " <> payloadTy <> " = " <> payloadTy
               , "  { " <> T.intercalate "\n  , " [wqfName f <> " :: !" <> hsType (wqfType f) | f <- wqPayload w]
               , "  }"
               , "  deriving stock (Eq, Show)"
               , ""
               , "encode" <> payloadTy <> " :: " <> payloadTy <> " -> Value"
               , "encode" <> payloadTy <> " p ="
               , "  object"
               ]
            ++ [lead i (tshow (wqfWire f) <> " .= p." <> wqfName f) | (i, f) <- zip [(0 :: Int) ..] (wqPayload w)]
            ++ [ "    ]"
               , ""
               , "parse" <> payloadTy <> " :: Value -> Either Text " <> payloadTy
               , "parse" <> payloadTy <> " = mapLeftText . parseEither (withObject " <> tshow payloadTy <> " go)"
               , "  where"
               , "    go o = " <> payloadTy <> fieldApps (wqPayload w)
               , ""
               , "mapLeftText :: Either String b -> Either Text b"
               , "mapLeftText = either (Left . T.pack) Right"
               ]
  where
    payloadTy = wqPayloadName w
    groupKeyExport = case wqGroupKey w of
        Nothing -> ""
        Just groupKey
            | gkVia groupKey == "raw" -> "  , groupKeyField, groupKeyFor"
            | otherwise -> "  , groupKeyField"
    groupKeyLines = case wqGroupKey w of
        Nothing -> []
        Just groupKey -> common <> derivationLines groupKey
          where
            common =
                [ "groupKeyField :: Text"
                , "groupKeyField = " <> tshow (gkField groupKey)
                , ""
                ]
            derivationLines key
                | gkVia key == "raw" =
                    [ "groupKeyFor :: " <> payloadTy <> " -> Text"
                    , "groupKeyFor payload = payload." <> gkField key
                    , ""
                    ]
                | otherwise =
                    [ "-- Opaque group-key derivation '" <> gkVia key <> "' remains hand-owned."
                    , "-- Captured fixture: " <> fromMaybe "<missing>" (gkFixture key)
                    , ""
                    ]
    hsType "bool" = "Bool"
    hsType "int" = "Int"
    hsType _ = "Text"
    lead 0 kv = "    [ " <> kv
    lead _ kv = "    , " <> kv
    fieldApps [] = ""
    fieldApps fs = " <$> " <> T.intercalate " <*> " ["o .: " <> tshow (wqfWire f) | f <- fs]

{- | Emit the pgmq retry policy + JobOutcome disposition compiled against the
LIVE @Keiro.PGMQ.Job@ runtime (RetryPolicy / JobOutcome / RetryDelay). This pins
the dangerous inversions over the runtime types: storeFailure ⇒ Retry (transient)
and decodeFailure ⇒ Dead (poison).
-}
emitQueuePolicy :: Text -> WorkqueueNode -> Text
emitQueuePolicy genPrefix w =
    nl $
        [ "{-# LANGUAGE OverloadedStrings #-}"
        , generatedBanner
        , "module " <> genPrefix <> ".QueuePolicy"
        , "  ( retryPolicy, jobOutcomeFor"
        , "  , jobOrdering, jobTuningFor, queueProvision"
        , "  ) where"
        , ""
        , "import Data.Text (Text)"
        , "import Keiro.PGMQ.Job (JobOrdering (..), JobOutcome (..), JobTuning, PartitionSpec (..), QueueProvision, RetryDelay (..), RetryPolicy (..), partitionedProvision, standardProvision, unloggedProvision, withFifoIndexProvision, withOrdering)"
        , ""
        , "jobOrdering :: JobOrdering"
        , "jobOrdering = " <> orderingCtor
        , ""
        , "-- Deployment owns visibility timeout, batch size, and polling; the spec owns ordering."
        , "jobTuningFor :: JobTuning -> JobTuning"
        , "jobTuningFor = withOrdering jobOrdering"
        , ""
        , "-- Pass this to ensureJobQueueWith at worker startup. FIFO adds the required GIN index; the DLQ remains standard."
        , "queueProvision :: QueueProvision"
        , "queueProvision = " <> provisionExpr
        , ""
        , "retryPolicy :: RetryPolicy"
        , "retryPolicy ="
        , "  RetryPolicy"
        , "    { maxRetries = " <> tshow' (wqMaxRetries w)
        , "    , defaultRetryDelay = RetryDelay " <> windowText (wqDelay w)
        , "    , useDeadLetter = " <> (if wqDlqOn w then "True" else "False")
        , "    }"
        , ""
        , "-- The consumer JobOutcome disposition over the spec's named domain outcomes,"
        , "-- lowered to the live Keiro.PGMQ.Job.JobOutcome."
        , "jobOutcomeFor :: Text -> JobOutcome"
        , "jobOutcomeFor o = case o of"
        ]
            ++ ["  " <> tshow (wqdOutcome r) <> " -> " <> outcome (wqdAction r) | r <- wqDisposition w]
            ++ ["  _ -> Retry (RetryDelay " <> windowText (wqDelay w) <> ")"]
  where
    orderingCtor = case wqOrdering w of
        WqUnordered -> "Unordered"
        WqFifoThroughput -> "FifoThroughput"
        WqFifoRoundRobin -> "FifoRoundRobin"
    provisionExpr = fifoWrap baseProvision
    fifoWrap expression = case wqOrdering w of
        WqUnordered -> expression
        _ -> "withFifoIndexProvision (" <> expression <> ")"
    baseProvision = case wqProvision w of
        WqStandard -> "standardProvision"
        WqUnlogged -> "unloggedProvision"
        WqPartitioned interval retention ->
            "partitionedProvision (PartitionSpec { partitionInterval = "
                <> tshow interval
                <> ", retentionInterval = "
                <> tshow retention
                <> " })"
    outcome IAckOk = "Done"
    outcome (IRetry win) = "Retry (RetryDelay " <> windowText win <> ")"
    outcome (IDeadLetter mr) = "Dead " <> tshow (fromMaybe "dead-lettered" mr)

--------------------------------------------------------------------------------
-- First-class read models (EP-107)
--------------------------------------------------------------------------------

{- | Emit an acyclic three-module read-model vertical. @ReadModelTable@ owns the
qualified-table constant shared by the hand-owned query and the generated
runtime record; @ReadModel@ re-exports it as part of the public surface.
-}
scaffoldReadModel :: Context -> ReadModelNode -> [ScaffoldModule]
scaffoldReadModel ctx readModel =
    [ generated "ReadModelTable" (emitReadModelTable tableModule stem readModel)
    , generated "ReadModel" (emitReadModelGen ctx readModelModule tableModule readModelHolePrefix stem readModel)
    , ScaffoldModule
        { modulePath = modulePathFor readModelHolePrefix "ReadModelHoles"
        , moduleText = emitReadModelHoles tableModule readModelHolePrefix stem readModel
        , kind = HoleStub
        , origin = readModelOrigin
        }
    ]
  where
    nodeSegment = pascal (rmName readModel)
    stem = readModelStem readModel
    readModelModule = genPrefixFor ctx nodeSegment
    tableModule = readModelModule <> ".ReadModelTable"
    readModelHolePrefix = holePrefixFor ctx nodeSegment
    readModelOrigin = nodeOrigin "readmodel" (rmName readModel) (rmLoc readModel)
    generated leaf body =
        ScaffoldModule
            { modulePath = modulePathFor readModelModule leaf
            , moduleText = body
            , kind = Generated
            , origin = readModelOrigin
            }

modulePathFor :: Text -> Text -> FilePath
modulePathFor prefix leaf = T.unpack (T.replace "." "/" prefix <> "/" <> leaf <> ".hs")

readModelStem :: ReadModelNode -> Text
readModelStem = lowerFirst . T.concat . map pascal . T.splitOn "_" . rmName

emitReadModelTable :: Text -> Text -> ReadModelNode -> Text
emitReadModelTable tableModule stem readModel =
    nl
        [ "{-# LANGUAGE OverloadedStrings #-}"
        , generatedBanner
        , "module " <> tableModule <> " (" <> qualifiedName <> ") where"
        , ""
        , "import Data.Text (Text)"
        , "import Keiro.Connection (qualifyTable)"
        , ""
        , "-- The fully-qualified, double-quoted data-table reference."
        , qualifiedName <> " :: Text"
        , qualifiedName <> " = qualifyTable " <> tshow (rmSchema readModel) <> " " <> tshow (rmTable readModel)
        ]
  where
    qualifiedName = stem <> "QualifiedTable"

emitReadModelGen :: Context -> Text -> Text -> Text -> Text -> ReadModelNode -> Text
emitReadModelGen ctx readModelModule tableModule readModelHolePrefix stem readModel =
    nl $
        [ "{-# LANGUAGE OverloadedRecordDot #-}"
        , "{-# LANGUAGE OverloadedStrings #-}"
        , generatedBanner
        , "module " <> readModelModule <> ".ReadModel"
        , "  ( " <> T.intercalate "\n  , " exports
        , "  ) where"
        , ""
        , "import Data.Functor (void)"
        , "import Effectful (Eff, (:>))"
        , "import " <> tableModule <> " (" <> qualifiedName <> ")"
        , "import " <> readModelHolePrefix <> ".ReadModelHoles (" <> T.intercalate ", " holeImports <> ")"
        ]
            ++ asyncImports
            ++ [ "import Keiro.ReadModel (ConsistencyMode (..), ReadModel (..), ReadModelMetadata, StrongScope (..), registerReadModel)"
               , "import Keiro.ReadModel.Rebuild qualified as Rebuild"
               , "import Kiroku.Store.Effect (Store)"
               , "import Kiroku.Store.Types (" <> kirokuTypes <> ")"
               , ""
               , readModelName <> " :: ReadModel " <> queryInputType <> " " <> queryResultType
               , readModelName <> " ="
               , "  ReadModel"
               , "    { name = " <> tshow registryName
               , "    , tableName = " <> tshow (rmTable readModel)
               , "    , schema = " <> tshow (rmSchema readModel)
               , "    , subscriptionName = " <> tshow subscriptionName
               , "    , version = " <> tshow' (rmVersion readModel)
               , "    , shapeHash = " <> tshow (rmShape readModel)
               , "    , defaultConsistency = " <> consistencyExpr (rmConsistency readModel)
               , "    , strongScope = " <> scopeExpr (rmScope readModel)
               , "    , query = " <> queryName
               , "    }"
               , ""
               , "-- Call once at projection startup before serving queries."
               , registerName <> " :: (Store :> es) => Eff es ()"
               , registerName <> " ="
               , "  void (registerReadModel " <> tshow registryName <> " " <> tshow' (rmVersion readModel) <> " " <> tshow (rmShape readModel) <> ")"
               , ""
               , startName <> " :: (Store :> es) => GlobalPosition -> Eff es ReadModelMetadata"
               , startName <> " ="
               , "  Rebuild.startRebuild " <> readModelName <> " " <> projectionNames
               , ""
               , finishName <> " :: (Store :> es) => GlobalPosition -> Eff es (Either Rebuild.RebuildError ReadModelMetadata)"
               , finishName <> " ="
               , "  Rebuild.finishRebuild " <> readModelName <> " " <> projectionNames
               , ""
               , abandonName <> " :: (Store :> es) => Eff es ReadModelMetadata"
               , abandonName <> " = Rebuild.abandonRebuild " <> readModelName
               ]
            ++ asyncDefinition
  where
    registryName = registryNameFor (contextName ctx) readModel
    subscriptionName = subscriptionNameFor (contextName ctx) readModel
    asyncName = registryName <> "-async"
    readModelName = stem <> "ReadModel"
    qualifiedName = stem <> "QualifiedTable"
    registerName = "register" <> pascal stem
    startName = "start" <> pascal stem <> "Rebuild"
    finishName = "finish" <> pascal stem <> "Rebuild"
    abandonName = "abandon" <> pascal stem <> "Rebuild"
    asyncValueName = stem <> "AsyncProjection"
    queryInputType = pascal stem <> "QueryInput"
    queryResultType = pascal stem <> "QueryResult"
    queryName = stem <> "Query"
    applyName = "apply" <> pascal stem
    exports =
        [ readModelName
        , qualifiedName
        , registerName
        , startName
        , finishName
        , abandonName
        ]
            ++ [asyncValueName | rmFeed readModel == RmSubscription]
    holeImports = [queryInputType, queryResultType, queryName] ++ [applyName | rmFeed readModel == RmSubscription]
    asyncImports = case rmFeed readModel of
        RmInline -> []
        RmSubscription -> ["import Keiro.Projection (AsyncProjection (..))"]
    kirokuTypes = case rmFeed readModel of
        RmInline -> "GlobalPosition"
        RmSubscription -> "GlobalPosition, RecordedEvent (..)"
    projectionNames = case rmFeed readModel of
        RmInline -> "[]"
        RmSubscription -> "[" <> tshow asyncName <> "]"
    asyncDefinition = case rmFeed readModel of
        RmInline -> []
        RmSubscription ->
            [ ""
            , asyncValueName <> " :: AsyncProjection"
            , asyncValueName <> " ="
            , "  AsyncProjection"
            , "    { name = " <> tshow asyncName
            , "    , readModelName = " <> tshow registryName
            , "    , subscriptionName = " <> tshow subscriptionName
            , "    , applyRecorded = " <> applyName
            , "    , idempotencyKey = \\recorded -> recorded.eventId"
            , "    }"
            ]
    consistencyExpr Strong = "Strong"
    consistencyExpr Eventual = "Eventual"
    scopeExpr Nothing = "EntireLog"
    scopeExpr (Just RmEntireLog) = "EntireLog"
    scopeExpr (Just (RmCategory categoryName)) = "CategoryHead " <> tshow categoryName

emitReadModelHoles :: Text -> Text -> Text -> ReadModelNode -> Text
emitReadModelHoles tableModule readModelHolePrefix stem readModel =
    nl $
        [ "-- This is a HAND-OWNED hole module. keiro-dsl creates it once and never overwrites it."
        , "module " <> readModelHolePrefix <> ".ReadModelHoles"
        , "  ( " <> T.intercalate "\n  , " exports
        , "  ) where"
        , ""
        , "import " <> tableModule <> " (" <> qualifiedName <> ")"
        , "import Hasql.Transaction qualified as Tx"
        ]
            ++ ["import Kiroku.Store.Types (RecordedEvent(..))" | rmFeed readModel == RmSubscription]
            ++ [ ""
               , "-- HOLE: replace these aliases with the real query input and result types."
               , "type " <> queryInputType <> " = ()"
               , "type " <> queryResultType <> " = ()"
               , ""
               , "-- HOLE: query " <> qualifiedTableLiteral readModel <> " via " <> qualifiedName <> "; never rely on search_path."
               , "-- Declared columns:"
               ]
            ++ map (("--   " <>) . readModelColumnDoc) (rmColumns readModel)
            ++ [ queryName <> " :: " <> queryInputType <> " -> Tx.Transaction " <> queryResultType
               , queryName <> " _input = " <> qualifiedName <> " `seq` error " <> tshow ("HOLE: fill " <> rmName readModel <> " query")
               ]
            ++ applyStub
  where
    qualifiedName = stem <> "QualifiedTable"
    queryInputType = pascal stem <> "QueryInput"
    queryResultType = pascal stem <> "QueryResult"
    queryName = stem <> "Query"
    applyName = "apply" <> pascal stem
    exports = [queryInputType, queryResultType, queryName] ++ [applyName | rmFeed readModel == RmSubscription]
    applyStub = case rmFeed readModel of
        RmInline -> []
        RmSubscription ->
            [ ""
            , "-- HOLE: apply one recorded event; runtime deduplication makes redelivery safe."
            , applyName <> " :: RecordedEvent -> Tx.Transaction ()"
            , applyName <> " _recorded = error " <> tshow ("HOLE: fill " <> rmName readModel <> " async apply")
            ]

qualifiedTableLiteral :: ReadModelNode -> Text
qualifiedTableLiteral readModel = quoteSqlIdentifier (rmSchema readModel) <> "." <> quoteSqlIdentifier (rmTable readModel)

quoteSqlIdentifier :: Text -> Text
quoteSqlIdentifier identifier = "\"" <> T.replace "\"" "\"\"" identifier <> "\""

readModelColumnDoc :: RmColumn -> Text
readModelColumnDoc columnDecl =
    rmcName columnDecl
        <> " "
        <> rmcType columnDecl
        <> if rmcRequired columnDecl then " NOT NULL" else ""

--------------------------------------------------------------------------------
-- Router + shared worker-policy lowering (EP-108)
--------------------------------------------------------------------------------

scaffoldRouter :: Context -> RouterNode -> [ScaffoldModule]
scaffoldRouter ctx router =
    [ ScaffoldModule
        { modulePath = modulePathFor genPrefix "Router"
        , moduleText = emitRouterGen genPrefix router
        , kind = Generated
        , origin = routerOrigin
        }
    , ScaffoldModule
        { modulePath = modulePathFor holePrefix "RouterHoles"
        , moduleText = emitRouterHoles holePrefix router
        , kind = HoleStub
        , origin = routerOrigin
        }
    ]
  where
    genPrefix = genPrefixFor ctx (rtId router)
    holePrefix = holePrefixFor ctx (rtId router)
    routerOrigin = nodeOrigin "router" (rtId router) (rtLoc router)

emitRouterGen :: Text -> RouterNode -> Text
emitRouterGen genPrefix router =
    nl $
        [ "{-# LANGUAGE OverloadedStrings #-}"
        , generatedBanner
        , "module " <> genPrefix <> ".Router"
        , "  ( " <> stem <> "Name"
        , "  , " <> stem <> "WorkerOptions"
        , "  ) where"
        , ""
        , "import Data.Text (Text)"
        ]
            ++ workerPolicyImports (rtPoison router)
            ++ [ ""
               , "-- The STABLE router name. It participates in every target-keyed"
               , "-- deterministicRouterCommandId; renaming it re-keys replayed dispatches."
               , stem <> "Name :: Text"
               , stem <> "Name = " <> tshow (rtName router)
               , ""
               , "-- Runtime-owned dispatch id inputs: (name, key, sourceEventId,"
               , "-- targetStreamName, occurrence). Target-keyed, not positional."
               , ""
               , "-- Node-level worker policy lowered from the spec. Pass this value to"
               , "-- Keiro.Router.runRouterWorkerWith; do not silently use defaultWorkerOptions."
               ]
            ++ workerOptionsLines (stem <> "WorkerOptions") (rtRejected router) (rtPoison router)
  where
    stem = lowerFirst (rtId router)

emitRouterHoles :: Text -> RouterNode -> Text
emitRouterHoles holePrefix router =
    nl
        [ "-- HAND-OWNED hole module for the router's behaviour-bearing bodies."
        , "-- keiro-dsl creates it once and never overwrites it."
        , "module " <> holePrefix <> ".RouterHoles () where"
        , ""
        , "-- HOLE resolve :: " <> inName (rtInput router) <> " -> Eff es [PMCommand targetCommand]"
        , "--   Spec source: " <> resolveSourceText (rvSource (rtResolve router)) <> "."
        , "--   The spec's 'stable' keyword acknowledges that retry attempts accumulate"
        , "--   the UNION of resolved target identities. Keep the recipient set stable"
        , "--   for a source event whenever an exact recipient set matters."
        , "-- HOLE router value: assemble Keiro.Router.Router with name = " <> lowerFirst (rtId router) <> "Name,"
        , "--   key, resolve, targetEventStream, and targetProjections; run it with"
        , "--   runRouterWorkerWith " <> lowerFirst (rtId router) <> "WorkerOptions."
        , "-- HOLE targetProjections: spec projections = " <> renderNames (rtProjections router) <> "."
        , "-- NOTE on-duplicate AckOk is sound because Keiro.Router confirms a duplicate"
        , "--   event id against the TARGET stream via confirmBenignDuplicate before"
        , "--   returning PMCommandDuplicate. Hand-rolled dispatch paths must do likewise."
        ]
  where
    renderNames names = "[" <> T.intercalate ", " names <> "]"

resolveSourceText :: ResolveSource -> Text
resolveSourceText (ResolveReadModel name) = "read-model " <> name <> " (typically Keiro.ReadModel.runQuery)"
resolveSourceText ResolveHole = "typed resolver hole"

workerPolicyImports :: PolicyChoice -> [Text]
workerPolicyImports poison =
    [ "import Keiro.ProcessManager (PoisonPolicy (..), RejectedCommandPolicy (..), WorkerOptions (..))"
    , "import Shibuya.Core.Ack (RetryDelay (..))"
    ]
        ++ if poison == PolHalt
            then []
            else ["import Effectful (Eff)", "import Shibuya.Core.Types (Envelope)"]

workerOptionsLines :: Text -> PolicyChoice -> PolicyChoice -> [Text]
workerOptionsLines valueName rejected poison =
    [ valueName <> signature
    , valueName <> argument <> " ="
    , "  WorkerOptions"
    , "    { poisonPolicy = " <> poisonExpr
    , "    , rejectedCommandPolicy = " <> rejectedExpr rejected
    , "    , transientRetryDelay = RetryDelay 5 -- matches defaultWorkerOptions; runtime tuning"
    , "    , metrics = Nothing                  -- runtime configuration; install at call site"
    , "    }"
    ]
  where
    signature = case poison of
        PolHalt -> " :: WorkerOptions es msg"
        _ -> " :: (Envelope msg -> Eff es ()) -> WorkerOptions es msg"
    argument = case poison of
        PolHalt -> ""
        _ -> " poisonCallback"
    poisonExpr = case poison of
        PolHalt -> "PoisonHalt"
        PolDeadLetter -> "PoisonDeadLetter poisonCallback"
        PolSkip -> "PoisonSkip poisonCallback"
    rejectedExpr = \case
        PolHalt -> "RejectedHalt"
        PolDeadLetter -> "RejectedDeadLetter"
        PolSkip -> "RejectedSkip"

--------------------------------------------------------------------------------
-- Process manager + durable timer (EP-3)
--------------------------------------------------------------------------------

{- | Emit the symbol-free deterministic wiring for a process manager + its timer
into a @Generated@ module, plus a create-if-absent @ProcessHoles@ module for the
behaviour-bearing bodies (the @handle@ reaction, the deadline window, and the
fire command). The @Generated@ module contains no keiki symbolic operator (the
saga's transducer is the separate aggregate hole), so the firewall invariant
holds. The timer worker uses the spec's @max-attempts@ ceiling, never the
dangerous @defaultTimerWorkerOptions@ (@Nothing@) default.
-}
scaffoldProcess :: Context -> ProcessNode -> [ScaffoldModule]
scaffoldProcess ctx p =
    [ ScaffoldModule
        { modulePath = T.unpack (T.replace "." "/" genPrefix <> "/Process.hs")
        , moduleText = emitProcessGen ctxPascal genPrefix holePrefix p
        , kind = Generated
        , origin = nodeOrigin "process" (procId p) (procLoc p)
        }
    , ScaffoldModule
        { modulePath = T.unpack (T.replace "." "/" holePrefix <> "/ProcessHoles.hs")
        , moduleText = emitProcessHoles genPrefix holePrefix p
        , kind = HoleStub
        , origin = nodeOrigin "process" (procId p) (procLoc p)
        }
    ]
  where
    ctxPascal = pascalFromKebab (contextName ctx)
    genPrefix = genPrefixFor ctx (procId p)
    holePrefix = holePrefixFor ctx (procId p)

emitProcessGen :: Text -> Text -> Text -> ProcessNode -> Text
emitProcessGen _ctxPascal genPrefix _holePrefix p =
    nl $
        [ "{-# LANGUAGE OverloadedStrings #-}"
        , generatedBanner
        , "module " <> genPrefix <> ".Process"
        , "  ( " <> lo <> "ProcessName"
        , "  , " <> lo <> "Category"
        , "  , " <> lo <> "ProcessWorkerOptions"
        , "  , " <> lo <> "TimerRequest"
        , "  , " <> lo <> "FireOutcome"
        , "  ) where"
        , ""
        , "import Data.Aeson (Value, object, (.=))"
        , "import Data.Text (Text)"
        , "import qualified Data.Text as T"
        , "import Data.Time (UTCTime)"
        , "import Data.UUID (UUID)"
        , "import qualified Data.UUID.V5 as UUID.V5"
        , "import Keiro.Command (CommandError (..))"
        , "import Keiro.Stream qualified as Stream"
        , "import Keiro.Timer (TimerId (..), TimerRequest (..))"
        ]
            ++ workerPolicyImports (procPoison p)
            ++ [ ""
               , "-- The define-once ProcessManager name (hole-kind 5: referenced, never retyped)."
               , lo <> "ProcessName :: Text"
               , lo <> "ProcessName = " <> tshow (procName p)
               , ""
               , "-- The validated saga stream category (hole-kind 5: referenced, never retyped)."
               , "-- Saga streams are '<category>-<correlationId>' via Keiro.Stream.entityStream."
               , "-- categoryUnsafe is safe here because keiro-dsl check proved the literal legal."
               , lo <> "Category :: Stream.StreamCategory a"
               , lo <> "Category = Stream.categoryUnsafe " <> tshow categoryName
               , ""
               , "-- Node-level worker policy lowered from the spec. Pass this value to"
               , "-- Keiro.ProcessManager.runProcessManagerWorkerWith."
               ]
            ++ workerOptionsLines (lo <> "ProcessWorkerOptions") (procRejected p) (procPoison p)
            ++ [ ""
               , "-- The deterministic timer-request builder: id derived from the correlation"
               , "-- key (hole-kind 1), processManagerName referenced, payload from the spec."
               , "-- (timer id derived as uuidv5 of " <> tshow (idePrefix (tmId timer)) <> " <> correlationId)"
               , lo <> "TimerRequest :: Text -> UTCTime -> TimerRequest"
               , lo <> "TimerRequest correlationId fireAtTime ="
               , "  TimerRequest"
               , "    { timerId = TimerId (namedUuid (" <> tshow (idePrefix (tmId timer)) <> " <> correlationId))"
               , "    , processManagerName = " <> lo <> "ProcessName"
               , "    , correlationId = correlationId"
               , "    , fireAt = fireAtTime"
               , "    , payload = " <> payloadExpr (tmPayload timer)
               , "    }"
               , ""
               , "-- The timer-fire disposition table (hole-kind 2), derived from the spec."
               , "-- on-reject => " <> showOutcome (onReject fd) <> " is the benign inversion."
               , "-- A duplicate append reaches on-error unless it is confirmed against the"
               , "-- target stream. Use Keiro.ProcessManager.confirmBenignDuplicate:"
               , "--   StreamName -> EventId -> CommandError -> Eff es Bool"
               , "-- Fold True into the duplicate result and surface False as the failure."
               , lo <> "FireOutcome :: Either CommandError a -> Maybe ()"
               , lo <> "FireOutcome result = case result of"
               , "  Right{} -> " <> outcomeToMaybe (onOk fd)
               , "  Left CommandRejected -> " <> outcomeToMaybe (onReject fd)
               , "  Left (CommandAmbiguous _) -> " <> outcomeToMaybe (onAmbiguous fd) <> "  -- explicit definition-bug arm"
               , "  Left{} -> " <> outcomeToMaybe (onError fd)
               , ""
               , "-- max-attempts = " <> tshow' (tmMaxAttempts timer) <> ", dead-letter = " <> tshow (tmDeadLetter timer)
               , "-- (the timer worker must pass Just " <> tshow' (tmMaxAttempts timer) <> " to runTimerWorkerWith, never the"
               , "--  defaultTimerWorkerOptions Nothing ceiling that retries forever)."
               , ""
               , "-- deterministic v5 UUID of a correlation-keyed string (hole-kind 1)."
               , "namedUuid :: Text -> UUID"
               , "namedUuid v = UUID.V5.generateNamed UUID.V5.namespaceURL (map (fromIntegral . fromEnum) (T.unpack v))"
               ]
  where
    lo = lowerFirst (procId p)
    categoryName = staticCategory ("process " <> procId p) (sagaCategory (procSaga p))
    timer = procTimer p
    fd = fireDisposition (tmFire timer)

{- | The timer payload, restricted to the spec's literal (@name=\"value\"@)
bindings so it compiles in the deterministic builder. Bare fields and
ref-valued bindings are input-driven (the agent-written hole), not emitted.
-}
payloadExpr :: [FieldBinding] -> Text
payloadExpr fs = case [b | b <- fs, isLiteral b] of
    [] -> "object []"
    lits -> "object [ " <> T.intercalate ", " (map kv lits) <> " ]"
  where
    isLiteral b = maybe False (const True) (fbValue b >>= stripWrappingQuotes)
    kv b = tshow (fbName b) <> " .= (" <> maybe "\"\"" tshow (fbValue b >>= stripWrappingQuotes) <> " :: Value)"
    stripWrappingQuotes value = T.stripPrefix "\"" value >>= T.stripSuffix "\""

showOutcome :: FireOutcome -> Text
showOutcome OFired = "Fired"
showOutcome ORetry = "Retry"

outcomeToMaybe :: FireOutcome -> Text
outcomeToMaybe OFired = "Just ()  -- Fired"
outcomeToMaybe ORetry = "Nothing  -- Retry"

emitProcessHoles :: Text -> Text -> ProcessNode -> Text
emitProcessHoles _genPrefix holePrefix p =
    nl
        [ "-- HAND-OWNED hole module for the process manager's behaviour-bearing bodies."
        , "-- keiro-dsl creates it once and never overwrites it."
        , "module " <> holePrefix <> ".ProcessHoles () where"
        , ""
        , "-- HOLE handle: build the ProcessManagerAction (the self-advance"
        , "--   '" <> advCommand (hAdvance (procHandle p)) <> "', the dispatch(es), and the timer) from the input."
        , "-- HOLE streams: build streamFor with entityStream " <> lowerFirst (procId p) <> "Category;"
        , "--   build target streams with entityStream " <> lowerFirst (procTarget p) <> "Category. Never concatenate raw stream names."
        , "-- HOLE window: the deadline policy, e.g. surgeWindow :: NominalDiffTime;"
        , "--   surgeDeadline observedAt = addUTCTime surgeWindow observedAt  (TIME INJECTED)."
        , "-- HOLE fire command: construct " <> fireCommand (tmFire (procTimer p)) <> " for the timer fire,"
        , "--   keyed by correlationId; the fired-event-id is the deterministic uuidv5 of"
        , "--   " <> tshow (idePrefix (fireFiredEventId (tmFire (procTimer p)))) <> " <> correlationId."
        , "-- NOTE on-duplicate AckOk is sound because the runtime confirms a duplicate"
        , "--   event id against the TARGET stream via confirmBenignDuplicate before"
        , "--   returning PMCommandDuplicate. Its effective signature is:"
        , "--     StreamName -> EventId -> CommandError -> Eff es Bool"
        , "--   Hand-rolled paths must call it with the target stream and attempted event id,"
        , "--   fold True into the duplicate result, and surface False as the original failure."
        , "--   Never pattern-match DuplicateEvent as success: event ids are globally unique."
        ]

--------------------------------------------------------------------------------
-- Domain module
--------------------------------------------------------------------------------

emitDomain :: Agg -> Text
emitDomain a =
    nl $
        [ "{-# LANGUAGE DataKinds #-}"
        , "{-# LANGUAGE DuplicateRecordFields #-}"
        ]
            ++ ["{-# LANGUAGE DeriveAnyClass #-}" | hasSnapshot a]
            ++ [ "{-# LANGUAGE OverloadedStrings #-}"
               , "{-# LANGUAGE TemplateHaskell #-}"
               , "{-# LANGUAGE TypeApplications #-}"
               , "{-# OPTIONS_GHC -Wno-unused-top-binds #-}"
               , generatedBanner
               , "module " <> aGenPrefix a <> ".Domain where"
               , ""
               ]
            ++ ["import Data.Aeson (FromJSON, ToJSON)" | hasSnapshot a]
            ++ [ "import Data.Proxy (Proxy (..))"
               , "import Data.Text (Text)"
               , "import GHC.Generics (Generic)"
               , "import Keiki.Core (RegFile (..))"
               ]
            ++ ["import Keiki.Shape (CanonicalStateShape, CanonicalTypeName)" | hasSnapshot a]
            ++ [ "import Keiki.Generics.TH (deriveAggregateCtorsAll, deriveWireCtorsAll)"
               , ""
               , sectionsOf
                    [ map (emitId a) (aIds a)
                    , map (emitEnum a) (aEnums a)
                    , [emitVertex a]
                    , map (emitRecord) (aCommands a)
                    , [emitSum (aName a <> "Command") (aCommands a)]
                    , map (emitRecord) (aEvents a)
                    , [emitSum (aName a <> "Event") (aEvents a)]
                    , [emitRegsType a, emitInitialRegs a]
                    ,
                        [ "$(deriveAggregateCtorsAll ''" <> aName a <> "Command ''" <> aName a <> "Regs)"
                        , ""
                        , "$(deriveWireCtorsAll ''" <> aName a <> "Event)"
                        ]
                    ]
               ]

hasSnapshot :: Agg -> Bool
hasSnapshot = maybe False (const True) . aSnapshot

emitId :: Agg -> IdDecl -> Text
emitId a d =
    nl $
        [ "newtype " <> idName d <> " = " <> idName d <> " Text"
        , "  deriving stock (Generic, Eq, Ord, Show)"
        ]
            ++ ["  deriving anyclass (ToJSON, FromJSON)" | hasSnapshot a]
            ++ ["instance CanonicalTypeName " <> idName d | hasSnapshot a]
            ++ [ ""
               , lowerFirst (idName d) <> "Text :: " <> idName d <> " -> Text"
               , lowerFirst (idName d) <> "Text (" <> idName d <> " t) = t"
               ]

emitEnum :: Agg -> EnumDecl -> Text
emitEnum a d =
    nl $
        [ "data " <> enumName d <> " = " <> T.intercalate " | " (map fst (enumCtors d))
        , "  deriving stock (Generic, Eq, Ord, Show, Enum, Bounded)"
        ]
            ++ ["  deriving anyclass (ToJSON, FromJSON)" | hasSnapshot a]
            ++ ["instance CanonicalTypeName " <> enumName d | hasSnapshot a]
            ++ [ ""
               , lowerFirst (enumName d) <> "Text :: " <> enumName d <> " -> Text"
               , lowerFirst (enumName d) <> "Text = \\case"
               , nl ["  " <> c <> " -> " <> tshow w | (c, w) <- enumCtors d]
               ]

emitVertex :: Agg -> Text
emitVertex a =
    nl $
        [ "data " <> aVertexType a <> " = " <> T.intercalate " | " (map (vertexCtor a . stName) (aStates a))
        , "  deriving stock (Generic, Eq, Ord, Show, Enum, Bounded)"
        ]
            ++ ["  deriving anyclass (ToJSON, FromJSON)" | hasSnapshot a]
            ++ [ line
               | hasSnapshot a
               , line <-
                    [ "instance CanonicalStateShape " <> aVertexType a
                    , "instance CanonicalTypeName " <> aVertexType a
                    ]
               ]

emitRecord :: ResolvedCtor -> Text
emitRecord rc =
    nl $
        [ "data " <> rcName rc <> "Data = " <> rcName rc <> "Data"
        ]
            ++ recordFields (rcFields rc)
            ++ ["  deriving stock (Generic, Eq, Show)"]

recordFields :: [(Text, Text)] -> [Text]
recordFields [] =
    ["  {"]
        <> ["  }"]
recordFields fs =
    [ lead i <> n <> " :: !" <> ty
    | (i, (n, ty)) <- zip [(0 :: Int) ..] fs
    ]
        ++ ["  }"]
  where
    lead 0 = "  { "
    lead _ = "  , "

emitSum :: Text -> [ResolvedCtor] -> Text
emitSum tyName ctors =
    nl $
        [firstLine] ++ restLines ++ ["  deriving stock (Generic, Eq, Show)"]
  where
    arm rc = rc' rc
    rc' rc = rcName rc <> " !" <> rcName rc <> "Data"
    (firstLine, restLines) = case ctors of
        [] -> ("data " <> tyName <> " = ()", [])
        (c : cs) ->
            ( "data " <> tyName <> " = " <> arm c
            , ["  | " <> arm c2 | c2 <- cs]
            )

emitRegsType :: Agg -> Text
emitRegsType a =
    nl $
        ["type " <> aName a <> "Regs ="]
            ++ regListLines (aRegs a)

regListLines :: [RegDecl] -> [Text]
regListLines [] = ["  '[]"]
regListLines rs =
    [ lead i <> "'(" <> tshow (regName r) <> ", " <> regType r <> ")"
    | (i, r) <- zip [(0 :: Int) ..] rs
    ]
        ++ ["   ]"]
  where
    lead 0 = "  '[ "
    lead _ = "   , "

emitInitialRegs :: Agg -> Text
emitInitialRegs a =
    nl $
        [ "initial" <> aName a <> "Regs :: RegFile " <> aName a <> "Regs"
        , "initial" <> aName a <> "Regs ="
        ]
            ++ chain (aRegs a)
  where
    chain [] = ["  RNil"]
    chain rs =
        [ "  RCons (Proxy @" <> tshow (regName r) <> ") " <> regInitialValue a r <> " $"
        | r <- init rs
        ]
            ++ ["  RCons (Proxy @" <> tshow (regName lastR) <> ") " <> regInitialValue a lastR <> " RNil"]
      where
        lastR = last rs

-- | The Haskell initial value for a register, by the category of its type.
regInitialValue :: Agg -> RegDecl -> Text
regInitialValue a r
    | regType r `elem` idNames = "(" <> regType r <> " \"\")"
    | regType r == aVertexType a = maybe "(error \"invalid vertex initial\")" (vertexCtor a) (bareInitial r)
    | regType r == "Text" = maybe "(error \"Text initial must be quoted\")" tshow (textInitial r)
    | otherwise = maybe "(error \"invalid register initial\")" id (bareInitial r)
  where
    idNames = map idName (aIds a)
    bareInitial reg = case regInitial reg of
        RegInitBare value -> Just value
        RegInitText _ -> Nothing
    textInitial reg = case regInitial reg of
        RegInitText value -> Just value
        RegInitBare _ -> Nothing

--------------------------------------------------------------------------------
-- Codec module
--------------------------------------------------------------------------------

emitCodec :: Agg -> Text
emitCodec a =
    nl
        [ "{-# LANGUAGE OverloadedRecordDot #-}"
        , "{-# LANGUAGE OverloadedStrings #-}"
        , generatedBanner
        , "module " <> aGenPrefix a <> ".Codec ("
        , "    " <> lowerFirst (aName a) <> "Codec,"
        , "    parse" <> aName a <> "Event,"
        , "    encode" <> aName a <> "Event,"
        , ") where"
        , ""
        , "import " <> aGenPrefix a <> ".Domain"
        , "import Data.Aeson (Value, object, withObject, (.:), (.=))"
        , "import Data.Aeson.Types (Parser, parseEither)"
        , "import Data.List.NonEmpty (NonEmpty (..))"
        , "import Data.Text (Text)"
        , "import qualified Data.Text as T"
        , "import Keiro.Codec (Codec (..), EventType (..))"
        , upcasterImport a
        , ""
        , emitEnumParsers a
        , ""
        , emitCodecValue a
        , ""
        , emitEncode a
        , ""
        , emitDecode a
        , ""
        , "mapLeftText :: Either String b -> Either Text b"
        , "mapLeftText = either (Left . T.pack) Right"
        ]

emitEnumParsers :: Agg -> Text
emitEnumParsers a = sectionsOf [[emitEnumParser e | e <- aEnums a]]

emitEnumParser :: EnumDecl -> Text
emitEnumParser d =
    nl $
        [ "parse" <> enumName d <> " :: Text -> Parser " <> enumName d
        , "parse" <> enumName d <> " = \\case"
        ]
            ++ ["  " <> tshow w <> " -> pure " <> c | (c, w) <- enumCtors d]
            ++ ["  _ -> fail " <> tshow ("unknown " <> enumName d)]

emitCodecValue :: Agg -> Text
emitCodecValue a =
    nl $
        [ lowerFirst (aName a) <> "Codec :: Codec " <> aName a <> "Event"
        , lowerFirst (aName a) <> "Codec ="
        , "  Codec"
        , "    { eventTypes = " <> eventTypesExpr
        , "    , eventType = \\case"
        ]
            ++ ["        " <> rcName e <> "{} -> EventType " <> tshow (rcName e) | e <- aEvents a]
            ++ [ "    , schemaVersion = " <> tshow' (maxEventVersion a)
               , "    , encode = encode" <> aName a <> "Event"
               , "    , decode = parse" <> aName a <> "Event"
               , "    , upcasters = " <> upcastersExpr a
               , "    }"
               ]
  where
    eventTypesExpr = case map rcName (aEvents a) of
        [] -> "error \"no events\""
        (e : es) -> "EventType " <> tshow e <> " :| [" <> T.intercalate ", " (map (("EventType " <>) . tshow) es) <> "]"

-- | The codec's @schemaVersion@: the maximum declared event version (EP-2).
maxEventVersion :: Agg -> Int
maxEventVersion a = maximum (1 : map rcVersion (aEvents a))

{- | One @(sourceVersion, upcasterName)@ entry per event that declares an
@upcast from@. The upcaster name is per-event (e.g. @upcastFooV1@) and its
body is a hole in the hand-owned Holes module.
-}
upcasterEntries :: Agg -> [(Int, Text)]
upcasterEntries a =
    [ (m, "upcast" <> rcName e <> "V" <> tshow' m)
    | e <- aEvents a
    , Just m <- [rcUpcastFrom e]
    ]

upcastersExpr :: Agg -> Text
upcastersExpr a =
    "[" <> T.intercalate ", " ["(" <> tshow' m <> ", const " <> fn <> ")" | (m, fn) <- upcasterEntries a] <> "]"

{- | When the codec references upcasters, it imports their (hole) definitions
from the hand-owned Holes module.
-}
upcasterImport :: Agg -> Text
upcasterImport a = case upcasterEntries a of
    [] -> ""
    es -> "import " <> aHolePrefix a <> ".Holes (" <> T.intercalate ", " (map snd es) <> ")"

emitEncode :: Agg -> Text
emitEncode a =
    nl $
        [ "encode" <> aName a <> "Event :: " <> aName a <> "Event -> Value"
        , "encode" <> aName a <> "Event = \\case"
        ]
            ++ concatMap encodeArm (aEvents a)
  where
    encodeArm e =
        [ "  " <> rcName e <> " payload ->"
        , "    object"
        ]
            ++ [ lead i <> kv
               | (i, kv) <- zip [(0 :: Int) ..] (("\"kind\" .= (" <> tshow (rcName e) <> " :: Text)") : map encodeField (rcFields e))
               ]
            ++ ["      ]"]
    lead 0 = "      [ "
    lead _ = "      , "
    encodeField (n, ty) =
        tshow n
            <> " .= "
            <> case fieldCat a ty of
                IdCat -> lowerFirst ty <> "Text payload." <> n
                EnumCat -> lowerFirst ty <> "Text payload." <> n
                _ -> "payload." <> n

emitDecode :: Agg -> Text
emitDecode a =
    nl $
        [ "parse" <> aName a <> "Event :: EventType -> Value -> Either Text " <> aName a <> "Event"
        , "parse" <> aName a <> "Event (EventType tag) = mapLeftText . parseEither (withObject " <> tshow (aName a <> "Event") <> " go)"
        , "  where"
        , "    go o = do"
        , "      case tag of"
        ]
            ++ concatMap decodeArm (aEvents a)
            ++ ["        _ -> fail \"unknown event type\""]
  where
    decodeArm e =
        [ "        " <> tshow (rcName e) <> " ->"
        , "          " <> rcName e <> " <$> (" <> rcName e <> "Data" <> fieldApps (rcFields e) <> ")"
        ]
    fieldApps [] = ""
    fieldApps fs = " <$> " <> T.intercalate " <*> " (map decodeField fs)
    -- The first field uses <$> (handled above), the rest <*>. We instead build
    -- a uniform list and join; for an empty record there are no fields.
    decodeField (n, ty) = case fieldCat a ty of
        IdCat -> "(" <> ty <> " <$> o .: " <> tshow n <> ")"
        EnumCat -> "(o .: " <> tshow n <> " >>= parse" <> ty <> ")"
        _ -> "o .: " <> tshow n

--------------------------------------------------------------------------------
-- EventStream module
--------------------------------------------------------------------------------

emitEventStream :: Agg -> Text
emitEventStream a =
    nl $
        [ generatedBanner
        , "module " <> aGenPrefix a <> ".EventStream"
        , "  ( " <> lowerFirst (aName a) <> "Category"
        , "  , " <> lowerFirst (aName a) <> "EventStream"
        , "  , " <> lowerFirst (aName a) <> "EventStreamDef"
        , "  , " <> aName a <> "EventStream"
        , "  , " <> aName a <> "EventStreamDef"
        ]
            ++ ["  , " <> lowerFirst (aName a) <> "SnapshotFixture" | hasSnapshot a]
            ++ [ "  ) where"
               , ""
               , "import " <> aGenPrefix a <> ".Domain"
               , "import " <> aGenPrefix a <> ".Codec (" <> lowerFirst (aName a) <> "Codec)"
               , "import " <> aHolePrefix a <> ".Holes (" <> lowerFirst (aName a) <> "Transducer)"
               , "import Keiki.Core (HsPred)"
               , "import Keiro.EventStream (EventStream (..), SnapshotPolicy (..))"
               , "import Keiro.EventStream.Validate (ValidatedEventStream, mkEventStreamOrThrow)"
               ]
            ++ ["import Data.Text (Text)" | hasSnapshot a]
            ++ ["import Keiro.Snapshot.Codec (defaultStateCodec, withFoldFingerprint)" | hasSnapshot a]
            ++ [ "import Keiro.Stream qualified as Stream"
               , ""
               , "-- The validated aggregate stream category (hole-kind 5: referenced, never retyped)."
               , "-- Entity streams are '<category>-<id>' via Keiro.Stream.entityStream."
               , "-- categoryUnsafe is safe here because this generated literal passed the DSL category proof."
               , lowerFirst (aName a) <> "Category :: Stream.StreamCategory a"
               , lowerFirst (aName a) <> "Category = Stream.categoryUnsafe " <> tshow categoryName
               , ""
               , "type " <> aName a <> "EventStreamDef ="
               , "  EventStream (HsPred " <> aName a <> "Regs " <> aName a <> "Command) " <> aName a <> "Regs " <> aVertexType a <> " " <> aName a <> "Command " <> aName a <> "Event"
               , ""
               , "type " <> aName a <> "EventStream ="
               , "  ValidatedEventStream (HsPred " <> aName a <> "Regs " <> aName a <> "Command) " <> aName a <> "Regs " <> aVertexType a <> " " <> aName a <> "Command " <> aName a <> "Event"
               , ""
               , lowerFirst (aName a) <> "EventStreamDef :: " <> aName a <> "EventStreamDef"
               , lowerFirst (aName a) <> "EventStreamDef ="
               , "  EventStream"
               , "    { transducer = " <> lowerFirst (aName a) <> "Transducer"
               , "    , initialState = " <> initialVertex a
               , "    , initialRegisters = initial" <> aName a <> "Regs"
               , "    , eventCodec = " <> lowerFirst (aName a) <> "Codec"
               , "    , resolveStreamName = Stream.streamName"
               , "    , snapshotPolicy = " <> snapshotPolicyExpr a
               ]
            ++ stateCodecFieldLines a
            ++ [ "    }"
               , ""
               ]
            ++ snapshotFixtureLines a
            ++ [ lowerFirst (aName a) <> "EventStream :: " <> aName a <> "EventStream"
               , lowerFirst (aName a) <> "EventStream ="
               , "  mkEventStreamOrThrow " <> tshow (aName a) <> " " <> lowerFirst (aName a) <> "EventStreamDef"
               ]
  where
    categoryName = staticCategory ("aggregate " <> aName a) (lowerFirst (aName a))

snapshotPolicyExpr :: Agg -> Text
snapshotPolicyExpr aggregate = case aSnapshot aggregate of
    Nothing -> "Never"
    Just snapshot -> case snapPolicy snapshot of
        SnapEvery interval -> "Every " <> tshow' interval
        SnapOnTerminal -> "OnTerminal"

stateCodecExpr :: Agg -> Text
stateCodecExpr aggregate = case aSnapshot aggregate of
    Nothing -> "Nothing"
    Just snapshot ->
        "Just (withFoldFingerprint "
            <> tshow (aFoldFingerprint aggregate)
            <> " (defaultStateCodec "
            <> tshow' (snapCodecVersion snapshot)
            <> "))"

stateCodecFieldLines :: Agg -> [Text]
stateCodecFieldLines aggregate = case aSnapshot aggregate of
    Nothing -> ["    , stateCodec = Nothing"]
    Just _ ->
        [ "    -- The snapshot discriminator composes: the spec's state-codec version (bump it"
        , "    -- in the spec's `state-codec version=` clause), keiki's register and"
        , "    -- control-state shape hashes, and this fold fingerprint derived from the"
        , "    -- spec's transition surface (guards, writes, emits, states, register"
        , "    -- initials, referenced rules). Spec-visible fold changes invalidate old"
        , "    -- snapshots automatically. Fold changes made ONLY in the hand-owned Holes"
        , "    -- module are invisible here: bump `state-codec version=` manually or old"
        , "    -- snapshots will be served stale."
        , "    , stateCodec = " <> stateCodecExpr aggregate
        ]

snapshotFixtureLines :: Agg -> [Text]
snapshotFixtureLines aggregate = case aSnapshot aggregate of
    Nothing -> []
    Just snapshot ->
        [ lowerFirst (aName aggregate) <> "SnapshotFixture :: (Int, Text)"
        , lowerFirst (aName aggregate) <> "SnapshotFixture = (" <> tshow' (snapCodecVersion snapshot) <> ", " <> tshow (snapShapeHash snapshot) <> ")"
        , ""
        ]

--------------------------------------------------------------------------------
-- Projection module
--------------------------------------------------------------------------------

emitProjection :: Agg -> Text
emitProjection a = case aProjection a of
    Nothing -> nl [generatedBanner, "module " <> aGenPrefix a <> ".Projection () where"]
    Just p ->
        nl
            [ "{-# LANGUAGE OverloadedRecordDot #-}"
            , "{-# LANGUAGE OverloadedStrings #-}"
            , generatedBanner
            , "module " <> aGenPrefix a <> ".Projection"
            , "  ( " <> lowerFirst (projTable p) <> "Projection"
            , "  , " <> lowerFirst (projTable p) <> "StatusFor"
            , "  ) where"
            , ""
            , "import " <> aGenPrefix a <> ".Domain"
            , "import " <> aHolePrefix a <> ".Holes (apply" <> pascal (projTable p) <> ")"
            , "import Data.Text (Text)"
            , "import Keiro.Projection (InlineProjection (..))"
            , ""
            , "-- The deterministic event->status mapping (hole-kind 3, /mapping/), derived"
            , "-- from the spec's status-map. The read-model SQL that consumes it lives in"
            , "-- the hand-owned Holes module (a DB-coupled hole, delegated to codd)."
            , projectionTableComment a p
            , lowerFirst (projTable p) <> "StatusFor :: " <> aName a <> "Event -> Maybe Text"
            , lowerFirst (projTable p) <> "StatusFor = \\case"
            , nl (statusArms a p)
            , ""
            , lowerFirst (projTable p) <> "Projection :: InlineProjection " <> aName a <> "Event"
            , lowerFirst (projTable p) <> "Projection ="
            , "  InlineProjection"
            , "    { name = " <> tshow (contextNameToProjName a p)
            , "    , apply = apply" <> pascal (projTable p)
            , "    }"
            ]

statusArms :: Agg -> ProjectionSpec -> [Text]
statusArms a p =
    [ "  " <> rcName e <> " {} -> " <> statusFor e
    | e <- aEvents a
    ]
        ++ ["  _ -> Nothing" | hasWildcard]
  where
    pairs = maybe [] mapPairs (projStatusMap p)
    statusFor e = case lookup (rcName e) pairs of
        Just value -> "Just " <> tshow value
        Nothing -> "Nothing"
    -- A wildcard is only needed if some event is uncovered; otherwise every arm
    -- is explicit and a wildcard would be redundant (and -Wall would warn).
    hasWildcard = False

contextNameToProjName :: Agg -> ProjectionSpec -> Text
contextNameToProjName a p = contextKebab a <> "-" <> projTable p <> "-inline"

contextKebab :: Agg -> Text
contextKebab = kebabFromPascal . aCtxPascal

projectionReadModel :: Agg -> Maybe ReadModelNode
projectionReadModel aggregate = do
    projection <- aProjection aggregate
    find ((== projTable projection) . rmName) (aReadModels aggregate)

projectionTableComment :: Agg -> ProjectionSpec -> Text
projectionTableComment aggregate projection = case projectionReadModel aggregate of
    Nothing ->
        "-- WARNING: no readmodel node declares '"
            <> projTable projection
            <> "'; unqualified SQL depends on search_path."
    Just readModel ->
        "-- Qualified table "
            <> qualifiedTableLiteral readModel
            <> "; use "
            <> genPrefixFor (aContext aggregate) (pascal (rmName readModel))
            <> ".ReadModelTable."
            <> readModelStem readModel
            <> "QualifiedTable."

--------------------------------------------------------------------------------
-- Holes module (create-if-absent)
--------------------------------------------------------------------------------

emitHoles :: Agg -> Text
emitHoles a =
    nl
        [ "{-# LANGUAGE BlockArguments #-}"
        , "{-# LANGUAGE DataKinds #-}"
        , "{-# LANGUAGE OverloadedRecordDot #-}"
        , "{-# LANGUAGE QualifiedDo #-}"
        , "{-# LANGUAGE TypeApplications #-}"
        , "-- This is a HAND-OWNED hole module. keiro-dsl creates it once and never"
        , "-- overwrites it. Fill the transducer body (and any other holes) against the"
        , "-- generated signatures, then run the harness to confirm behaviour."
        , "module " <> aHolePrefix a <> ".Holes"
        , "  ( " <> lowerFirst (aName a) <> "Transducer"
        , holeProjectionExport a
        , holeUpcasterExports a
        , "  ) where"
        , ""
        , "import " <> aGenPrefix a <> ".Domain"
        , "import Keiki.Builder ((=:))"
        , "import qualified Keiki.Builder as B"
        , "import Keiki.Core (HsPred, RegFile, SymTransducer, lit, (.==), (./=), (.||))"
        , holeUpcasterImports a
        , holeProjectionImports a
        , ""
        , "-- HOLE: the transducer body. Reproduce the structure below, replacing each"
        , "-- `-- HOLE` line with the keiki symbolic operators it describes."
        , lowerFirst (aName a) <> "Transducer"
        , "  :: SymTransducer"
        , "       (HsPred " <> aName a <> "Regs " <> aName a <> "Command)"
        , "       " <> aName a <> "Regs"
        , "       " <> aVertexType a
        , "       " <> aName a <> "Command"
        , "       " <> aName a <> "Event"
        , lowerFirst (aName a) <> "Transducer ="
        , "  B.buildTransducer " <> initialVertex a <> " initial" <> aName a <> "Regs isTerminal do"
        , nl (concatMap (fromBlock a) (groupBySource a))
        , " where"
        , "  isTerminal = \\case"
        , nl ["    " <> vertexCtor a (stName s) <> " -> True" | s <- aStates a, stTerminal s]
        , "    _ -> False"
        , holeProjectionStub a
        , holeUpcasterStubs a
        ]

-- | Export, import, and stub the per-event upcaster holes (EP-2 evolution).
holeUpcasterExports :: Agg -> Text
holeUpcasterExports a = case upcasterEntries a of
    [] -> ""
    es -> nl ["  , " <> fn | (_, fn) <- es]

holeUpcasterImports :: Agg -> Text
holeUpcasterImports a = case upcasterEntries a of
    [] -> ""
    _ -> nl ["import Data.Aeson (Value)", "import Data.Text (Text)"]

holeUpcasterStubs :: Agg -> Text
holeUpcasterStubs a = case upcasterEntries a of
    [] -> ""
    es ->
        nl $
            concat
                [ [ ""
                  , "-- HOLE upcaster: bring a " <> fn <> " payload up one version. Decide the"
                  , "-- default/derivation for any field added at the new version here."
                  , fn <> " :: Value -> Either Text Value"
                  , fn <> " _ = Left \"HOLE: upcaster not implemented\""
                  ]
                | (_, fn) <- es
                ]

holeProjectionExport :: Agg -> Text
holeProjectionExport a = case aProjection a of
    Nothing -> "  -- (no projection)"
    Just p -> "  , apply" <> pascal (projTable p)

holeProjectionImports :: Agg -> Text
holeProjectionImports aggregate = case projectionReadModel aggregate of
    Nothing -> ""
    Just readModel ->
        "import "
            <> genPrefixFor (aContext aggregate) (pascal (rmName readModel))
            <> ".ReadModelTable ("
            <> readModelStem readModel
            <> "QualifiedTable)"

holeProjectionStub :: Agg -> Text
holeProjectionStub a = case aProjection a of
    Nothing -> ""
    Just p ->
        nl
            ( [ ""
              , "-- HOLE: the read-model SQL for the projection (a DB-coupled hole; the"
              , "-- pure event->status mapping is generated as " <> lowerFirst (projTable p) <> "StatusFor)."
              ]
                ++ projectionGuidance
                ++ [ "apply" <> pascal (projTable p) <> " :: " <> aName a <> "Event -> recorded -> txn ()"
                   , "apply" <> pascal (projTable p) <> " _event _recorded = " <> projectionTableUse <> "error \"HOLE: fill " <> projTable p <> " projection apply\""
                   ]
            )
      where
        projectionGuidance = case projectionReadModel a of
            Nothing ->
                ["-- WARNING: no readmodel node declares this table's schema; unqualified SQL depends on search_path."]
            Just readModel ->
                [ "-- Table: " <> qualifiedTableLiteral readModel <> ". Use " <> readModelStem readModel <> "QualifiedTable; never rely on search_path."
                , "-- Declared columns:"
                ]
                    ++ map (("--   " <>) . readModelColumnDoc) (rmColumns readModel)
        projectionTableUse = case projectionReadModel a of
            Nothing -> ""
            Just readModel -> readModelStem readModel <> "QualifiedTable `seq` "

-- Group transitions by source state, preserving order, for the B.from blocks.
groupBySource :: Agg -> [(Text, [Transition])]
groupBySource a = go [] (transitionsOf a)
  where
    go acc [] = reverse acc
    go acc (t : ts) =
        let src = tSource t
            (same, rest) = span ((== src) . tSource) ts
         in go ((src, t : same) : acc) rest

-- We don't keep the original Aggregate around in Agg, so reconstruct
-- transitions from a stored field. (Filled in resolveAgg via aTransitions.)
transitionsOf :: Agg -> [Transition]
transitionsOf = aTransitions

fromBlock :: Agg -> (Text, [Transition]) -> [Text]
fromBlock a (src, ts) =
    [ "    B.from " <> vertexCtor a src <> " do"
    ]
        ++ concatMap (onCmdBlock a) ts

onCmdBlock :: Agg -> Transition -> [Text]
onCmdBlock a t =
    [ "      B.onCmd inCtor" <> tCommand t <> " $ \\d -> B.do"
    ]
        -- Plan 143: the mode is structural, not hole-owned — a replay-only
        -- transition lowers to B.replayOnly (keiki ReplayOnly edge).
        ++ ["        B.replayOnly" | tMode t == TmReplayOnly]
        ++ maybe [] (\g -> ["        -- HOLE guard: " <> renderGuard g]) (tGuard t)
        ++ ["        -- HOLE write " <> r <> " := " <> renderGuard e | (r, e) <- tWrites t]
        ++ ["        -- HOLE emit " <> ev <> " (B.emit wire" <> ev <> " ...)" | ev <- tEmits t]
        ++ ["        B.goto " <> vertexCtor a (tGoto t)]

--------------------------------------------------------------------------------
-- Field categories and shared helpers
--------------------------------------------------------------------------------

data FieldCat = IdCat | EnumCat | OtherCat

fieldCat :: Agg -> Text -> FieldCat
fieldCat a ty
    | ty `elem` map idName (aIds a) = IdCat
    | ty `elem` map enumName (aEnums a) = EnumCat
    | otherwise = OtherCat

-- | The first constructor of a declared enum, used to build sample values.
firstEnumCtor :: Agg -> Text -> Maybe Text
firstEnumCtor a ty =
    case [c | e <- aEnums a, enumName e == ty, (c, _) <- take 1 (enumCtors e)] of
        (c : _) -> Just c
        [] -> Nothing

vertexCtor :: Agg -> Text -> Text
vertexCtor a s = aName a <> s

initialVertex :: Agg -> Text
initialVertex a = case aStates a of
    (s : _) -> vertexCtor a (stName s)
    [] -> aName a <> "Init"

generatedBanner :: Text
generatedBanner = "-- @generated by keiro-dsl; do not edit. Regenerated from the .keiro spec."

nodeOrigin :: Text -> Text -> Loc -> Text
nodeOrigin nodeKind nodeName loc =
    nodeKind <> " " <> nodeName <> case unLoc loc of
        0 -> ""
        line -> " (line " <> tshow' line <> ")"

{- | Conditions that the deterministic emitters cannot lower faithfully. The
pre-write scaffold pipeline treats each returned message as a refusal. The
list is extended alongside the policy and type lowering milestones.
-}
scaffoldRefusals :: Spec -> [Text]
scaffoldRefusals spec =
    concatMap aggregateRefusals aggregates
        <> concatMap contractRefusals contracts
        <> concatMap publisherRefusals publishers
  where
    aggregates = [aggregate | NAggregate aggregate <- specNodes spec]
    contracts = [contract | NContract contract <- specNodes spec]
    publishers = [publisher | NPublisher publisher <- specNodes spec]
    idTypes = map idName (specIds spec)
    enumTypes = map enumName (specEnums spec)
    enumCtorsFor ty = case [map fst (enumCtors enum) | enum <- specEnums spec, enumName enum == ty] of
        ctors : _ -> ctors
        [] -> []
    aggregateRefusals aggregate =
        [ "AggregateEmpty: aggregate '" <> aggName aggregate <> "' must declare at least one command, event, and transition"
        | null (aggCommands aggregate) || null (aggEvents aggregate) || null (aggTransitions aggregate)
        ]
            <> concatMap (registerRefusals aggregate) (aggRegs aggregate)
            <> [ "FieldTypeUnrepresentable: aggregate '" <> aggName aggregate <> "' field '" <> fieldName field <> "' has unsupported explicit type '" <> ty <> "'"
               | field <- aggregateFields aggregate
               , Just ty <- [fieldType field]
               , not (supportedType aggregate ty)
               ]
    registerRefusals aggregate reg =
        [ "RegTypeUnsupported: aggregate '" <> aggName aggregate <> "' register '" <> regName reg <> "' has unsupported type '" <> regType reg <> "'"
        | not (supportedType aggregate (regType reg))
        ]
            <> [ "RegTextInitialNotQuoted: aggregate '" <> aggName aggregate <> "' Text register '" <> regName reg <> "' must use a quoted initial"
               | regType reg == "Text"
               , RegInitBare _ <- [regInitial reg]
               ]
            <> [ "RegInitialNotEnumCtor: aggregate '" <> aggName aggregate <> "' register '" <> regName reg <> "' must start at a constructor of enum '" <> regType reg <> "'"
               | regType reg `elem` enumTypes
               , case regInitial reg of
                    RegInitBare value -> value `notElem` enumCtorsFor (regType reg)
                    RegInitText _ -> True
               ]
            <> [ "RegInitialInvalidLiteral: aggregate '" <> aggName aggregate <> "' Bool register '" <> regName reg <> "' must start at True or False"
               | regType reg == "Bool"
               , case regInitial reg of RegInitBare value -> value `notElem` ["True", "False"]; RegInitText _ -> True
               ]
            <> [ "RegInitialInvalidLiteral: aggregate '" <> aggName aggregate <> "' Int register '" <> regName reg <> "' must start at an integer literal"
               | regType reg == "Int"
               , case regInitial reg of RegInitBare value -> (readMaybe (T.unpack value) :: Maybe Int) == Nothing; RegInitText _ -> True
               ]
    aggregateFields aggregate =
        concatMap cmdFields (aggCommands aggregate)
            <> concat [fields | event <- aggEvents aggregate, EventFields fields <- [evBody event]]
    supportedType aggregate ty =
        ty `elem` (["Text", "Int", "Bool", aggName aggregate <> "Vertex"] <> idTypes <> enumTypes)
    contractRefusals contract =
        [ "ContractEmpty: contract '" <> ctrName contract <> "' must declare at least one event"
        | null (ctrEvents contract)
        ]
    publisherRefusals publisher =
        let backoff = pubBackoff publisher
            label message = message <> ": publisher '" <> pubName publisher <> "'"
         in case boKind backoff of
                "constant" -> []
                "exponential" -> case (boMax backoff, boMultiplier backoff) of
                    (Just maximumWindow, Just multiplierText) ->
                        case (windowSeconds (boWindow backoff), windowSeconds maximumWindow, readMaybe (T.unpack multiplierText) :: Maybe Double) of
                            (Right initialSeconds, Right maximumSeconds, Just multiplier)
                                | initialSeconds > 0 && maximumSeconds >= initialSeconds && multiplier >= 1 -> []
                            _ -> [label "BackoffInvalidExponential"]
                    _ -> [label "BackoffExponentialIncomplete"]
                other -> [label ("BackoffUnknownKind '" <> other <> "'")]

windowSeconds :: Text -> Either Text Int
windowSeconds window = case T.unsnoc window of
    Just (digits, unit)
        | not (T.null digits)
        , Just amount <- readMaybe (T.unpack digits) -> case unit of
            's' -> Right amount
            'm' -> Right (amount * 60)
            'h' -> Right (amount * 3600)
            _ -> Left invalid
    _ -> Left invalid
  where
    invalid = "invalid window '" <> window <> "' (expected digits followed by s, m, or h)"

windowText :: Text -> Text
windowText = either (const "0") tshow' . windowSeconds

-- | Render an Expr back to source-ish text for a hole annotation.
renderGuard :: Expr -> Text
renderGuard = go (0 :: Int)
  where
    go ctx e = parenIf (prec e < ctx) (body e)
    body (EOr l r) = go 1 l <> " || " <> go 2 r
    body (EAnd l r) = go 2 l <> " && " <> go 3 r
    body (ECmp op l r) = go 4 l <> " " <> cmp op <> " " <> go 4 r
    body (EAtom (AName n)) = n
    body (EAtom (ABool True)) = "true"
    body (EAtom (ABool False)) = "false"
    prec :: Expr -> Int
    prec EOr{} = 1
    prec EAnd{} = 2
    prec ECmp{} = 3
    prec EAtom{} = 4
    parenIf True s = "(" <> s <> ")"
    parenIf False s = s
    cmp OpEq = "=="
    cmp OpNeq = "!="
    cmp OpLt = "<"
    cmp OpLe = "<="
    cmp OpGt = ">"
    cmp OpGe = ">="

--------------------------------------------------------------------------------
-- Text helpers
--------------------------------------------------------------------------------

nl :: [Text] -> Text
nl = T.intercalate "\n"

-- | Join groups of declarations, blank-line-separated, dropping empties.
sectionsOf :: [[Text]] -> Text
sectionsOf = T.intercalate "\n\n" . filter (not . T.null) . map (T.intercalate "\n\n")

lowerFirst :: Text -> Text
lowerFirst t = case T.uncons t of
    Just (c, rest) -> T.cons (toLower c) rest
    Nothing -> t

{- | Assert the shared category proof at emission time as a belt-and-braces
guard for callers that bypass the CLI's normal validate-before-scaffold path.
-}
staticCategory :: Text -> Text -> Text
staticCategory owner value = case sagaCategoryError value of
    Nothing -> value
    Just reason -> error (T.unpack ("keiro-dsl scaffold: illegal " <> owner <> " category " <> tshow value <> " " <> reason))

pascal :: Text -> Text
pascal t = case T.uncons t of
    Just (c, rest) -> T.cons (toUpper c) rest
    Nothing -> t

pascalFromKebab :: Text -> Text
pascalFromKebab = T.concat . map pascal . T.splitOn "-"

kebabFromPascal :: Text -> Text
kebabFromPascal = T.intercalate "-" . map T.toLower . splitCamel

-- | Split CamelCase into its words (best-effort, for the projection name).
splitCamel :: Text -> [Text]
splitCamel = go . T.unpack
  where
    go [] = []
    go (c : cs) =
        let (rest, more) = break' cs
         in T.pack (c : rest) : go more
    break' [] = ([], [])
    break' (x : xs)
        | x `elem` ['A' .. 'Z'] = ([], x : xs)
        | otherwise = let (r, m) = break' xs in (x : r, m)

tshow :: Text -> Text
tshow t = T.pack (show t)

tshow' :: Int -> Text
tshow' = T.pack . show
