-- | The scaffold engine. Given an 'Aggregate' (and a 'Context' naming the
-- service and output module-namespace root), it emits deterministic
-- @-- \@generated@ modules plus create-if-absent Hole modules for the behavior
-- that remains explicitly hand-owned.
--
-- The load-bearing invariant of this module is the __firewall__: generated
-- aggregate @Transducer.hs@ owns transition terms, while an outcome-enabled
-- @EventStream.hs@ may evaluate its checked reason terms after exact-edge
-- selection. Hand-owned Hole modules remain the other intentional construction
-- boundary. A generated-text scan enforces these narrow exceptions.
--
-- Version-2 generated-owned transition bodies are rendered authoritatively in
-- that transducer. Explicit Hole-owned transitions keep only predicate/update
-- ownership; the generated command/event/target envelope remains authoritative.
-- Read-model SQL (the projection @apply@) is still a DB-coupled Hole delegated
-- to @codd@/the agent; the @Generated@ Projection module emits deterministic
-- @InlineProjection@ wiring and the pure event→status mapping. The decode emitted
-- here is /strict/ (every field required); lenient\/optional decode is EP-4's
-- concern.
module Keiro.Dsl.Scaffold
  ( ScaffoldModule (..),
    ModuleRole (..),
    moduleRole,
    ModuleKind (..),
    Context (..),
    Placement (..),
    defaultContext,
    genPrefixFor,
    contextGeneratedPrefix,
    holePrefixFor,
    generatedNominalModule,
    behaviorSourceMapModule,
    NominalUseSite (..),
    NominalGenerationOwner (..),
    planNominalGeneration,
    planNominalGenerationForService,
    generatedNominalsInTypes,
    generatedNominalTypeImports,
    generatedNominalTypeImportsForService,
    generatedIdSampleHaskell,
    scaffoldReplayAudit,
    scaffoldStructural,
    scaffoldStructuralForService,
    scaffoldStructuralOwners,
    scaffoldStructuralOwnersForService,
    codecComparisonModule,
    codecComparisonBanner,
    bindingSkeletonModules,
    bindingSkeletonOwners,
    scaffoldAggregateForService,
    scaffoldAggregate,
    obsoleteGeneratedOutputHooks,
    scaffoldProcess,
    scaffoldRouter,
    scaffoldRouterForService,
    scaffoldContract,
    scaffoldContractForService,
    scaffoldIntake,
    scaffoldPublisher,
    scaffoldWorkqueue,
    scaffoldWorkqueueForService,
    scaffoldReadModel,
    scaffoldReadModelForService,
    scaffoldProjectionCatalog,
    scaffoldRefusals,
    windowSeconds,

    -- * Firewall self-check (M3)
    FirewallSurface (..),
    firewallSurface,
    firewallBreaches,

    -- * Internal resolution, shared with "Keiro.Dsl.Harness"
    Agg (..),
    ResolvedDomainOutcomeTypes (..),
    aggregateCheckedService,
    ResolvedRegister (..),
    ResolvedCtor (..),
    StructuralProjection (..),
    resolveAggForService,
    resolveAgg,
    nominalEqualityUsedInGeneratedExpressions,
    projectionSpecs,
    resolveProjectionModules,
    nominalProjectionModule,
    codecMappedDeclarations,
    FieldCat (..),
    fieldCat,
    vertexCtor,
    initialVertex,
    firstEnumCtor,
    lowerFirst,
    pascal,
    pascalFromKebab,
    generatedBanner,
    generatedBannerFor,
    isGeneratedBannerLine,
    stampGeneratedModule,
    stampGeneratedModules,
  )
where

import Data.Char (isAlpha, isAlphaNum, isDigit, isUpper)
import Data.List (find, groupBy, isSuffixOf, nub, sort, sortOn)
import Data.List.NonEmpty (NonEmpty)
import Data.List.NonEmpty qualified as NE
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe, isJust, isNothing, mapMaybe, maybeToList)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Version (showVersion)
import Keiro.Dsl.AggregateGenerationPlan
import Keiro.Dsl.AggregateType
import Keiro.Dsl.BehaviorCoverage qualified as Behavior
import Keiro.Dsl.BehaviorSourceMap qualified as BehaviorSource
import Keiro.Dsl.CodecCompare (BranchArm (..), BranchField (..), BranchSchema (..))
import Keiro.Dsl.ConsumerTypePlan
import Keiro.Dsl.EventOutput
import Keiro.Dsl.ExplainBindings (BindingObligation (..), BindingObligationKind (..), bindingObligations)
import Keiro.Dsl.Expression
import Keiro.Dsl.FieldIdentity
import Keiro.Dsl.FoldFingerprint (aggregateFoldFingerprintForService, renderFoldSurfaceError)
import Keiro.Dsl.GeneratedHaskellLanguage
import Keiro.Dsl.Grammar
import Keiro.Dsl.HaskellImport
import Keiro.Dsl.HaskellName qualified as HaskellName
import Keiro.Dsl.IdDomain (IdDomainContract, contractIdDomainContractFor, idDomainContractFor, idDomainPrefix, idDomainSampleText)
import Keiro.Dsl.LanguageVersion (SourceLanguage (LegacyUnversioned), languageVersionText)
import Keiro.Dsl.MappedCodecPlan
import Keiro.Dsl.NominalType
import Keiro.Dsl.PrettyPrint (renderExpr)
import Keiro.Dsl.ProjectionMappedImpact (projectionAggregateSourceFingerprint)
import Keiro.Dsl.ReadModelShape (fnv1a64, registryNameFor, subscriptionNameFor)
import Keiro.Dsl.RouterSelection
import Keiro.Dsl.SemanticContract (CheckedService (..), EffectiveLanguageContract, effectiveContractLanguageVersion, effectiveLanguageContract, legacyCheckedService)
import Keiro.Dsl.SourceIndex qualified as SourceIndex
import Keiro.Dsl.TypeGraph
import Keiro.Dsl.Validate (sagaCategoryError)
import Paths_keiro_dsl qualified as Package
import Text.Read (readMaybe)

-- | One emitted module: its on-disk path (relative to the scaffold @--out@
-- directory), its full text, and whether it is overwritten every run
-- ('Generated') or written only when absent ('HoleStub').
data ScaffoldModule = ScaffoldModule
  { modulePath :: !FilePath,
    moduleText :: !Text,
    kind :: !ModuleKind,
    origin :: !Text
  }
  deriving stock (Eq, Show)

-- | Stable semantic identity for a generated artifact.  It is deliberately
-- independent of the cased module path: source-name migrations pair artifacts
-- by this role, then compare their old and current paths.
data ModuleRole = ModuleRole
  { roleOwnerKind :: !Text,
    roleOwnerName :: !Text,
    roleFamily :: !Text
  }
  deriving stock (Eq, Ord, Show)

moduleRole :: ScaffoldModule -> ModuleRole
moduleRole scaffoldModule =
  ModuleRole
    { roleOwnerKind = headOr "module" originWords,
      roleOwnerName = origin scaffoldModule,
      roleFamily = case reverse (T.splitOn "." moduleName) of
        family : _ -> family
        [] -> moduleName
    }
  where
    originWords = T.words (origin scaffoldModule)
    moduleName = T.replace "/" "." (T.dropEnd 3 (T.pack (modulePath scaffoldModule)))
    headOr fallback = \case
      value : _ -> value
      [] -> fallback

data ModuleKind
  = -- | @-- \@generated@; overwritten on every scaffold.
    Generated
  | -- | Hand-owned; created only when absent, never overwritten.
    HoleStub
  deriving stock (Eq, Show)

-- | The threading context: the spec's @context@ name, the chosen output
-- module-namespace root, and the placement style. Extended additively (never
-- re-shaped) by later verticals.
data Context = Context
  { contextName :: !Text,
    -- | @""@ means no namespace prefix (the historical default).
    moduleRoot :: !Text,
    -- | 'GeneratedPrefix' is the historical default.
    placement :: !Placement
  }
  deriving stock (Eq, Show)

-- | One aggregate-level reason a generated nominal declaration must be visible.
-- The declaration itself is context-owned; these use sites determine the
-- aggregate modules that import it.
data NominalUseSite = NominalUseSite
  { nominalUseAggregate :: !Name,
    nominalUseKind :: !AggregateUseSite
  }
  deriving stock (Eq, Ord, Show)

-- | The checked generation owner for one unbound ID or enum. Every owner in a
-- service points at the same context-level module, while retaining its source
-- location through 'ResolvedNominalType' and all aggregate use sites explicitly.
data NominalGenerationOwner = NominalGenerationOwner
  { nominalDeclaration :: !ResolvedNominalType,
    nominalModule :: !Text,
    nominalUseSites :: !(Set.Set NominalUseSite),
    nominalEqualityUsed :: !Bool
  }
  deriving stock (Eq, Show)

-- | A context with today's default placement ('GeneratedPrefix', no root prefix)
-- for the given @context@ name. Callers that do not care about placement (the
-- @parse@ path, tests) build their context with this.
defaultContext :: Text -> Context
defaultContext name = Context {contextName = name, moduleRoot = "", placement = GeneratedPrefix}

-- | The generated-layer namespace for a node, honouring the root prefix and the
-- placement style. The 'Text' argument is the already-pascalised node name (e.g.
-- @Reservation@, @HospitalSurge@). For 'GeneratedPrefix' this is
-- @\<root\>.Generated.\<Ctx\>.\<Node\>@ (identical to the historical layout); for
-- 'CollocatedLeaf' it is @\<root\>.\<Ctx\>.\<Node\>.Generated@.
genPrefixFor :: Context -> Text -> Text
genPrefixFor ctx node = case placement ctx of
  GeneratedPrefix -> rootPrefix ctx <> "Generated." <> ctxPascalOf ctx <> "." <> node
  CollocatedLeaf -> rootPrefix ctx <> ctxPascalOf ctx <> "." <> node <> ".Generated"

-- | The generated-layer namespace shared by modules emitted once for a whole
-- service context, such as Nominals, ReplayAudit, and Conformance.
contextGeneratedPrefix :: Context -> Text
contextGeneratedPrefix ctx = case placement ctx of
  GeneratedPrefix -> rootPrefix ctx <> "Generated." <> ctxPascalOf ctx
  CollocatedLeaf -> rootPrefix ctx <> ctxPascalOf ctx <> ".Generated"

-- | The hand-owned (hole) namespace for a node: @\<root\>.\<Ctx\>.\<Node\>@ —
-- the same for both placement styles (holes always sit beside the domain).
holePrefixFor :: Context -> Text -> Text
holePrefixFor ctx node = rootPrefix ctx <> ctxPascalOf ctx <> "." <> node

-- | The one context-level Haskell owner for generated IDs and enums.
generatedNominalModule :: Context -> Text
generatedNominalModule ctx = contextGeneratedPrefix ctx <> ".Nominals"

-- | Emit the one context-owned table that contains every current behavior
-- source position. Services without behavior requirements emit no table and,
-- consequently, no aggregate behavior contract imports one.
behaviorSourceMapModule :: Context -> [BehaviorSource.BehaviorSourceEntry] -> Maybe ScaffoldModule
behaviorSourceMapModule _ [] = Nothing
behaviorSourceMapModule ctx entries =
  Just
    ScaffoldModule
      { modulePath = T.unpack (T.replace "." "/" moduleName <> ".hs"),
        moduleText =
          nl
            ( renderGeneratedLanguagePragmas []
                <> [ generatedBanner,
                     "module " <> moduleName,
                     "  ( BehaviorSourceLocation (..)",
                     "  , behaviorSourceLocation",
                     "  , renderBehaviorSourceLocation",
                     "  ) where",
                     "",
                     "import Data.Text (Text)",
                     "import Data.Text qualified as T",
                     "",
                     "data BehaviorSourceLocation = BehaviorSourceLocation",
                     "  { sourceFile :: !FilePath",
                     "  , sourceLine :: !Int",
                     "  , sourceColumn :: !Int",
                     "  }",
                     "  deriving stock (Eq, Ord, Show)",
                     "",
                     "behaviorSourceLocation :: Text -> Maybe BehaviorSourceLocation",
                     "behaviorSourceLocation key = case key of"
                   ]
                <> [ "  "
                       <> tshow (Behavior.unBehaviorKey (BehaviorSource.behaviorSourceKey entry))
                       <> " -> Just (BehaviorSourceLocation "
                       <> tshow (T.pack (BehaviorSource.behaviorSourceFile entry))
                       <> " "
                       <> tshow' (BehaviorSource.behaviorSourceLine entry)
                       <> " "
                       <> tshow' (BehaviorSource.behaviorSourceColumn entry)
                       <> ")"
                   | entry <- sortOn BehaviorSource.behaviorSourceKey entries
                   ]
                <> [ "  _ -> Nothing",
                     "",
                     "renderBehaviorSourceLocation :: Text -> Text",
                     "renderBehaviorSourceLocation key = case behaviorSourceLocation key of",
                     "  Just location -> T.pack (sourceFile location) <> \":\" <> tshow (sourceLine location) <> \":\" <> tshow (sourceColumn location)",
                     "  Nothing -> \"<internal invariant: missing behavior source for \" <> key <> \">\"",
                     "",
                     "tshow :: Show value => value -> Text",
                     "tshow = T.pack . show"
                   ]
            ),
        kind = Generated,
        origin = "context " <> contextName ctx <> " behavior source map"
      }
  where
    moduleName = contextGeneratedPrefix ctx <> ".BehaviorSourceMap"

-- | The root namespace prefix, dot-terminated, or @""@ when no root is set.
rootPrefix :: Context -> Text
rootPrefix ctx = case moduleRoot ctx of r | T.null r -> ""; r -> r <> "."

-- | The context name in PascalCase, e.g. @hospital-capacity@ -> @HospitalCapacity@.
ctxPascalOf :: Context -> Text
ctxPascalOf = pascalFromKebab . contextName

--------------------------------------------------------------------------------
-- Firewall self-check (M3)
--------------------------------------------------------------------------------

-- | The canonical keiki surface forbidden in generated modules. Symbolic
-- operators are matched as maximal Haskell symbol tokens, identifiers as complete
-- tokens, qualifiers by their leading module alias, and imports structurally.
data FirewallSurface = FirewallSurface
  { forbiddenSymbolic :: ![Text],
    forbiddenIdents :: ![Text],
    forbiddenQualifiers :: ![Text],
    forbiddenImports :: ![Text],
    restrictedImports :: ![(Text, [Text])]
  }
  deriving stock (Eq, Show)

firewallSurface :: FirewallSurface
firewallSurface =
  FirewallSurface
    { forbiddenSymbolic = [".==", "./=", ".<", ".<=", ".>", ".>=", ".&&", ".||", ".+", ".-", ".*", "=:", "*:"],
      forbiddenIdents = ["lit", "pnot", "tadd", "tsub", "tmul"],
      forbiddenQualifiers = ["B"],
      forbiddenImports = ["Keiki.Builder", "Keiki.Operators", "Keiki.Symbolic"],
      -- Generated aggregate modules use the first two names; generated
      -- harnesses validate, step, and replay filled holes register by register.
      restrictedImports =
        [ ( "Keiki.Core",
            [ "RegFile",
              "HsPred",
              "FieldProjection",
              "ExactFieldProjection",
              "FieldWitness",
              "fieldWitness",
              "exactFieldWitness",
              "fieldWitnessGet",
              "fieldWitnessAgrees",
              "applyEventsEither",
              "defaultValidationOptions",
              "step",
              "validateTransducer",
              "EdgeMode",
              "EdgeRef",
              "StepSuccess",
              "StepFailure",
              "ReplayEventSpan",
              "ReplayAttribution",
              "ReplaySuccess",
              "applyEventsDetailedEither",
              "stepDetailedEither",
              "!"
            ]
          )
        ]
    }

-- | Scan generated modules for firewall breaches, returning every offending
-- @(module path, token, 1-based line number)@. Only modules whose 'kind' is
-- 'Generated' are scanned. Strings and comments are skipped, symbol runs use
-- maximal munch, and keiki imports are checked independently of token spelling.
firewallBreaches :: [ScaffoldModule] -> [(FilePath, Text, Int)]
firewallBreaches mods =
  [ (modulePath m, breach, n)
  | m <- mods,
    kind m == Generated,
    not (authoritativeScalarModule m),
    (n, line) <- zip [1 ..] (T.lines (moduleText m)),
    breach <- lineBreaches line
  ]

-- The version-2 aggregate transducer and an outcome-enabled aggregate event
-- stream are the narrow, intentional exceptions to the generated
-- symbolic-operator firewall. The former owns transition terms; the latter
-- evaluates a checked reason term only after Keiki has selected an exact edge.
-- Ordinary event-stream modules remain scanned.
authoritativeScalarModule :: ScaffoldModule -> Bool
authoritativeScalarModule scaffoldModule =
  "/Transducer.hs" `isSuffixOf` path
    || ( "/EventStream.hs" `isSuffixOf` path
           && "DomainCommandHandler" `T.isInfixOf` moduleText scaffoldModule
       )
  where
    path = modulePath scaffoldModule

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
    | Just allowed <- lookup imported (restrictedImports firewallSurface),
      not (hasAllowedExplicitImportList allowed line) ->
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
  { aContext :: !Context,
    aLanguageContract :: !EffectiveLanguageContract,
    aSpec :: !Spec,
    aAggregate :: !Aggregate,
    aCtxPascal :: !Text,
    aName :: !Text,
    aLoc :: !Loc,
    aVertexType :: !Text,
    aIds :: ![IdDecl],
    aEnums :: ![EnumDecl],
    aRegs :: ![ResolvedRegister],
    aStates :: ![StateDecl],
    aCommands :: ![ResolvedCtor],
    aEvents :: ![ResolvedCtor],
    aDomainOutcomeTypes :: !(Maybe ResolvedDomainOutcomeTypes),
    -- | Generated IDs and enums used by this aggregate, in stable name order.
    aGeneratedNominals :: ![ResolvedNominalType],
    aTransitions :: ![Transition],
    aOutputMappings :: !(Map.Map (Int, Int) EventOutputMapping),
    aWire :: !WireSpec,
    aProjection :: !(Maybe ProjectionSpec),
    aSnapshot :: !(Maybe SnapshotSpec),
    aFoldFingerprint :: !Text,
    aReadModels :: ![ReadModelNode],
    aTypeGraph :: !(Maybe TypeGraph),
    aSymbols :: !AggregateSymbols,
    -- | e.g. @Generated.HospitalCapacity.Reservation@
    aGenPrefix :: !Text,
    -- | e.g. @HospitalCapacity.Reservation@
    aHolePrefix :: !Text
  }

data ResolvedDomainOutcomeTypes = ResolvedDomainOutcomeTypes
  { resolvedRejectionType :: !ResolvedAggregateType,
    resolvedNoOpType :: !ResolvedAggregateType
  }
  deriving stock (Eq, Show)

aggregateCheckedService :: Agg -> CheckedService
aggregateCheckedService aggregate =
  CheckedService
    { checkedLanguageContract = aLanguageContract aggregate,
      checkedSpec = aSpec aggregate
    }

data ResolvedRegister = ResolvedRegister
  { rrName :: !Name,
    rrType :: !ResolvedAggregateType,
    rrInitial :: !ResolvedRegisterInitial,
    rrLoc :: !Loc
  }
  deriving stock (Eq, Show)

-- | A command or event constructor with its fully-resolved field identities and
-- aggregate types.
data ResolvedCtor = ResolvedCtor
  { rcName :: !Text,
    -- | (DSL/selector/wire identity, canonical aggregate type)
    rcFields :: ![(ResolvedFieldIdentity, ResolvedAggregateType)],
    -- | EP-2: schema version (1 for commands and unversioned events).
    rcVersion :: !Int,
    -- | EP-2: the source version this event migrates from (the upcaster step).
    rcUpcastFrom :: !(Maybe Int)
  }

defaultWire :: WireSpec
defaultWire = WireSpec {wireKind = "ctorName", wireFields = "camelCase", wireSchemaVersion = 1}

resolveAgg :: Context -> Spec -> Aggregate -> Agg
resolveAgg ctx spec = resolveAggForService ctx (legacyCheckedService spec)

-- | Resolve one aggregate under the service's effective runtime semantics.
resolveAggForService :: Context -> CheckedService -> Aggregate -> Agg
resolveAggForService ctx service agg =
  Agg
    { aContext = ctx,
      aLanguageContract = checkedLanguageContract service,
      aSpec = spec,
      aAggregate = agg,
      aCtxPascal = ctxPascal,
      aName = nm,
      aLoc = aggLoc agg,
      aVertexType = vertexType,
      aIds = specIds spec,
      aEnums = specEnums spec,
      aRegs = map resolveRegister (aggRegs agg),
      aStates = aggStates agg,
      aCommands = map resolveCommand (aggCommands agg),
      aEvents = map resolveEvent (aggEvents agg),
      aDomainOutcomeTypes = resolvedDomainOutcomeTypes,
      aGeneratedNominals = generatedNominalsInTypes aggregateResolvedTypes,
      aTransitions = aggTransitions agg,
      aOutputMappings =
        Map.fromList
          [ ( (transitionIndex, emitIndex),
              orDieOutput (eventOutputMapping spec agg transition emitIndex eventName)
            )
          | (transitionIndex, transition) <- zip [1 ..] (aggTransitions agg),
            (emitIndex, eventName) <- zip [1 ..] (tEmits transition)
          ],
      aWire = fromMaybe defaultWire (aggWire agg),
      aProjection = aggProjection agg,
      aSnapshot = aggSnapshot agg,
      aFoldFingerprint = either (error . T.unpack . renderFoldSurfaceError) id (aggregateFoldFingerprintForService service agg),
      aReadModels = [readModel | NReadModel readModel <- specNodes spec],
      aTypeGraph = either (const Nothing) Just (resolveTypeGraph spec),
      aSymbols = symbols,
      aGenPrefix = genPrefixFor ctx nm,
      aHolePrefix = holePrefixFor ctx nm
    }
  where
    spec = checkedSpec service
    nm = aggName agg
    symbols = aggregateSymbols spec
    ctxPascal = pascalFromKebab (contextName ctx)
    vertexType = nm <> "Vertex"
    commandFieldTypes = [(cmdName c, cmdFields c) | c <- aggCommands agg]
    resolveCommand c = (mkCtor CommandFieldUse (cmdName c) (cmdFields c)) {rcVersion = 1, rcUpcastFrom = Nothing}
    resolveEvent e =
      (mkCtor EventFieldUse (evName e) (eventFields e))
        { rcVersion = evVersion e,
          rcUpcastFrom = fst <$> evUpcastFrom e
        }
      where
        eventFields ev = case evBody ev of
          EventFields fs -> fs
          EventFromCommand cn -> fromMaybe [] (lookup cn commandFieldTypes)
    mkCtor useSite cn fs =
      ResolvedCtor
        { rcName = cn,
          rcFields = map (\field -> (resolveAggregateFieldIdentity field, orDie (inferAggregateFieldType symbols agg useSite field))) fs,
          rcVersion = 1,
          rcUpcastFrom = Nothing
        }
    aggregateResolvedTypes =
      map rrType (map resolveRegister (aggRegs agg))
        <> map snd (concatMap rcFields (map resolveCommand (aggCommands agg)))
        <> map snd (concatMap rcFields (map resolveEvent (aggEvents agg)))
    resolvedDomainOutcomeTypes = case aggDomainOutcomeTypes agg of
      Nothing -> Nothing
      Just declaration ->
        Just
          ResolvedDomainOutcomeTypes
            { resolvedRejectionType = resolveOutcomeType declaration (rejectionType declaration),
              resolvedNoOpType = resolveOutcomeType declaration (noOpType declaration)
            }
    resolveOutcomeType declaration name =
      orDie (resolveAggregateType symbols (outcomeTypesLoc declaration) HaskellLoweringUse (TRef name))
    resolveRegister register =
      let resolvedType = orDie (resolveAggregateType symbols (regLoc register) RegisterUse (regType register))
          resolvedInitial = orDie (resolveRegisterInitial symbols (regLoc register) resolvedType (regInitial register))
       in ResolvedRegister
            { rrName = regName register,
              rrType = resolvedType,
              rrInitial = resolvedInitial,
              rrLoc = regLoc register
            }
    orDie = either (error . ("validated aggregate resolution failed: " <>) . show) id
    orDieOutput = either (error . ("validated aggregate output resolution failed: " <>) . show) id

-- | Keep only generated nominal IDs/enums from a resolved aggregate type list.
-- The map both deduplicates and makes declaration/import order independent of
-- member and field order.
generatedNominalsInTypes :: [ResolvedAggregateType] -> [ResolvedNominalType]
generatedNominalsInTypes resolvedTypes =
  Map.elems . Map.fromList $
    [ (resolvedNominalName nominal, nominal)
    | AggregateNominal nominal <- resolvedTypes,
      GeneratedNominal <- [resolvedNominalOwnership nominal]
    ]

-- | Plan declaration ownership and use closure without emitting text. Parsing
-- and validation already reject malformed declarations; retaining the checked
-- error here keeps this function total for direct library callers.
planNominalGeneration :: Context -> Spec -> Either (NonEmpty NominalTypeError) [NominalGenerationOwner]
planNominalGeneration ctx spec = planNominalGenerationForService ctx (legacyCheckedService spec)

planNominalGenerationForService :: Context -> CheckedService -> Either (NonEmpty NominalTypeError) [NominalGenerationOwner]
planNominalGenerationForService ctx service = do
  registry <- resolveNominalTypes spec
  let aggregates = [resolveAggForService ctx service aggregate | NAggregate aggregate <- specNodes spec]
      generated =
        [ nominal
        | nominal <- Map.elems (nominalTypes registry),
          GeneratedNominal <- [resolvedNominalOwnership nominal]
        ]
  pure
    [ NominalGenerationOwner
        { nominalDeclaration = nominal,
          nominalModule = generatedNominalModule ctx,
          nominalUseSites = Set.fromList (concatMap (usesFor nominal) aggregates),
          nominalEqualityUsed = any (nominalEqualityUsedInGeneratedExpressions nominal) aggregates
        }
    | nominal <- generated
    ]
  where
    spec = checkedSpec service
    usesFor nominal aggregate =
      [ NominalUseSite (aName aggregate) useKind
      | useKind <- aggregateUseKinds nominal aggregate
      ]

nominalEqualityUsedInGeneratedExpressions :: ResolvedNominalType -> Agg -> Bool
nominalEqualityUsedInGeneratedExpressions nominal aggregate =
  any
    (anyTypedExpression comparesNominal)
    (resolvedGeneratedExpressions aggregate <> resolvedOutcomeExpressions aggregate)
  where
    comparesNominal expression = case typedScalarNode expression of
      TypedEqual left _ -> typedScalarType left == AggregateNominal nominal
      TypedNotEqual left _ -> typedScalarType left == AggregateNominal nominal
      _ -> False

aggregateUseKinds :: ResolvedNominalType -> Agg -> [AggregateUseSite]
aggregateUseKinds nominal aggregate =
  nub $
    [RegisterUse | nominal `elem` registerNominals]
      <> [CommandFieldUse | nominal `elem` commandNominals]
      <> [EventFieldUse | nominal `elem` eventNominals]
      <> [CodecUse | nominal `elem` eventNominals]
      <> [SnapshotUse | hasSnapshot aggregate && nominal `elem` registerNominals]
      <> [HarnessSampleUse | nominal `elem` commandNominals || nominal `elem` eventNominals]
      <> [HaskellLoweringUse | nominal `elem` (aGeneratedNominals aggregate <> outcomeNominals)]
  where
    registerNominals = generatedNominalsInTypes (map rrType (aRegs aggregate))
    commandNominals = generatedNominalsInTypes (map snd (concatMap rcFields (aCommands aggregate)))
    eventNominals = generatedNominalsInTypes (map snd (concatMap rcFields (aEvents aggregate)))
    outcomeNominals =
      generatedNominalsInTypes
        [ resolvedType
        | outcomeTypes <- maybeToList (aDomainOutcomeTypes aggregate),
          resolvedType <- [resolvedRejectionType outcomeTypes, resolvedNoOpType outcomeTypes]
        ]

--------------------------------------------------------------------------------
-- Entry point
--------------------------------------------------------------------------------

-- | Emit the context-level private structural stratum. Shape modules contain
-- only generated wire representations. The projection facade contains only
-- schema-derived Keiki field witnesses; neither layer owns consumer behavior.
scaffoldStructural :: Context -> Spec -> [ScaffoldModule]
scaffoldStructural ctx spec = scaffoldStructuralForService ctx (legacyCheckedService spec)

scaffoldStructuralForService :: Context -> CheckedService -> [ScaffoldModule]
scaffoldStructuralForService ctx service = map fst (scaffoldStructuralOwnersForService ctx service)

-- | 'scaffoldStructural' paired with the mapped declarations each module was
-- emitted for. A shape module names exactly one declaration; a binding skeleton
-- names every declaration whose obligations it carries (several declarations may
-- share one leaf binding module); the projection facade names __none__, because it
-- is emitted once for the whole context from the complete resolved graph.
--
-- This is the attribution seam whole-workspace scaffolding needs: a workspace
-- emits from one merged spec, and this list says which declaration — and therefore
-- which member file — produced each structural module, without parsing the
-- human-readable 'origin' string.
scaffoldStructuralOwners :: Context -> Spec -> [(ScaffoldModule, [Name])]
scaffoldStructuralOwners ctx spec = scaffoldStructuralOwnersForService ctx (legacyCheckedService spec)

scaffoldStructuralOwnersForService :: Context -> CheckedService -> [(ScaffoldModule, [Name])]
scaffoldStructuralOwnersForService ctx service = case resolveTypeGraph (checkedSpec service) of
  Left _ -> []
  Right graph ->
    [(shapeModule ctx graph entry, [sdName (fst entry)]) | entry <- structural]
      <> projectionModules
      <> generatedNominalOwners ctx service
      <> nominalRepresentationOwners ctx spec
      <> nominalProjectionOwners ctx service
      <> bindingSkeletonOwners ctx spec graph
    where
      structural =
        [ (declaration, shape)
        | ResolvedStructural declaration shape <- Map.elems (tgDeclarations graph)
        ]
      projectionModules =
        [ ( ScaffoldModule
              { modulePath = T.unpack (T.replace "." "/" (structuralProjectionModule ctx) <> ".hs"),
                moduleText = emitStructuralProjections ctx graph,
                kind = Generated,
                origin = "context " <> specContext spec <> " mapped structural facade"
              },
            []
          )
        | not (null (projectionSpecs graph))
        ]
      spec = checkedSpec service

-- | Plan one opt-in, non-production historical-codec comparison module.
--
-- The module is intentionally absent from 'scaffoldStructural' and therefore
-- from production manifests and scaffold records. It must be requested by name
-- and is compiled only by consumer-owned test/tool components.
codecComparisonModule :: Context -> Spec -> Name -> Either Text ScaffoldModule
codecComparisonModule ctx spec requestedName = do
  graph <- either (Left . ("mapped type graph did not resolve: " <>) . T.pack . show) Right (resolveTypeGraph spec)
  (declaration, shape) <- case Map.lookup (MappedKey requestedName) (tgDeclarations graph) of
    Nothing -> Left ("codec comparison target is not a mapped declaration: " <> requestedName)
    Just (ResolvedOpaque _) ->
      Left
        ( "codec comparison target "
            <> requestedName
            <> " is opaque; finite evidence must never upgrade an opaque declaration to a structural claim"
        )
    Just (ResolvedStructural declaration shape) -> Right (declaration, shape)
  owner <- case sortOn aggName (comparisonOwners declaration) of
    [] ->
      Left
        ( "codec comparison target "
            <> requestedName
            <> " is not reachable from a persisted private event payload"
        )
    aggregate : _ -> Right aggregate
  let moduleName = structuralPrefix ctx <> ".CodecCompare." <> requestedName
  pure
    ScaffoldModule
      { modulePath = T.unpack (T.replace "." "/" moduleName <> ".hs"),
        moduleText = emitCodecComparison ctx moduleName graph declaration shape owner,
        kind = Generated,
        origin = "non-production codec comparison " <> requestedName
      }
  where
    comparisonOwners declaration =
      [ aggregate
      | NAggregate aggregate <- specNodes spec,
        let resolved = resolveAgg ctx spec aggregate,
        any ((== sdName declaration) . mappedName) (codecMappedDeclarations resolved)
      ]
      where
        mappedName (ResolvedStructural structural _) = sdName structural
        mappedName (ResolvedOpaque opaque) = odName opaque

codecComparisonBanner :: Text
codecComparisonBanner =
  "-- @generated by keiro-dsl codec comparison; non-production migration evidence; do not edit."

emitCodecComparison :: Context -> Text -> TypeGraph -> StructuralDecl -> ResolvedMappedShape -> Aggregate -> Text
emitCodecComparison ctx moduleName graph declaration shape owner =
  nl
    [ "",
      codecComparisonBanner,
      "-- This module compares historical and generated codecs in consumer-owned tests only.",
      "-- It is never a runtime fallback and never changes the generated codec's authority.",
      "module " <> moduleName <> " (compareWithHistorical) where",
      "",
      "import Control.Monad (filterM)",
      "import Data.Aeson (Value)",
      "import Data.Aeson qualified as Aeson",
      "import Data.List (sort)",
      "import Data.List.NonEmpty qualified as NonEmpty",
      "import Data.Text (Text)",
      "import Data.Text qualified",
      "import " <> codecModule <> " qualified as GeneratedCodec",
      "import Keiro.Codec.Structural (FixtureCases (..))",
      "import Keiro.Dsl.CodecCompare",
      "import Keiro.Dsl.TypeGraph (BindingVersion (..), CanonicalTypeId (..), QualifiedValueName (..))",
      "import System.Directory (doesFileExist, listDirectory)",
      "import System.FilePath (takeExtension, (</>))",
      renderPlannedImports importPlan,
      "",
      "compareWithHistorical :: HistoricalCodec " <> domainType <> " -> FilePath -> IO CompareReport",
      "compareWithHistorical historicalCodec goldenDirectory = do",
      "  names <- sort . filter ((== \".json\") . takeExtension) <$> listDirectory goldenDirectory",
      "  files <- filterM doesFileExist [goldenDirectory </> name | name <- names]",
      "  loaded <- traverse (loadGolden historicalCodec) files",
      "  let inputIssues = [issue | Left issue <- loaded]",
      "      entries = [entry | Right entry <- loaded]",
      "      typedCases = NonEmpty.toList (fixtureCases " <> fixtureReference <> ")",
      "      encodeObservations =",
      "        [ EncodeObservation label (hcEncode historicalCodec value) (GeneratedCodec.encode" <> name <> "Mapped value)",
      "        | (label, value) <- typedCases",
      "        ]",
      "      decodeObservations = [observation | (observation, _) <- entries]",
      "      typedObserved =",
      "        concat",
      "          [ observedBranchesFor FromBinding branchSchema (GeneratedCodec.encode" <> name <> "Mapped value)",
      "          | (_, value) <- typedCases",
      "          ]",
      "      historicalObserved =",
      "        concat [observedBranchesFor HistoricalGolden branchSchema value | (_, values) <- entries, value <- values]",
      "      declared = declaredBranchesFor FromBinding branchSchema <> declaredBranchesFor HistoricalGolden branchSchema",
      "      provenance =",
      "        CompareProvenance",
      "          { cpHistoricalCodecIdentity = hcIdentity historicalCodec",
      "          , cpHistoricalCodecVersion = hcVersion historicalCodec",
      "          , cpCanonicalType = CanonicalTypeId " <> tshow (unCanonicalTypeId (sdCanonical declaration)),
      "          , cpBindingSymbol = QualifiedValueName " <> tshow (unQualifiedValueName (sdBinding declaration)),
      "          , cpBindingVersion = BindingVersion " <> tshow (unBindingVersion (sdBindingVersion declaration)),
      "          , cpWireFingerprint = " <> tshow (wireFingerprint graph name),
      "          }",
      "  pure (compareReport provenance inputIssues (encodeObservations <> decodeObservations) declared (typedObserved <> historicalObserved))",
      "",
      "loadGolden :: HistoricalCodec " <> domainType <> " -> FilePath -> IO (Either CompareInputIssue (CompareObservation, [Value]))",
      "loadGolden historicalCodec path = do",
      "  decoded <- Aeson.eitherDecodeFileStrict path",
      "  pure $ case decoded of",
      "    Left reason -> Left (HistoricalGoldenUnreadable path (fromString reason))",
      "    Right inputValue ->",
      "      let historicalDecoded = hcDecode historicalCodec inputValue",
      "          historicalOutcome = normalizeDecode historicalDecoded",
      "          generatedOutcome = normalizeDecode (GeneratedCodec.decode" <> name <> "Mapped inputValue)",
      "          observation = DecodeObservation path inputValue historicalOutcome generatedOutcome",
      "          coveredValues = case historicalDecoded of",
      "            Right value -> [inputValue, GeneratedCodec.encode" <> name <> "Mapped value]",
      "            Left _ -> []",
      "       in Right (observation, coveredValues)",
      "",
      "normalizeDecode :: Either Text " <> domainType <> " -> DecodeOutcome",
      "normalizeDecode = either DecodeFailed (DecodedShape . GeneratedCodec.encode" <> name <> "Mapped)",
      "",
      "fromString :: String -> Text",
      "fromString = Data.Text.pack",
      "",
      "branchSchema :: BranchSchema",
      "branchSchema = " <> renderBranchSchema (branchSchemaFor graph (ResolvedStructural declaration shape))
    ]
  where
    name = sdName declaration
    domainType = renderReferenceOrDie importPlan (haskellTypeReference (sdHaskell declaration))
    codecModule = genPrefixFor ctx (aggName owner) <> ".Codec"
    fixtureReference = renderReferenceOrDie importPlan (qualifiedValueReference (sdFixtures declaration))
    importPlan =
      planImportsOrDie
        moduleName
        Set.empty
        ( Set.fromList
            [ haskellTypeReference (sdHaskell declaration),
              qualifiedValueReference (sdFixtures declaration)
            ]
        )

branchSchemaFor :: TypeGraph -> ResolvedMappedDecl -> BranchSchema
branchSchemaFor graph =
  foldMappedDecl
    MappedDeclAlgebra
      { onStructuralDecl = \_ shape ->
          foldMappedShape
            MappedShapeAlgebra
              { onRecord = \_ _ fields ->
                  BranchRecord
                    [ BranchField
                        (rwfKey field)
                        (rwfPresence field == POptional)
                        (branchExpr graph (rwfType field))
                    | field <- fields
                    ],
                onEnum = const BranchScalar,
                onUnion = \encoding arms ->
                  BranchUnion
                    (ueTagField encoding)
                    (ueContentsField encoding)
                    [BranchArm (rwaTag arm) (branchExpr graph <$> rwaPayload arm) | arm <- arms]
              }
            shape,
        onOpaqueDecl = const BranchScalar
      }

branchExpr :: TypeGraph -> ResolvedTypeExpr -> BranchSchema
branchExpr graph =
  foldTypeExpr
    TypeExprAlgebra
      { onText = BranchScalar,
        onInt = BranchScalar,
        onInteger = BranchScalar,
        onBool = BranchScalar,
        onNatural = BranchScalar,
        onTime = BranchScalar,
        onJson = BranchScalar,
        onOptional = BranchOptional,
        onList = BranchList,
        onMap = BranchMap,
        onRef = \key -> maybe BranchScalar (branchSchemaFor graph) (Map.lookup key (tgDeclarations graph))
      }

renderBranchSchema :: BranchSchema -> Text
renderBranchSchema schema = case schema of
  BranchScalar -> "BranchScalar"
  BranchOptional nested -> "BranchOptional (" <> renderBranchSchema nested <> ")"
  BranchList nested -> "BranchList (" <> renderBranchSchema nested <> ")"
  BranchMap nested -> "BranchMap (" <> renderBranchSchema nested <> ")"
  BranchRecord fields ->
    "BranchRecord ["
      <> T.intercalate
        ", "
        [ "BranchField "
            <> tshow (bfWireKey field)
            <> " "
            <> (if bfPresenceOptional field then "True" else "False")
            <> " ("
            <> renderBranchSchema (bfSchema field)
            <> ")"
        | field <- fields
        ]
      <> "]"
  BranchUnion tagField contentsField arms ->
    "BranchUnion "
      <> tshow tagField
      <> " "
      <> tshow contentsField
      <> " ["
      <> T.intercalate
        ", "
        [ "BranchArm "
            <> tshow (baWireTag arm)
            <> " "
            <> maybe "Nothing" (\nested -> "(Just (" <> renderBranchSchema nested <> "))") (baPayloadSchema arm)
        | arm <- arms
        ]
      <> "]"

-- | Emit one create-once consumer module per distinct qualified obligation
-- owner. Multiple mapped declarations may intentionally share a leaf binding
-- module, so grouping happens by module rather than by declaration.
bindingSkeletonModules :: Context -> Spec -> TypeGraph -> [ScaffoldModule]
bindingSkeletonModules ctx spec graph = map fst (bindingSkeletonOwners ctx spec graph)

-- | 'bindingSkeletonModules' paired with the mapped declarations whose
-- obligations each skeleton carries, in first-appearance order. A skeleton shared
-- by declarations from different member files therefore names all of them, which
-- is what lets whole-workspace scaffolding treat it as context-level rather than
-- attributing it to an arbitrary member.
bindingSkeletonOwners :: Context -> Spec -> TypeGraph -> [(ScaffoldModule, [Name])]
bindingSkeletonOwners ctx spec graph = case bindingObligations spec of
  Left _ -> []
  Right obligations ->
    [ (emitBindingSkeleton ctx spec graph owner entries, nub (map obligationMappedName entries))
    | (owner, entries) <- Map.toAscList (Map.fromListWith (<>) [(obligationModule obligation, [obligation]) | obligation <- obligations])
    ]

emitBindingSkeleton :: Context -> Spec -> TypeGraph -> Text -> [BindingObligation] -> ScaffoldModule
emitBindingSkeleton ctx spec graph owner obligations =
  ScaffoldModule
    { modulePath = T.unpack (T.replace "." "/" owner <> ".hs"),
      moduleText =
        nl $
          [ "{-# LANGUAGE DataKinds #-}",
            "{-# LANGUAGE LambdaCase #-}",
            "",
            "-- This is a HAND-OWNED consumer binding skeleton. keiro-dsl creates it once",
            "-- and never overwrites it. Fill each HOLE and run the generated harness.",
            "module " <> owner <> " ("
          ]
            <> exportLines
            <> [") where", ""]
            <> importLines
            <> [""]
            <> intercalateBlank (map renderObligation obligations),
      kind = HoleStub,
      origin = "consumer binding skeleton " <> owner
    }
  where
    exportLines =
      [ (if index == (0 :: Int) then "    " else "  , ") <> obligationSymbol obligation
      | (index, obligation) <- zip [0 ..] obligations
      ]
    importPlan = bindingSkeletonImportPlan ctx spec graph owner obligations
    importLines =
      sort . nub $
        map ("import " <>) staticImports
          <> T.lines (renderPlannedImports importPlan)
    staticImports =
      sort . nub $
        [ "Keiro.Codec.Structural (FixtureCases, StructuralBinding (..))"
        | any (\obligation -> obligationCategory obligation == "structural" && obligationKind obligation `elem` [BindingValue, FixtureValue]) obligations
        ]
          <> [ "Keiro.Codec.Nominal (NominalBinding (..), NominalFixtureCases)"
             | any ((/= "structural") . obligationCategory) obligations
             ]
          <> [ "Data.KindID (KindID)"
             | obligation <- obligations,
               Just (nominal, _) <- [nominalFor obligation],
               IdRepresentation {} <- [resolvedNominalRepresentation nominal]
             ]
          <> [ "Data.Text (Text)"
             | obligation <- obligations,
               Just (nominal, _) <- [nominalFor obligation],
               ScalarRepresentation NominalText <- [resolvedNominalRepresentation nominal]
             ]
          <> [ "Data.Time (UTCTime)"
             | obligation <- obligations,
               Just (nominal, _) <- [nominalFor obligation],
               ScalarRepresentation NominalTime <- [resolvedNominalRepresentation nominal]
             ]
          <> [ "Numeric.Natural (Natural)"
             | obligation <- obligations,
               Just (nominal, _) <- [nominalFor obligation],
               ScalarRepresentation NominalNatural <- [resolvedNominalRepresentation nominal]
             ]
    renderObligation obligation = case structuralFor obligation of
      Nothing -> case nominalFor obligation of
        Just (nominal, binding) -> renderNominalObligation nominal binding obligation
        Nothing -> ["-- HOLE: declaration disappeared before skeleton rendering"]
      Just (declaration, shape) -> case obligationKind obligation of
        BindingValue -> renderBinding importPlan ctx declaration shape obligation
        FixtureValue ->
          [ "-- HOLE: provide deterministic labelled conformance fixtures for " <> sdName declaration,
            renderStructuralObligationSignature importPlan declaration obligation,
            obligationSymbol obligation <> " = error " <> tshow ("HOLE: fill " <> sdName declaration <> " fixtures")
          ]
        InitialValue ->
          [ "-- HOLE: provide the initial register value for " <> sdName declaration,
            renderStructuralObligationSignature importPlan declaration obligation,
            obligationSymbol obligation <> " = error " <> tshow ("HOLE: fill " <> sdName declaration <> " initial value")
          ]
    structuralFor obligation = case Map.lookup (MappedKey (obligationMappedName obligation)) (tgDeclarations graph) of
      Just (ResolvedStructural declaration shape) -> Just (declaration, shape)
      _ -> Nothing
    nominalFor obligation = do
      registry <- either (const Nothing) Just (resolveNominalTypes spec)
      nominal <- lookupNominalType (obligationMappedName obligation) registry
      binding <- case resolvedNominalOwnership nominal of
        ConsumerNominal value -> Just value
        GeneratedNominal -> Nothing
      pure (nominal, binding)
    renderNominalObligation nominal binding obligation = case obligationKind obligation of
      BindingValue ->
        [ "-- HOLE: complete both total directions; the generated codec remains wire authority.",
          renderNominalObligationSignature importPlan ctx nominal binding obligation,
          obligationSymbol obligation <> " =",
          "  NominalBinding",
          "    { nominalToRepresentation = \\_domainValue -> error " <> tshow ("HOLE: fill " <> resolvedNominalName nominal <> " nominalToRepresentation"),
          "    , nominalFromRepresentation = \\_representationValue -> error " <> tshow ("HOLE: fill " <> resolvedNominalName nominal <> " nominalFromRepresentation"),
          "    }"
        ]
      FixtureValue ->
        [ "-- HOLE: provide deterministic labelled expected-wire fixtures for " <> resolvedNominalName nominal,
          renderNominalObligationSignature importPlan ctx nominal binding obligation,
          obligationSymbol obligation <> " = error " <> tshow ("HOLE: fill " <> resolvedNominalName nominal <> " fixtures")
        ]
      InitialValue ->
        [ "-- HOLE: provide the initial register value for " <> resolvedNominalName nominal,
          renderNominalObligationSignature importPlan ctx nominal binding obligation,
          obligationSymbol obligation <> " = error " <> tshow ("HOLE: fill " <> resolvedNominalName nominal <> " initial value")
        ]
    intercalateBlank [] = []
    intercalateBlank (section : rest) = section <> concatMap ("" :) rest

renderBinding :: HaskellImportPlan -> Context -> StructuralDecl -> ResolvedMappedShape -> BindingObligation -> [Text]
renderBinding importPlan ctx declaration shape obligation =
  [ "-- HOLE: complete both total directions; wire policy remains in the generated codec.",
    obligationSymbol obligation <> " :: StructuralBinding " <> domainType <> " " <> shapeType,
    obligationSymbol obligation <> " =",
    "  StructuralBinding",
    "    { bindingToShape = \\case"
  ]
    <> indentCases (bindingCases True)
    <> ["    , bindingFromShape = \\case"]
    <> indentCases (bindingCases False)
    <> ["    }"]
  where
    domainType = renderReferenceOrDie importPlan (haskellTypeReference (sdHaskell declaration))
    shapeModuleName = structuralShapeModule ctx (sdName declaration)
    shapeType = renderReferenceOrDie importPlan (qualifiedTypeReference shapeModuleName (sdName declaration <> "Shape"))
    domainCtor constructor = renderReferenceOrDie importPlan (constructorReference (hsModule (sdHaskell declaration)) constructor)
    shapeCtor constructor = renderReferenceOrDie importPlan (constructorReference shapeModuleName constructor)
    indentCases = map ("      " <>)
    bindingCases toShapeDirection =
      foldMappedShape
        MappedShapeAlgebra
          { onRecord = \constructor _ fields -> [recordCase toShapeDirection constructor fields],
            onEnum = \entries -> map (enumCase toShapeDirection . weCtor) entries,
            onUnion = \_ arms -> map (unionCase toShapeDirection) arms
          }
        shape
    recordCase toShapeDirection constructor fields =
      sourceCtor
        <> arguments variables
        <> " -> "
        <> targetCtor
        <> arguments (map (holeFor toShapeDirection . rwfHaskell) fields)
      where
        variables = map (("_" <>) . (<> "Value") . rwfHaskell) fields
        sourceCtor = if toShapeDirection then domainCtor constructor else shapeCtor constructor
        targetCtor = if toShapeDirection then shapeCtor constructor else domainCtor constructor
    enumCase toShapeDirection constructor =
      sourceCtor <> " -> " <> holeFor toShapeDirection constructor
      where
        sourceCtor = if toShapeDirection then domainCtor constructor else shapeCtor constructor
    unionCase toShapeDirection arm =
      sourceCtor
        <> maybe "" (const " _payloadValue") (rwaPayload arm)
        <> " -> "
        <> case rwaPayload arm of
          Nothing -> holeFor toShapeDirection (rwaCtor arm)
          Just _ -> targetCtor <> " " <> holeFor toShapeDirection (rwaCtor arm <> ".payload")
      where
        sourceCtor = if toShapeDirection then domainCtor (rwaCtor arm) else shapeCtor (rwaCtor arm)
        targetCtor = if toShapeDirection then shapeCtor (rwaCtor arm) else domainCtor (rwaCtor arm)
    arguments [] = ""
    arguments values = " " <> T.unwords values
    holeFor toShapeDirection fieldName =
      "(error "
        <> tshow
          ( "HOLE: fill "
              <> sdName declaration
              <> (if toShapeDirection then " bindingToShape." else " bindingFromShape.")
              <> fieldName
          )
        <> ")"

bindingSkeletonImportPlan :: Context -> Spec -> TypeGraph -> Text -> [BindingObligation] -> HaskellImportPlan
bindingSkeletonImportPlan ctx spec graph owner obligations =
  planImportsOrDie owner (Set.fromList (map obligationSymbol obligations)) (Set.fromList (concatMap obligationReferences obligations))
  where
    obligationReferences obligation = case Map.lookup (MappedKey (obligationMappedName obligation)) (tgDeclarations graph) of
      Just (ResolvedStructural declaration shape) ->
        haskellTypeReference (sdHaskell declaration)
          : [ qualifiedTypeReference shapeModuleName (sdName declaration <> "Shape")
            | obligationKind obligation == BindingValue
            ]
            <> [ reference
               | obligationKind obligation == BindingValue,
                 constructor <- structuralConstructorNames shape,
                 reference <-
                   [ constructorReference (hsModule (sdHaskell declaration)) constructor,
                     constructorReference shapeModuleName constructor
                   ]
               ]
        where
          shapeModuleName = structuralShapeModule ctx (sdName declaration)
      _ -> case nominalForName (obligationMappedName obligation) of
        Just (nominal, binding) ->
          haskellTypeReference (consumerNominalHaskell binding)
            : [ qualifiedTypeReference
                  (nominalRepresentationModule ctx (resolvedNominalName nominal))
                  (resolvedNominalName nominal <> "Representation")
              | obligationKind obligation == BindingValue,
                EnumRepresentation {} <- [resolvedNominalRepresentation nominal]
              ]
        Nothing -> []
    nominalForName name = do
      registry <- either (const Nothing) Just (resolveNominalTypes spec)
      nominal <- lookupNominalType name registry
      binding <- case resolvedNominalOwnership nominal of
        ConsumerNominal value -> Just value
        GeneratedNominal -> Nothing
      pure (nominal, binding)

structuralConstructorNames :: ResolvedMappedShape -> [Text]
structuralConstructorNames =
  foldMappedShape
    MappedShapeAlgebra
      { onRecord = \constructor _ _ -> [constructor],
        onEnum = map weCtor,
        onUnion = \_ -> map rwaCtor
      }

structuralShapeReferences :: Context -> StructuralDecl -> ResolvedMappedShape -> [HaskellReference]
structuralShapeReferences ctx declaration shape =
  qualifiedTypeReference moduleName (sdName declaration <> "Shape")
    : [constructorReference moduleName constructor | constructor <- structuralConstructorNames shape]
      <> [ HaskellReference moduleName selector ValueNamespace RequireQualified
         | selector <- structuralSelectorNames shape
         ]
  where
    moduleName = structuralShapeModule ctx (sdName declaration)

structuralSelectorNames :: ResolvedMappedShape -> [Text]
structuralSelectorNames =
  foldMappedShape
    MappedShapeAlgebra
      { onRecord = \_ _ -> map rwfHaskell,
        onEnum = const [],
        onUnion = \_ _ -> []
      }

nominalRepresentationEncoderReference :: Context -> ResolvedNominalType -> HaskellReference
nominalRepresentationEncoderReference ctx nominal =
  HaskellReference
    (nominalRepresentationModule ctx name)
    (lowerFirst name <> "RepresentationText")
    ValueNamespace
    RequireQualified
  where
    name = resolvedNominalName nominal

nominalRepresentationConstructorReference :: Context -> ResolvedNominalType -> Text -> HaskellReference
nominalRepresentationConstructorReference ctx nominal constructor =
  HaskellReference
    (nominalRepresentationModule ctx (resolvedNominalName nominal))
    constructor
    ConstructorNamespace
    RequireQualified

renderStructuralObligationSignature :: HaskellImportPlan -> StructuralDecl -> BindingObligation -> Text
renderStructuralObligationSignature importPlan declaration obligation =
  obligationSymbol obligation
    <> " :: "
    <> case obligationKind obligation of
      BindingValue -> error "structural binding signatures are rendered with renderBinding"
      FixtureValue -> "FixtureCases " <> domainType
      InitialValue -> domainType
  where
    domainType = renderReferenceOrDie importPlan (haskellTypeReference (sdHaskell declaration))

renderNominalObligationSignature :: HaskellImportPlan -> Context -> ResolvedNominalType -> ConsumerNominalBinding -> BindingObligation -> Text
renderNominalObligationSignature importPlan ctx nominal binding obligation =
  obligationSymbol obligation
    <> " :: "
    <> case obligationKind obligation of
      BindingValue -> "NominalBinding " <> domainType <> " " <> representationType
      FixtureValue -> "NominalFixtureCases " <> domainType
      InitialValue -> domainType
  where
    domainType = renderReferenceOrDie importPlan (haskellTypeReference (consumerNominalHaskell binding))
    representationType = case resolvedNominalRepresentation nominal of
      IdRepresentation prefix -> "(KindID " <> tshow prefix <> ")"
      EnumRepresentation {} ->
        renderReferenceOrDie
          importPlan
          ( qualifiedTypeReference
              (nominalRepresentationModule ctx (resolvedNominalName nominal))
              (resolvedNominalName nominal <> "Representation")
          )
      ScalarRepresentation NominalText -> "Text"
      ScalarRepresentation NominalInt -> "Int"
      ScalarRepresentation NominalNatural -> "Natural"
      ScalarRepresentation NominalBool -> "Bool"
      ScalarRepresentation NominalTime -> "UTCTime"

qualifiedTypeReference :: Text -> Text -> HaskellReference
qualifiedTypeReference moduleName typeName =
  HaskellReference moduleName typeName TypeNamespace RequireQualified

constructorReference :: Text -> Text -> HaskellReference
constructorReference moduleName constructor =
  HaskellReference moduleName constructor ConstructorNamespace RequireQualified

shapeModule :: Context -> TypeGraph -> (StructuralDecl, ResolvedMappedShape) -> ScaffoldModule
shapeModule ctx graph (declaration, shape) =
  ScaffoldModule
    { modulePath = T.unpack (T.replace "." "/" (structuralShapeModule ctx (sdName declaration)) <> ".hs"),
      moduleText = emitShape ctx graph declaration shape,
      kind = Generated,
      origin = nodeOrigin "mapped structural" (sdName declaration) (sdLoc declaration)
    }

structuralPrefix :: Context -> Text
structuralPrefix ctx = case placement ctx of
  GeneratedPrefix -> rootPrefix ctx <> "Generated." <> ctxPascalOf ctx <> ".Structural"
  CollocatedLeaf -> rootPrefix ctx <> ctxPascalOf ctx <> ".Generated.Structural"

structuralShapeModule :: Context -> Name -> Text
structuralShapeModule ctx name = structuralPrefix ctx <> ".Shape." <> name

nominalRepresentationModule :: Context -> Name -> Text
nominalRepresentationModule ctx name = case placement ctx of
  GeneratedPrefix -> rootPrefix ctx <> "Generated." <> ctxPascalOf ctx <> ".Nominal.Shape." <> name
  CollocatedLeaf -> rootPrefix ctx <> ctxPascalOf ctx <> ".Nominal.Shape." <> name <> ".Generated"

-- | Emit the one generated nominal authority for the complete context. The
-- empty declaration attribution is intentional: in a workspace this module is
-- context-level even when all declarations currently happen to live in one
-- member, so moving that member cannot move Haskell type ownership.
generatedNominalOwners :: Context -> CheckedService -> [(ScaffoldModule, [Name])]
generatedNominalOwners ctx service = case planNominalGenerationForService ctx service of
  Left _ -> []
  Right [] -> []
  Right owners ->
    [ ( ScaffoldModule
          { modulePath = T.unpack (T.replace "." "/" (generatedNominalModule ctx) <> ".hs"),
            moduleText = emitGeneratedNominals languageContract ctx owners,
            kind = Generated,
            origin = "context " <> specContext spec <> " generated nominal declarations"
          },
        []
      )
    ]
      <> [ ( ScaffoldModule
               { modulePath = T.unpack (T.replace "." "/" (generatedNominalInternalModule ctx) <> ".hs"),
                 moduleText = emitGeneratedNominalInternals ctx enforcingIds,
                 kind = Generated,
                 origin = "context " <> specContext spec <> " generated nominal ID internals"
               },
             []
           )
         | not (null enforcingIds)
         ]
    where
      enforcingIds =
        [ (nominal, contract)
        | owner <- owners,
          let nominal = nominalDeclaration owner,
          IdRepresentation prefix <- [resolvedNominalRepresentation nominal],
          Just contract <- [idDomainContractFor languageContract prefix]
        ]
  where
    spec = checkedSpec service
    languageContract = checkedLanguageContract service

generatedNominalInternalModule :: Context -> Text
generatedNominalInternalModule ctx = generatedNominalModule ctx <> ".Internal"

emitGeneratedNominals :: EffectiveLanguageContract -> Context -> [NominalGenerationOwner] -> Text
emitGeneratedNominals languageContract ctx owners =
  nl
    ( renderGeneratedLanguagePragmas localExtensions
        <> [ generatedBanner,
             moduleHeader,
             ""
           ]
        <> baseImports
        <> internalImports
        <> equalityImports
        <> if T.null declarations then [] else ["", declarations]
    )
  where
    usesEquality = any nominalEqualityUsed owners
    exactEqualityOwners = [owner | owner <- owners, nominalEqualityUsed owner, exactOwner (nominalDeclaration owner)]
    inexactEqualityOwners = [owner | owner <- owners, nominalEqualityUsed owner, not (exactOwner (nominalDeclaration owner))]
    usesExactEquality = not (null exactEqualityOwners)
    usesInexactEquality = not (null inexactEqualityOwners)
    legacyNominals =
      [ nominal
      | owner <- owners,
        let nominal = nominalDeclaration owner,
        case resolvedNominalRepresentation nominal of
          IdRepresentation prefix -> not (isJust (idDomainContractFor languageContract prefix))
          EnumRepresentation {} -> True
          ScalarRepresentation {} -> False
      ]
    hasExactEnum = any (\owner -> case resolvedNominalRepresentation (nominalDeclaration owner) of EnumRepresentation {} -> True; _ -> False) exactEqualityOwners
    hasExactEnforcedId = any (\owner -> case resolvedNominalRepresentation (nominalDeclaration owner) of IdRepresentation prefix -> isJust (idDomainContractFor languageContract prefix); _ -> False) exactEqualityOwners
    enforcingIds =
      [ nominal
      | owner <- owners,
        let nominal = nominalDeclaration owner,
        IdRepresentation prefix <- [resolvedNominalRepresentation nominal],
        Just _ <- [idDomainContractFor languageContract prefix]
      ]
    moduleHeader
      | null enforcingIds = "module " <> generatedNominalModule ctx <> " where"
      | otherwise =
          nl
            [ "module " <> generatedNominalModule ctx,
              "  ( " <> T.intercalate "\n  , " (concatMap ownerExports owners),
              "  ) where"
            ]
    ownerExports owner =
      baseExports <> equalityExports
      where
        nominal = nominalDeclaration owner
        name = resolvedNominalName nominal
        baseExports = case resolvedNominalRepresentation nominal of
          IdRepresentation prefix
            | Just _ <- idDomainContractFor languageContract prefix ->
                [name, "parse" <> name, "mk" <> name, nominalTextName nominal]
          _ -> [name <> " (..)", nominalTextName nominal]
        equalityExports =
          if nominalEqualityUsed owner
            then [nominalEqualityTagName nominal, nominalEqualityWitnessName nominal]
            else []
    localExtensions =
      [ExtDeriveAnyClass | any (nominalUsesDeriveAnyClass . nominalDeclaration) owners]
        <> [ExtTypeFamilies | usesEquality]
    baseImports =
      ["import Data.Aeson (FromJSON, ToJSON)" | not (null legacyNominals)]
        <> ["import Data.Text (Text)" | not (null legacyNominals) || usesEquality]
        <> ["import GHC.Generics (Generic)" | not (null legacyNominals)]
        <> ["import Keiki.Shape (CanonicalTypeName)" | not (null legacyNominals)]
    equalityImports =
      [ "import Keiki.Core (" <> T.intercalate ", " coreImports <> ")"
      | usesEquality
      ]
        <> ["import Data.List.NonEmpty (NonEmpty (..))" | hasExactEnum]
        <> [ "import Keiki.ProjectionDomain (" <> T.intercalate ", " projectionDomainImports <> ")"
           | not (null projectionDomainImports)
           ]
        <> ["import Keiro.Codec.IdDomain (idDomainTextPattern, typeIdV7Domain)" | hasExactEnforcedId]
      where
        coreImports =
          ["FieldProjection (..)", "FieldWitness"]
            <> (if usesExactEquality then ["ExactFieldProjection (..)", "exactFieldWitness"] else [])
            <> ["fieldWitness" | usesInexactEquality]
        projectionDomainImports =
          ["finiteProjectionDomain" | hasExactEnum]
            <> (if hasExactEnforcedId then ["TextPattern", "textProjectionDomain"] else [])
    internalImports =
      [ "import "
          <> generatedNominalInternalModule ctx
          <> " ("
          <> T.intercalate
            ", "
            (concatMap (\nominal -> [resolvedNominalName nominal, "mk" <> resolvedNominalName nominal, "parse" <> resolvedNominalName nominal, nominalTextName nominal]) enforcingIds)
          <> ")"
      | not (null enforcingIds)
      ]
    declarations = T.dropWhileEnd (== '\n') (sectionsOf [map emitOwner owners])
    emitOwner owner = emitGeneratedNominal languageContract (nominalEqualityUsed owner) (nominalDeclaration owner)
    exactOwner nominal = case resolvedNominalRepresentation nominal of
      EnumRepresentation {} -> True
      IdRepresentation prefix -> isJust (idDomainContractFor languageContract prefix)
      ScalarRepresentation {} -> False
    nominalUsesDeriveAnyClass nominal = case resolvedNominalRepresentation nominal of
      IdRepresentation prefix -> not (isJust (idDomainContractFor languageContract prefix))
      EnumRepresentation {} -> True
      ScalarRepresentation {} -> False

emitGeneratedNominal :: EffectiveLanguageContract -> Bool -> ResolvedNominalType -> Text
emitGeneratedNominal languageContract equalityUsed nominal = case resolvedNominalRepresentation nominal of
  IdRepresentation prefix
    | Just _ <- idDomainContractFor languageContract prefix ->
        nl equalitySection
  IdRepresentation {} ->
    nl $
      [ "newtype " <> name <> " = " <> name <> " Text",
        "  deriving stock (Generic, Eq, Ord, Show)",
        "  deriving anyclass (ToJSON, FromJSON)",
        "",
        "instance CanonicalTypeName " <> name,
        "",
        nominalTextName nominal <> " :: " <> name <> " -> Text",
        nominalTextName nominal <> " (" <> name <> " value) = value"
      ]
        <> equalitySection
  EnumRepresentation constructors ->
    nl $
      [ "data " <> name <> " = " <> T.intercalate " | " (map fst (NE.toList constructors)),
        "  deriving stock (Generic, Eq, Ord, Show, Enum, Bounded)",
        "  deriving anyclass (ToJSON, FromJSON)",
        "",
        "instance CanonicalTypeName " <> name,
        "",
        nominalTextName nominal <> " :: " <> name <> " -> Text",
        nominalTextName nominal <> " = \\case",
        nl ["  " <> constructor <> " -> " <> tshow wire | (constructor, wire) <- NE.toList constructors]
      ]
        <> equalitySection
  ScalarRepresentation {} ->
    error "generated nominal scalar reached generated declaration emission"
  where
    name = resolvedNominalName nominal
    equalitySection = if equalityUsed then ["", emitGeneratedNominalEquality languageContract nominal] else []

emitGeneratedNominalEquality :: EffectiveLanguageContract -> ResolvedNominalType -> Text
emitGeneratedNominalEquality languageContract nominal =
  nl $
    [ "data " <> tagName,
      "",
      "instance FieldProjection " <> tagName <> " where",
      "  type FieldName " <> tagName <> " = " <> tshow name,
      "  type FieldOwner " <> tagName <> " = " <> name,
      "  type FieldResult " <> tagName <> " = Text",
      "  fieldShapeId _ = " <> tshow equalityIdentity,
      "  projectFieldValue _ = " <> nominalTextName nominal
    ]
      <> exactInstance
      <> [ "",
           witnessName <> " :: FieldWitness " <> tagName,
           witnessName <> " = " <> witnessConstructor <> " @" <> tagName
         ]
  where
    name = resolvedNominalName nominal
    tagName = nominalEqualityTagName nominal
    witnessName = nominalEqualityWitnessName nominal
    equalityIdentity = fromMaybe (error "generated nominal equality contract missing") (nominalEqualityIdentityForService languageContract nominal)
    (exactInstance, witnessConstructor) = case resolvedNominalRepresentation nominal of
      IdRepresentation prefix -> case idDomainContractFor languageContract prefix of
        Nothing -> ([], "fieldWitness")
        Just _ ->
          ( [ "",
              patternName <> " :: TextPattern",
              patternName <> " = either (error . show) id (idDomainTextPattern (typeIdV7Domain " <> tshow prefix <> "))",
              "",
              "instance ExactFieldProjection " <> tagName <> " where",
              "  fieldProjectionDomain _ = textProjectionDomain " <> patternName,
              "  reconstructFieldOwner _ = either (const Nothing) Just . parse" <> name
            ],
            "exactFieldWitness"
          )
      EnumRepresentation constructors ->
        ( [ "",
            "instance ExactFieldProjection " <> tagName <> " where",
            "  fieldProjectionDomain _ = finiteProjectionDomain (" <> renderNonEmpty (map (tshow . snd) (NE.toList constructors)) <> ")",
            "  reconstructFieldOwner _ = \\case"
          ]
            <> ["    " <> tshow wire <> " -> Just " <> constructor | (constructor, wire) <- NE.toList constructors]
            <> ["    _ -> Nothing"],
          "exactFieldWitness"
        )
      ScalarRepresentation {} -> error "generated nominal scalar equality emission"
    patternName = lowerFirst name <> "IdDomainPattern"

emitGeneratedNominalInternals :: Context -> [(ResolvedNominalType, IdDomainContract)] -> Text
emitGeneratedNominalInternals ctx nominals =
  nl
    [ generatedBanner,
      "module " <> generatedNominalInternalModule ctx,
      "  ( " <> T.intercalate "\n  , " (concatMap exportsFor nominals),
      "  ) where",
      "",
      "import Data.Aeson (FromJSON (..), ToJSON (..), withText)",
      "import Data.Text (Text)",
      "import Data.Text qualified as T",
      "import GHC.Generics (Generic)",
      "import Keiki.Shape (CanonicalTypeName)",
      "import Keiro.Codec.IdDomain (typeIdV7Domain, validateIdDomainText)",
      "",
      sectionsOf [map emitInternal nominals]
    ]
  where
    exportsFor (nominal, _) =
      [ resolvedNominalName nominal,
        "parse" <> resolvedNominalName nominal,
        "mk" <> resolvedNominalName nominal,
        nominalTextName nominal,
        legacyNominalConstructorName nominal
      ]
    emitInternal (nominal, contract) =
      nl
        [ "newtype " <> name <> " = " <> name <> " Text",
          "  deriving stock (Generic, Eq, Ord, Show)",
          "",
          "instance CanonicalTypeName " <> name,
          "",
          "instance ToJSON " <> name <> " where",
          "  toJSON = toJSON . " <> textName,
          "",
          "instance FromJSON " <> name <> " where",
          "  parseJSON = withText " <> tshow name <> " (either (fail . T.unpack) pure . parse" <> name <> ")",
          "",
          "parse" <> name <> " :: Text -> Either Text " <> name,
          "parse" <> name <> " input = case validateIdDomainText (typeIdV7Domain " <> tshow (idDomainPrefix contract) <> ") input of",
          "  Left reason -> Left (T.pack (show reason))",
          "  Right () -> Right (" <> name <> " input)",
          "",
          "mk" <> name <> " :: Text -> Either Text " <> name,
          "mk" <> name <> " = parse" <> name,
          "",
          textName <> " :: " <> name <> " -> Text",
          textName <> " (" <> name <> " value) = value",
          "",
          legacyNominalConstructorName nominal <> " :: Text -> " <> name,
          legacyNominalConstructorName nominal <> " = " <> name
        ]
      where
        name = resolvedNominalName nominal
        textName = nominalTextName nominal

nominalEqualityTagName :: ResolvedNominalType -> Text
nominalEqualityTagName nominal = resolvedNominalName nominal <> "EqualityProjection"

nominalEqualityWitnessName :: ResolvedNominalType -> Text
nominalEqualityWitnessName nominal = lowerFirst (resolvedNominalName nominal) <> "EqualityWitness"

renderNonEmpty :: [Text] -> Text
renderNonEmpty values = case values of
  [] -> error "cannot render an empty exact projection domain"
  firstValue : rest -> firstValue <> " :| [" <> T.intercalate ", " rest <> "]"

nominalTextName :: ResolvedNominalType -> Text
nominalTextName = (<> "Text") . lowerFirst . resolvedNominalName

-- | Explicit type/constructor imports for exactly the generated declarations a
-- generated aggregate module uses. Keeping an import list avoids making every
-- aggregate depend on every service declaration merely because they share the
-- one owner module.
generatedNominalTypeImports :: Context -> [ResolvedNominalType] -> [Text]
generatedNominalTypeImports _ [] = []
generatedNominalTypeImports ctx nominals =
  [ "import "
      <> generatedNominalModule ctx
      <> " ("
      <> T.intercalate ", " [resolvedNominalName nominal <> " (..)" | nominal <- stableNominals nominals]
      <> ")"
  ]

generatedNominalTypeImportsForService :: CheckedService -> Context -> [ResolvedNominalType] -> [Text]
generatedNominalTypeImportsForService service ctx nominals =
  generatedNominalTypeImportsWithParsers service ctx nominals nominals

-- | As 'generatedNominalTypeImportsForService', but importing an enforced ID's
-- @parse\<Name\>@ only for the nominals in @parsing@.
--
-- The parser is emitted only where a literal of that ID is constructed. A module
-- that merely mentions the type — a guard operand, say — needs the type name and
-- nothing else, and importing the parser there is an unused import.
generatedNominalTypeImportsWithParsers :: CheckedService -> Context -> [ResolvedNominalType] -> [ResolvedNominalType] -> [Text]
generatedNominalTypeImportsWithParsers _ _ [] _ = []
generatedNominalTypeImportsWithParsers service ctx nominals parsing =
  [ "import "
      <> generatedNominalModule ctx
      <> " ("
      <> T.intercalate ", " (concatMap importsFor (stableNominals nominals))
      <> ")"
  ]
  where
    parsingNames = map resolvedNominalName (stableNominals parsing)
    importsFor nominal = case resolvedNominalRepresentation nominal of
      IdRepresentation prefix
        | Just _ <- idDomainContractFor (checkedLanguageContract service) prefix ->
            [resolvedNominalName nominal]
              <> ["parse" <> resolvedNominalName nominal | resolvedNominalName nominal `elem` parsingNames]
      _ -> [resolvedNominalName nominal <> " (..)"]

generatedNominalCodecImports :: CheckedService -> Context -> [ResolvedNominalType] -> [Text]
generatedNominalCodecImports _ _ [] = []
generatedNominalCodecImports service ctx nominals =
  [ "import "
      <> generatedNominalModule ctx
      <> " ("
      <> T.intercalate
        ", "
        ( concat
            [ publicImports nominal
            | nominal <- stableNominals nominals
            ]
        )
      <> ")"
  ]
    <> [ "import "
           <> generatedNominalInternalModule ctx
           <> " ("
           <> T.intercalate ", " [legacyNominalConstructorName nominal | nominal <- enforcingIds]
           <> ")"
       | not (null enforcingIds)
       ]
  where
    publicImports nominal = case resolvedNominalRepresentation nominal of
      IdRepresentation prefix
        | Just _ <- idDomainContractFor (checkedLanguageContract service) prefix -> [nominalTextName nominal]
      _ -> [resolvedNominalName nominal <> " (..)", nominalTextName nominal]
    enforcingIds =
      [ nominal
      | nominal <- stableNominals nominals,
        IdRepresentation prefix <- [resolvedNominalRepresentation nominal],
        Just _ <- [idDomainContractFor (checkedLanguageContract service) prefix]
      ]

legacyNominalConstructorName :: ResolvedNominalType -> Text
legacyNominalConstructorName nominal = "unsafe" <> resolvedNominalName nominal <> "FromLegacyText"

stableNominals :: [ResolvedNominalType] -> [ResolvedNominalType]
stableNominals = Map.elems . Map.fromList . map (\nominal -> (resolvedNominalName nominal, nominal))

nominalRepresentationOwners :: Context -> Spec -> [(ScaffoldModule, [Name])]
nominalRepresentationOwners ctx spec = case resolveNominalTypes spec of
  Left _ -> []
  Right registry ->
    [ (nominalRepresentationModuleValue ctx nominal constructors, [resolvedNominalName nominal])
    | nominal <- Map.elems (nominalTypes registry),
      ConsumerNominal {} <- [resolvedNominalOwnership nominal],
      EnumRepresentation constructors <- [resolvedNominalRepresentation nominal]
    ]

nominalRepresentationModuleValue :: Context -> ResolvedNominalType -> NonEmpty (Name, Text) -> ScaffoldModule
nominalRepresentationModuleValue ctx nominal constructors =
  ScaffoldModule
    { modulePath = T.unpack (T.replace "." "/" moduleName <> ".hs"),
      moduleText =
        nl
          [ generatedBanner,
            "module " <> moduleName <> " (" <> representationType <> " (..), " <> encoderName <> ") where",
            "",
            "import Data.Text (Text)",
            "import GHC.Generics (Generic)",
            "",
            "data " <> representationType <> " = " <> T.intercalate " | " (map fst (NE.toList constructors)),
            "  deriving stock (Eq, Generic, Ord, Show, Enum, Bounded)",
            "",
            encoderName <> " :: " <> representationType <> " -> Text",
            encoderName <> " = \\case",
            nl ["  " <> constructor <> " -> " <> tshow wire | (constructor, wire) <- NE.toList constructors]
          ],
      kind = Generated,
      origin = nodeOrigin "bound nominal enum representation" (resolvedNominalName nominal) (resolvedNominalLoc nominal)
    }
  where
    moduleName = nominalRepresentationModule ctx (resolvedNominalName nominal)
    representationType = resolvedNominalName nominal <> "Representation"
    encoderName = lowerFirst (resolvedNominalName nominal) <> "RepresentationText"

nominalProjectionModule :: Context -> Text
nominalProjectionModule ctx = case placement ctx of
  GeneratedPrefix -> rootPrefix ctx <> "Generated." <> ctxPascalOf ctx <> ".NominalProjections"
  CollocatedLeaf -> rootPrefix ctx <> ctxPascalOf ctx <> ".Generated.NominalProjections"

nominalProjectionOwners :: Context -> CheckedService -> [(ScaffoldModule, [Name])]
nominalProjectionOwners ctx service = case nominalProjectionTypes spec of
  [] -> []
  nominals ->
    [ ( ScaffoldModule
          { modulePath = T.unpack (T.replace "." "/" (nominalProjectionModule ctx) <> ".hs"),
            moduleText = emitNominalProjections (checkedLanguageContract service) ctx nominals,
            kind = Generated,
            origin = "context " <> specContext spec <> " nominal scalar projection facade"
          },
        []
      )
    ]
  where
    spec = checkedSpec service

nominalProjectionTypes :: Spec -> [ResolvedNominalType]
nominalProjectionTypes spec =
  Map.elems . Map.fromList $
    [ (resolvedNominalName nominal, nominal)
    | aggregate <- [value | NAggregate value <- specNodes spec],
      resolved <- registerTypes aggregate <> commandTypes aggregate,
      AggregateNominal nominal <- [resolved],
      ConsumerNominal {} <- [resolvedNominalOwnership nominal]
    ]
  where
    symbols = aggregateSymbols spec
    registerTypes aggregate =
      [ resolved
      | register <- aggRegs aggregate,
        Right resolved <- [resolveAggregateType symbols (regLoc register) RegisterUse (regType register)]
      ]
    commandTypes aggregate =
      [ resolved
      | command <- aggCommands aggregate,
        field <- cmdFields command,
        Right resolved <- [inferAggregateFieldType symbols aggregate CommandFieldUse field]
      ]

emitNominalProjections :: EffectiveLanguageContract -> Context -> [ResolvedNominalType] -> Text
emitNominalProjections languageContract ctx nominals =
  nl $
    renderGeneratedLanguagePragmas [ExtTypeFamilies]
      <> [ generatedBanner,
           "module " <> moduleName <> " where",
           ""
         ]
      <> map ("import " <>) imports
      <> T.lines (renderPlannedImports importPlan)
      <> [""]
      <> [T.intercalate "\n\n" (map emitNominalProjection nominals)]
  where
    moduleName = nominalProjectionModule ctx
    imports =
      sort . nub $
        [ "Keiki.Core (" <> T.intercalate ", " coreImports <> ")",
          "Keiro.Codec.Nominal (" <> T.intercalate ", " nominalCodecImports <> ")"
        ]
          <> ["Data.KindID qualified as KindID" | any hasId nominals]
          <> ["Keiro.Codec.IdDomain (idDomainTextPattern, typeIdV7Domain, validateIdDomainText)" | any hasEnforcedId nominals]
          <> ["Data.List.NonEmpty (NonEmpty (..))" | any hasExactDomain nominals]
          <> ["Data.Text (Text)" | any usesText nominals]
          <> ["Data.Time (UTCTime)" | any (hasScalar NominalTime) nominals]
          -- The four text combinators build the legacy hand-rolled TypeID
          -- pattern and are used only by the unenforced-ID branch; importing
          -- them unconditionally warns under -Wunused-imports whenever every
          -- exact-domain nominal is an enum or an enforced ID.
          <> [ "Keiki.ProjectionDomain ("
                 <> T.intercalate
                   ", "
                   ( ["TextPattern", "finiteProjectionDomain", "matchesTextPattern", "textProjectionDomain"]
                       <> (if any hasUnenforcedId nominals then ["textCharSet", "textConcat", "textLiteral", "textRepeatBetween"] else [])
                   )
                 <> ")"
             | any hasExactDomain nominals
             ]
          <> ["Numeric.Natural (Natural)" | any (hasScalar NominalNatural) nominals]
    hasExactProjection nominal = case resolvedNominalRepresentation nominal of ScalarRepresentation {} -> False; _ -> True
    hasInexactProjection = any (not . hasExactProjection) nominals
    hasReconstruction = any hasExactProjection nominals
    coreImports =
      ["FieldProjection (..)", "FieldWitness"]
        <> (if hasReconstruction then ["ExactFieldProjection (..)", "exactFieldWitness"] else [])
        <> ["fieldWitness" | hasInexactProjection]
    nominalCodecImports =
      ["nominalToRepresentation"]
        <> ["nominalFromRepresentation" | hasReconstruction]
    hasScalar wanted nominal = resolvedNominalRepresentation nominal == ScalarRepresentation wanted
    hasId nominal = case resolvedNominalRepresentation nominal of IdRepresentation {} -> True; _ -> False
    hasEnforcedId nominal = case resolvedNominalRepresentation nominal of
      IdRepresentation prefix -> isJust (idDomainContractFor languageContract prefix)
      _ -> False
    hasUnenforcedId nominal = case resolvedNominalRepresentation nominal of
      IdRepresentation prefix -> isNothing (idDomainContractFor languageContract prefix)
      _ -> False
    hasExactDomain nominal = case resolvedNominalRepresentation nominal of ScalarRepresentation {} -> False; _ -> True
    usesText nominal = case resolvedNominalRepresentation nominal of ScalarRepresentation NominalText -> True; IdRepresentation {} -> True; EnumRepresentation {} -> True; _ -> False
    importPlan =
      planImportsOrDie
        moduleName
        ( Set.fromList
            [ tagName
            | nominal <- nominals,
              tagName <- case resolvedNominalRepresentation nominal of
                ScalarRepresentation {} -> [resolvedNominalName nominal <> "NominalProjection"]
                IdRepresentation {} -> [nominalEqualityTagName nominal]
                EnumRepresentation {} -> [nominalEqualityTagName nominal]
            ]
        )
        ( Set.fromList
            [ reference
            | nominal <- nominals,
              ConsumerNominal binding <- [resolvedNominalOwnership nominal],
              reference <-
                [ haskellTypeReference (consumerNominalHaskell binding),
                  qualifiedValueReference (consumerNominalBinding binding)
                ]
                  <> case resolvedNominalRepresentation nominal of
                    EnumRepresentation constructors ->
                      HaskellReference representationModule (lowerFirst (resolvedNominalName nominal) <> "RepresentationText") ValueNamespace RequireQualified
                        : [ HaskellReference representationModule constructor ConstructorNamespace RequireQualified
                          | (constructor, _) <- NE.toList constructors
                          ]
                      where
                        representationModule = nominalRepresentationModule ctx (resolvedNominalName nominal)
                    _ -> []
            ]
        )
    emitNominalProjection nominal = case resolvedNominalOwnership nominal of
      GeneratedNominal -> ""
      ConsumerNominal binding -> case resolvedNominalRepresentation nominal of
        ScalarRepresentation {} -> emitScalarProjection nominal binding
        IdRepresentation prefix -> emitConsumerIdProjection nominal binding prefix
        EnumRepresentation constructors -> emitConsumerEnumProjection nominal binding constructors
    emitScalarProjection nominal binding =
      nl
        [ "data " <> tagName,
          "",
          "instance FieldProjection " <> tagName <> " where",
          "  type FieldName " <> tagName <> " = " <> tshow name,
          "  type FieldOwner " <> tagName <> " = " <> renderReferenceOrDie importPlan (haskellTypeReference (consumerNominalHaskell binding)),
          "  type FieldResult " <> tagName <> " = " <> scalarHaskellType (resolvedNominalRepresentation nominal),
          "  fieldShapeId _ = " <> tshow (unCanonicalTypeId (consumerNominalCanonical binding)),
          "  projectFieldValue _ = nominalToRepresentation " <> renderReferenceOrDie importPlan (qualifiedValueReference (consumerNominalBinding binding)),
          "",
          witnessName <> " :: FieldWitness " <> tagName,
          witnessName <> " = fieldWitness @" <> tagName
        ]
      where
        name = resolvedNominalName nominal
        tagName = name <> "NominalProjection"
        witnessName = lowerFirst name <> "Witness"
    emitConsumerIdProjection nominal binding prefix =
      nl
        ( patternLines
            <> [ "",
                 "data " <> tagName,
                 "",
                 "instance FieldProjection " <> tagName <> " where",
                 "  type FieldName " <> tagName <> " = " <> tshow name,
                 "  type FieldOwner " <> tagName <> " = " <> ownerType,
                 "  type FieldResult " <> tagName <> " = Text",
                 "  fieldShapeId _ = " <> tshow equalityIdentity,
                 "  projectFieldValue _ = KindID.toText . nominalToRepresentation " <> bindingName,
                 "",
                 "instance ExactFieldProjection " <> tagName <> " where",
                 "  fieldProjectionDomain _ = textProjectionDomain " <> patternName,
                 "  reconstructFieldOwner _ value"
               ]
            <> validationGuard
            <> [ "    | not (matchesTextPattern " <> patternName <> " value) = Nothing",
                 "    | otherwise = case KindID.parseText @" <> tshow prefix <> " value of",
                 "        Left _ -> Nothing",
                 "        Right representation -> Just (nominalFromRepresentation " <> bindingName <> " representation)",
                 "",
                 witnessName <> " :: FieldWitness " <> tagName,
                 witnessName <> " = exactFieldWitness @" <> tagName
               ]
        )
      where
        name = resolvedNominalName nominal
        tagName = nominalEqualityTagName nominal
        witnessName = nominalEqualityWitnessName nominal
        patternName = lowerFirst name <> "EqualityPattern"
        ownerType = renderReferenceOrDie importPlan (haskellTypeReference (consumerNominalHaskell binding))
        bindingName = renderReferenceOrDie importPlan (qualifiedValueReference (consumerNominalBinding binding))
        equalityIdentity = fromMaybe (error "consumer ID equality contract missing") (nominalEqualityIdentityForService languageContract nominal)
        enforced = isJust (idDomainContractFor languageContract prefix)
        patternLines
          | enforced =
              [ patternName <> " :: TextPattern",
                patternName <> " = either (error . show) id (idDomainTextPattern (typeIdV7Domain " <> tshow prefix <> "))"
              ]
          | otherwise =
              [ patternName <> " :: TextPattern",
                patternName <> " = either (error . show) id $ do",
                "  prefix <- textLiteral " <> tshow (prefix <> "_"),
                "  leading <- textCharSet ('0' :| \"1234567\")",
                "  crockford <- textCharSet ('0' :| \"123456789abcdefghjkmnpqrstvwxyz\")",
                "  suffix <- textRepeatBetween 25 25 crockford",
                "  pure (textConcat (prefix :| [leading, suffix]))"
              ]
        validationGuard =
          [ "    | Left _ <- validateIdDomainText (typeIdV7Domain " <> tshow prefix <> ") value = Nothing"
          | enforced
          ]
    emitConsumerEnumProjection nominal binding constructors =
      nl $
        [ "data " <> tagName,
          "",
          "instance FieldProjection " <> tagName <> " where",
          "  type FieldName " <> tagName <> " = " <> tshow name,
          "  type FieldOwner " <> tagName <> " = " <> ownerType,
          "  type FieldResult " <> tagName <> " = Text",
          "  fieldShapeId _ = " <> tshow equalityIdentity,
          "  projectFieldValue _ = " <> encoderName <> " . nominalToRepresentation " <> bindingName,
          "",
          "instance ExactFieldProjection " <> tagName <> " where",
          "  fieldProjectionDomain _ = finiteProjectionDomain (" <> renderNonEmpty (map (tshow . snd) (NE.toList constructors)) <> ")",
          "  reconstructFieldOwner _ = \\case"
        ]
          <> [ "    " <> tshow wire <> " -> Just (nominalFromRepresentation " <> bindingName <> " " <> representationConstructor constructor <> ")"
             | (constructor, wire) <- NE.toList constructors
             ]
          <> [ "    _ -> Nothing",
               "",
               witnessName <> " :: FieldWitness " <> tagName,
               witnessName <> " = exactFieldWitness @" <> tagName
             ]
      where
        name = resolvedNominalName nominal
        tagName = nominalEqualityTagName nominal
        witnessName = nominalEqualityWitnessName nominal
        ownerType = renderReferenceOrDie importPlan (haskellTypeReference (consumerNominalHaskell binding))
        bindingName = renderReferenceOrDie importPlan (qualifiedValueReference (consumerNominalBinding binding))
        representationModule = nominalRepresentationModule ctx name
        encoderName = renderReferenceOrDie importPlan (HaskellReference representationModule (lowerFirst name <> "RepresentationText") ValueNamespace RequireQualified)
        representationConstructor constructor = renderReferenceOrDie importPlan (HaskellReference representationModule constructor ConstructorNamespace RequireQualified)
        equalityIdentity = fromMaybe (error "consumer enum equality contract missing") (nominalEqualityIdentityForService languageContract nominal)
    scalarHaskellType representation = case representation of
      ScalarRepresentation NominalText -> "Text"
      ScalarRepresentation NominalInt -> "Int"
      ScalarRepresentation NominalNatural -> "Natural"
      ScalarRepresentation NominalBool -> "Bool"
      ScalarRepresentation NominalTime -> "UTCTime"
      IdRepresentation {} -> "()"
      EnumRepresentation {} -> "()"

structuralProjectionModule :: Context -> Text
structuralProjectionModule ctx = structuralPrefix ctx <> "Projections"

emitShape :: Context -> TypeGraph -> StructuralDecl -> ResolvedMappedShape -> Text
emitShape ctx graph declaration shape =
  nl $
    languagePragmas
      <> [ generatedBanner,
           "module " <> moduleName <> " (" <> shapeType <> " (..)) where",
           ""
         ]
      <> map ("import " <>) imports
      <> T.lines (renderPlannedImports importPlan)
      <> ["" | not (null imports) || not (T.null (renderPlannedImports importPlan))]
      <> [shapeDeclaration]
  where
    moduleName = structuralShapeModule ctx (sdName declaration)
    shapeType = sdName declaration <> "Shape"
    requirements = shapeRequirements ctx graph shape
    languagePragmas = renderGeneratedLanguagePragmas []
    imports =
      sort . nub $
        ["Data.Aeson (Value)" | ReqJson `elem` requirements]
          <> ["Data.Map.Strict (Map)" | ReqMap `elem` requirements]
          <> ["Data.Text (Text)" | ReqText `elem` requirements]
          <> ["Data.Time (UTCTime)" | ReqTime `elem` requirements]
          <> ["GHC.Generics (Generic)"]
          <> ["Numeric.Natural (Natural)" | ReqNatural `elem` requirements]
    shapeDeclaration =
      foldMappedShape
        MappedShapeAlgebra
          { onRecord = \constructor _ fields ->
              nl $
                ["data " <> shapeType <> " = " <> constructor]
                  <> recordFields
                    [ (rwfHaskell field, renderShapeType importPlan ctx graph (rwfType field))
                    | field <- fields
                    ]
                  <> ["  deriving stock (Eq, Generic, Show)"],
            onEnum = \entries ->
              "data "
                <> shapeType
                <> " = "
                <> T.intercalate " | " (map weCtor entries)
                <> "\n  deriving stock (Eq, Generic, Show)",
            onUnion = \_ arms ->
              nl $
                case arms of
                  [] -> ["data " <> shapeType <> " = " <> shapeType <> "Empty", "  deriving stock (Eq, Generic, Show)"]
                  firstArm : rest ->
                    ["data " <> shapeType <> " = " <> renderArm firstArm]
                      <> ["  | " <> renderArm arm | arm <- rest]
                      <> ["  deriving stock (Eq, Generic, Show)"]
          }
        shape
    renderArm arm = rwaCtor arm <> maybe "" ((" !" <>) . renderShapeType importPlan ctx graph) (rwaPayload arm)
    importPlan =
      planImportsOrDie
        moduleName
        (Set.singleton shapeType)
        (Set.fromList [reference | ReqReference reference <- requirements])

data ShapeRequirement
  = ReqJson
  | ReqMap
  | ReqText
  | ReqTime
  | ReqNatural
  | ReqReference !HaskellReference
  deriving stock (Eq, Ord, Show)

shapeRequirements :: Context -> TypeGraph -> ResolvedMappedShape -> [ShapeRequirement]
shapeRequirements ctx graph =
  foldMappedShape
    MappedShapeAlgebra
      { onRecord = \_ _ fields -> concatMap (exprRequirements ctx graph . rwfType) fields,
        onEnum = const [],
        onUnion = \_ arms -> concatMap (maybe [] (exprRequirements ctx graph) . rwaPayload) arms
      }

exprRequirements :: Context -> TypeGraph -> ResolvedTypeExpr -> [ShapeRequirement]
exprRequirements ctx graph =
  foldTypeExpr
    TypeExprAlgebra
      { onText = [ReqText],
        onInt = [],
        onInteger = [],
        onBool = [],
        onNatural = [ReqNatural],
        onTime = [ReqTime],
        onJson = [ReqJson],
        onOptional = id,
        onList = id,
        onMap = (ReqMap :) . (ReqText :),
        onRef = \key -> case Map.lookup key (tgDeclarations graph) of
          Just (ResolvedStructural declaration _) ->
            [ ReqReference
                ( HaskellReference
                    (structuralShapeModule ctx (sdName declaration))
                    (sdName declaration <> "Shape")
                    TypeNamespace
                    RequireQualified
                )
            ]
          Just (ResolvedOpaque declaration) -> [ReqReference (haskellTypeReference (odHaskell declaration))]
          Nothing -> []
      }

renderShapeType :: HaskellImportPlan -> Context -> TypeGraph -> ResolvedTypeExpr -> Text
renderShapeType importPlan ctx graph =
  renderStrictOrApplicationArgument
    . foldTypeExpr
      TypeExprAlgebra
        { onText = atomicShapeType "Text",
          onInt = atomicShapeType "Int",
          onInteger = atomicShapeType "Integer",
          onBool = atomicShapeType "Bool",
          onNatural = atomicShapeType "Natural",
          onTime = atomicShapeType "UTCTime",
          onJson = atomicShapeType "Value",
          onOptional = applicationShapeType . ("Maybe " <>) . renderStrictOrApplicationArgument,
          onList = atomicShapeType . ("[" <>) . (<> "]") . renderedShapeTypeText,
          onMap = applicationShapeType . ("Map Text " <>) . renderStrictOrApplicationArgument,
          onRef =
            atomicShapeType . \key -> case Map.lookup key (tgDeclarations graph) of
              Just (ResolvedStructural nested _) ->
                renderReferenceOrDie
                  importPlan
                  (HaskellReference (structuralShapeModule ctx (sdName nested)) (sdName nested <> "Shape") TypeNamespace RequireQualified)
              Just (ResolvedOpaque opaque) ->
                renderReferenceOrDie importPlan (haskellTypeReference (odHaskell opaque))
              Nothing -> "()"
        }

data ShapeTypePrecedence
  = AtomicShapeType
  | ApplicationShapeType

data RenderedShapeType = RenderedShapeType
  { renderedShapeTypePrecedence :: !ShapeTypePrecedence,
    renderedShapeTypeText :: !Text
  }

atomicShapeType :: Text -> RenderedShapeType
atomicShapeType = RenderedShapeType AtomicShapeType

applicationShapeType :: Text -> RenderedShapeType
applicationShapeType = RenderedShapeType ApplicationShapeType

renderStrictOrApplicationArgument :: RenderedShapeType -> Text
renderStrictOrApplicationArgument rendered = case renderedShapeTypePrecedence rendered of
  AtomicShapeType -> renderedShapeTypeText rendered
  ApplicationShapeType -> "(" <> renderedShapeTypeText rendered <> ")"

data StructuralProjection = StructuralProjection
  { spTag :: !Text,
    spWitness :: !Text,
    spPointer :: !Text,
    spOwner :: !HaskellSource,
    spResult :: !Text,
    spCanonical :: !CanonicalTypeId,
    spBinding :: !QualifiedValueName,
    spSelectors :: ![(Text, Text)]
  }
  deriving stock (Eq, Show)

projectionSpecs :: TypeGraph -> [StructuralProjection]
projectionSpecs graph =
  sortOn spTag . allocateProjectionNames . concat $
    [ projectionsForRoot graph declaration shape
    | ResolvedStructural declaration shape <- Map.elems (tgDeclarations graph)
    ]

projectionsForRoot :: TypeGraph -> StructuralDecl -> ResolvedMappedShape -> [StructuralProjection]
projectionsForRoot graph root rootShape = case rootShape of
  RRecord _ _ fields -> concatMap (walkField [] []) fields
  REnum {} -> []
  RUnion {} -> []
  where
    walkField keys selectors field
      | rwfPresence field /= PRequired = []
      | otherwise = case projectionScalar (rwfType field) of
          Just result -> [mkProjection (keys <> [rwfKey field]) (selectors <> [(shapeModuleForOwner, rwfHaskell field)]) result]
          Nothing -> case rwfType field of
            RRef key -> case Map.lookup key (tgDeclarations graph) of
              Just (ResolvedStructural nested (RRecord _ _ nestedFields)) ->
                concatMap
                  (walkNested nested (keys <> [rwfKey field]) (selectors <> [(shapeModuleForOwner, rwfHaskell field)]))
                  nestedFields
              _ -> []
            _ -> []
      where
        shapeModuleForOwner = "__SHAPE__." <> sdName root

    walkNested owner keys selectors field
      | rwfPresence field /= PRequired = []
      | otherwise = case projectionScalar (rwfType field) of
          Just result -> [mkProjection (keys <> [rwfKey field]) (selectors <> [(shapeModuleFor owner, rwfHaskell field)]) result]
          Nothing -> case rwfType field of
            RRef key -> case Map.lookup key (tgDeclarations graph) of
              Just (ResolvedStructural nested (RRecord _ _ nestedFields)) ->
                concatMap
                  (walkNested nested (keys <> [rwfKey field]) (selectors <> [(shapeModuleFor owner, rwfHaskell field)]))
                  nestedFields
              _ -> []
            _ -> []

    -- Context is supplied when rendering; this marker is replaced there.
    shapeModuleFor declaration = "__SHAPE__." <> sdName declaration
    mkProjection keys selectors result =
      StructuralProjection
        { spTag = nameStem <> "Projection",
          spWitness = lowerFirst nameStem <> "Witness",
          spPointer = pointer,
          spOwner = sdHaskell root,
          spResult = result,
          spCanonical = sdCanonical root,
          spBinding = sdBinding root,
          spSelectors = selectors
        }
      where
        pointer = T.concat ["/" <> escapePointer key | key <- keys]
        nameStem = projectionNameStem (sdName root) pointer

projectionScalar :: ResolvedTypeExpr -> Maybe Text
projectionScalar = \case
  RText -> Just "Text"
  RInt -> Just "Int"
  RInteger -> Just "Integer"
  RBool -> Just "Bool"
  RTime -> Just "UTCTime"
  RNatural -> Just "Natural"
  RJson -> Nothing
  ROptional {} -> Nothing
  RList {} -> Nothing
  RMap {} -> Nothing
  RRef {} -> Nothing

escapePointer :: Text -> Text
escapePointer = T.replace "/" "~1" . T.replace "~" "~0"

projectionNameStem :: Name -> Text -> Text
projectionNameStem owner pointer =
  pascal owner
    <> T.concat
      [ normaliseAliasPart (unescapePointer segment)
      | segment <- filter (not . T.null) (T.splitOn "/" pointer)
      ]

-- | Add a stable digest only when two distinct wire paths normalize to the
-- same Haskell name. Digest collisions receive a deterministic ordinal, so the
-- emitter never produces duplicate declarations even in that unlikely case.
allocateProjectionNames :: [StructuralProjection] -> [StructuralProjection]
allocateProjectionNames specs = concatMap allocateGroup groups
  where
    groups = groupBy (\left right -> spTag left == spTag right) (sortOn spTag specs)
    allocateGroup [spec] = [spec]
    allocateGroup collided = reverse named
      where
        ordered = sortOn projectionIdentity collided
        digest spec = T.take 8 (fnv1a64 (projectionIdentity spec))
        digestCounts = Map.fromListWith (+) [(digest spec, 1 :: Int) | spec <- ordered]
        (_, named) = foldl allocate (Map.empty, []) ordered
        allocate (seen, allocated) spec =
          let shortDigest = digest spec
              occurrence = Map.findWithDefault 0 shortDigest seen + 1
              suffix =
                shortDigest
                  <> if Map.findWithDefault 0 shortDigest digestCounts == 1
                    then ""
                    else tshow' occurrence
           in (Map.insert shortDigest occurrence seen, renameWithSuffix suffix spec : allocated)
    projectionIdentity spec = unCanonicalTypeId (spCanonical spec) <> "#" <> spPointer spec
    renameWithSuffix suffix spec =
      spec
        { spTag = nameStem <> suffix <> "Projection",
          spWitness = lowerFirst nameStem <> suffix <> "Witness"
        }
      where
        nameStem = fromMaybe (spTag spec) (T.stripSuffix "Projection" (spTag spec))

projectionWitnessName :: TypeGraph -> MappedKey -> Text -> Maybe Text
projectionWitnessName graph owner pointer = do
  ResolvedStructural declaration _ <- Map.lookup owner (tgDeclarations graph)
  spWitness
    <$> find
      (\spec -> spCanonical spec == sdCanonical declaration && spPointer spec == pointer)
      (projectionSpecs graph)

emitStructuralProjections :: Context -> TypeGraph -> Text
emitStructuralProjections ctx graph =
  nl $
    renderGeneratedLanguagePragmas [ExtTypeFamilies | not (null specs)]
      <> [ generatedBanner,
           "-- Equality witnesses are emitted for Text, Int, Bool, Natural, and UTCTime.",
           "-- Int, Natural, and UTCTime belong to Keiki's ordered subset.",
           "module " <> moduleName,
           "  ( " <> T.intercalate "\n  , " (map spWitness specs),
           "  ) where",
           ""
         ]
      <> staticImports
      <> T.lines (renderPlannedImports importPlan)
      <> concatMap renderProjection specs
  where
    moduleName = structuralProjectionModule ctx
    specs = map (resolveProjectionModules ctx) (projectionSpecs graph)
    resultTypes = Set.fromList (map spResult specs)
    staticImports =
      ["import Data.Text (Text)" | "Text" `Set.member` resultTypes]
        <> ["import Data.Time (UTCTime)" | "UTCTime" `Set.member` resultTypes]
        <> ["import Numeric.Natural (Natural)" | "Natural" `Set.member` resultTypes]
        <> ["import Keiro.Codec.Structural (bindingToShape)" | not (null specs)]
        <> ["import Keiki.Core (FieldProjection (..), FieldWitness, fieldWitness)" | not (null specs)]
    importPlan =
      planImportsOrDie
        moduleName
        (Set.fromList (map spTag specs))
        ( Set.fromList
            ( [haskellTypeReference (spOwner spec) | spec <- specs]
                <> [qualifiedValueReference (spBinding spec) | spec <- specs]
                <> [ HaskellReference shapeModuleName selector ValueNamespace RequireQualified
                   | spec <- specs,
                     (shapeModuleName, selector) <- spSelectors spec
                   ]
            )
        )
    renderProjection spec =
      [ "",
        "data " <> spTag spec,
        "",
        "instance FieldProjection " <> spTag spec <> " where",
        "  type FieldName " <> spTag spec <> " = " <> tshow (spPointer spec),
        "  type FieldOwner " <> spTag spec <> " = " <> renderReferenceOrDie importPlan (haskellTypeReference (spOwner spec)),
        "  type FieldResult " <> spTag spec <> " = " <> spResult spec,
        "  fieldShapeId _ = " <> tshow (unCanonicalTypeId (spCanonical spec)),
        "  projectFieldValue _ owner = " <> renderGetter spec,
        "",
        spWitness spec <> " :: FieldWitness " <> spTag spec,
        spWitness spec <> " = fieldWitness @" <> spTag spec
      ]
    renderGetter spec =
      foldl
        ( \value (shapeModuleName, selector) ->
            renderReferenceOrDie importPlan (HaskellReference shapeModuleName selector ValueNamespace RequireQualified)
              <> " ("
              <> value
              <> ")"
        )
        ("bindingToShape " <> renderReferenceOrDie importPlan (qualifiedValueReference (spBinding spec)) <> " owner")
        (spSelectors spec)

resolveProjectionModules :: Context -> StructuralProjection -> StructuralProjection
resolveProjectionModules ctx spec =
  spec
    { spSelectors =
        [ (replaceModule marker, selector)
        | (marker, selector) <- spSelectors spec
        ]
    }
  where
    replaceModule marker
      | Just name <- T.stripPrefix "__SHAPE__." marker = structuralShapeModule ctx name
      | otherwise = structuralShapeModule ctx (lastSegment marker)

haskellTypeReference :: HaskellSource -> HaskellReference
haskellTypeReference source =
  HaskellReference (hsModule source) (hsType source) TypeNamespace PreferUnqualified

qualifiedValueReference :: QualifiedValueName -> HaskellReference
qualifiedValueReference qualified =
  HaskellReference moduleName valueName ValueNamespace RequireQualified
  where
    (moduleName, valueName) = splitQualified (unQualifiedValueName qualified)

renderReferenceOrDie :: HaskellImportPlan -> HaskellReference -> Text
renderReferenceOrDie importPlan =
  either
    (error . ("validated Haskell reference failed: " <>) . show)
    id
    . renderPlannedReference importPlan

planImportsOrDie :: Text -> Set.Set Text -> Set.Set HaskellReference -> HaskellImportPlan
planImportsOrDie target localDeclarations =
  either
    (error . ("validated Haskell import planning failed: " <>) . show)
    id
    . planHaskellImports
      ImportEnvironment
        { targetModule = target,
          localNames = localDeclarations,
          reservedQualifiers = rendererReservedQualifiers
        }

rendererReservedQualifiers :: Set.Set Text
rendererReservedQualifiers =
  Set.fromList
    [ "Aeson",
      "AesonKey",
      "AesonKeyMap",
      "B",
      "GeneratedNominals",
      "Holes",
      "K",
      "Key",
      "KeyMap",
      "KindID",
      "Map",
      "NominalProjections",
      "NonEmpty",
      "S",
      "Set",
      "StructuralProjections",
      "T"
    ]

splitQualified :: Text -> (Text, Text)
splitQualified value =
  let (prefix, name) = T.breakOnEnd "." value
   in (T.dropEnd 1 prefix, name)

lastSegment :: Text -> Text
lastSegment = snd . T.breakOnEnd "."

-- | Emit all modules for one aggregate. The 'Spec' is needed for the shared
-- id\/enum declarations.
scaffoldAggregate :: Context -> Spec -> Aggregate -> [ScaffoldModule]
scaffoldAggregate ctx spec = scaffoldAggregateForService ctx (legacyCheckedService spec)

-- | Emit all modules for one aggregate after selecting the effective semantic
-- contract. This is the normal source/workspace generation entry point.
scaffoldAggregateForService :: Context -> CheckedService -> Aggregate -> [ScaffoldModule]
scaffoldAggregateForService ctx service agg =
  [ genModule a "Domain" (emitDomain a),
    genModule a "Codec" (emitCodec a)
  ]
    ++ ( if hasVersion2Ownership a
           then
             [ genModule a "Transducer" (emitGeneratedTransducer a),
               genModule a "BehaviorContract" (emitBehaviorContract a),
               behaviorHoleModule a
             ]
           else []
       )
    ++ [ genModule a "EventStream" (emitEventStream a),
         genModule a "Projection" (emitProjection a)
       ]
    ++ [holeModule a (emitHoles a) | aggregateNeedsHoleModule a]
  where
    a = resolveAggForService ctx service agg

aggregateNeedsHoleModule :: Agg -> Bool
aggregateNeedsHoleModule aggregate
  | hasVersion2Ownership aggregate = not (null (version2HoleExports aggregate))
  | otherwise = True

-- | The generated behavioral contract is deliberately separate from both the
-- authoritative transducer and the create-once witness list.  Regeneration can
-- replace this module freely while stale textual keys in @BehaviorHoles@ keep
-- compiling and are reported by reconciliation.
emitBehaviorContract :: Agg -> Text
emitBehaviorContract aggregate =
  nl $
    renderGeneratedLanguagePragmas [ExtOverloadedLabels | not (null (aRegs aggregate))]
      <> [ generatedBanner,
           "module " <> aGenPrefix aggregate <> ".BehaviorContract",
           "  ( BehaviorKey (..)",
           "  , ObligationKind (..)",
           "  , EvidenceLevel (..)",
           "  , GuardCoverage (..)",
           "  , BehaviorRequirement (..)",
           "  , RejectionClass (..)",
           "  , LiveExpectation (..)",
           "  , BehaviorWitness (..)",
           "  , BehaviorFailure (..)",
           "  , BehaviorConformanceReport (..)",
           "  , behaviorRequirements",
           "  , behaviorCoverageReport",
           "  , behaviorConformancePassed",
           "  , behaviorConformancePassedWith",
           "  , renderBehaviorConformanceText",
           "  ) where",
           "",
           "import " <> aGenPrefix aggregate <> ".Codec (encode" <> name <> "Event, parse" <> name <> "Event, " <> valueStem <> "Codec)",
           "import " <> aGenPrefix aggregate <> ".Domain",
           "import " <> aGenPrefix aggregate <> ".Transducer (" <> valueStem <> "Transducer)",
           "import " <> contextGeneratedPrefix (aContext aggregate) <> ".BehaviorSourceMap qualified as BehaviorSourceMap"
         ]
      <> outcomeBehaviorImports
      <> [ "import Data.Aeson (ToJSON (..), object, (.=))",
           "import Data.List (sortOn)",
           "import Data.List.NonEmpty (NonEmpty)",
           "import Data.List.NonEmpty qualified as NonEmpty",
           "import Data.Map.Strict qualified as Map",
           "import Data.Text (Text)",
           "import Data.Text qualified as T",
           "import Keiki.Core qualified as K (" <> T.intercalate ", " behaviorCoreImports <> ")",
           "import Keiro.Codec qualified as Codec (Codec (eventType), EventType (..))",
           "",
           "newtype BehaviorKey = BehaviorKey { unBehaviorKey :: Text }",
           "  deriving stock (Eq, Ord, Show)",
           "",
           "data ObligationKind = LiveTransition | RequiredRejection | ReplayTransition",
           "  deriving stock (Eq, Ord, Show)",
           "",
           "data EvidenceLevel = GeneratedAuthoritative | HoleWitnessed | LegacyRuntimeWitness",
           "  deriving stock (Eq, Ord, Show)",
           "",
           "data GuardCoverage = GuardTotal | GuardPartial | GuardUnknown | GuardNotApplicable",
           "  deriving stock (Eq, Ord, Show)",
           "",
           "data BehaviorRequirement = BehaviorRequirement",
           "  { requirementKey :: !BehaviorKey",
           "  , requirementKind :: !ObligationKind",
           "  , requirementEvidence :: !EvidenceLevel",
           "  , requirementGuardCoverage :: !GuardCoverage",
           "  , requirementSource :: !" <> aVertexType aggregate,
           "  , requirementCommandName :: !Text",
           "  , requirementExpectedEdge :: !(Maybe (K.EdgeRef " <> aVertexType aggregate <> "))",
           "  , requirementTarget :: !(Maybe " <> aVertexType aggregate <> ")",
           "  , requirementEventKinds :: ![Text]",
           "  }",
           "  deriving stock (Eq, Show)",
           "",
           "data RejectionClass = RejectNoOutgoingEdges | RejectNoMatchingEdge",
           "  deriving stock (Eq, Show)",
           "",
           "data LiveExpectation",
           "  = Emits (NonEmpty " <> name <> "Event)",
           "  | Rejects RejectionClass"
         ]
      <> outcomeExpectationConstructors
      <> [ "  | NoOp",
           "  deriving stock (Eq, Show)",
           "",
           "data BehaviorWitness",
           "  = Pending BehaviorKey",
           "  | LiveWitness",
           "      { witnessKey :: BehaviorKey",
           "      , witnessHistory :: [" <> name <> "Event]",
           "      , witnessCommand :: " <> name <> "Command",
           "      , witnessExpected :: LiveExpectation",
           "      }",
           "  | ReplayWitness",
           "      { witnessKey :: BehaviorKey",
           "      , witnessHistoryPrefix :: [" <> name <> "Event]",
           "      , witnessObservedChunk :: [" <> name <> "Event]",
           "      }",
           "  deriving stock (Eq, Show)",
           "",
           "data BehaviorFailure = BehaviorFailure",
           "  { failureKey :: !BehaviorKey",
           "  , failureSubject :: !Text",
           "  , failureCode :: !Text",
           "  , failureDetail :: !Text",
           "  }",
           "  deriving stock (Eq, Show)",
           "",
           "instance ToJSON BehaviorFailure where",
           "  toJSON behaviorFailure = object",
           "    [ \"key\" .= unBehaviorKey (failureKey behaviorFailure)",
           "    , \"subject\" .= failureSubject behaviorFailure",
           "    , \"code\" .= failureCode behaviorFailure",
           "    , \"detail\" .= failureDetail behaviorFailure",
           "    ]",
           "",
           "data BehaviorConformanceReport = BehaviorConformanceReport",
           "  { reportRequired :: ![BehaviorKey]",
           "  , reportFilled :: ![BehaviorKey]",
           "  , reportPending :: ![BehaviorKey]",
           "  , reportMissing :: ![BehaviorKey]",
           "  , reportDuplicate :: ![BehaviorKey]",
           "  , reportStale :: ![BehaviorKey]",
           "  , reportFailed :: ![BehaviorFailure]",
           "  , reportVerified :: ![BehaviorKey]",
           "  , reportUnverified :: ![BehaviorKey]",
           "  }",
           "  deriving stock (Eq, Show)",
           "",
           "instance ToJSON BehaviorConformanceReport where",
           "  toJSON report = object",
           "    [ \"schema\" .= (\"keiro/behavior-conformance/1\" :: Text)",
           "    , \"required\" .= keyTexts (reportRequired report)",
           "    , \"filled\" .= keyTexts (reportFilled report)",
           "    , \"pending\" .= keyTexts (reportPending report)",
           "    , \"missing\" .= keyTexts (reportMissing report)",
           "    , \"duplicate\" .= keyTexts (reportDuplicate report)",
           "    , \"stale\" .= keyTexts (reportStale report)",
           "    , \"failed\" .= reportFailed report",
           "    , \"verified\" .= keyTexts (reportVerified report)",
           "    , \"unverified\" .= keyTexts (reportUnverified report)",
           "    ]",
           "",
           "behaviorRequirements :: [BehaviorRequirement]",
           "behaviorRequirements ="
         ]
      <> renderBehaviorRequirementList aggregate
      <> [ "",
           "behaviorCoverageReport :: [BehaviorWitness] -> BehaviorConformanceReport",
           "behaviorCoverageReport witnesses =",
           "  BehaviorConformanceReport",
           "    { reportRequired = sortedKeys (Map.keys requiredByKey)",
           "    , reportFilled = sortedKeys [key | (key, [witness]) <- Map.toList witnessGroups, Map.member key requiredByKey, not (isPending witness)]",
           "    , reportPending = sortedKeys [key | (key, rows) <- Map.toList witnessGroups, Map.member key requiredByKey, any isPending rows]",
           "    , reportMissing = sortedKeys [key | key <- Map.keys requiredByKey, Map.notMember key witnessGroups]",
           "    , reportDuplicate = sortedKeys [key | (key, rows) <- Map.toList witnessGroups, length rows > 1]",
           "    , reportStale = sortedKeys [key | key <- Map.keys witnessGroups, Map.notMember key requiredByKey]",
           "    , reportFailed = sortOn (unBehaviorKey . failureKey) failures",
           "    , reportVerified = sortedKeys [requirementKey requirement | (requirement, Right ()) <- executions, proofStrength requirement]",
           "    , reportUnverified = sortedKeys [requirementKey requirement | (requirement, Right ()) <- executions, not (proofStrength requirement)]",
           "    }",
           " where",
           "  requiredByKey = Map.fromList [(requirementKey requirement, requirement) | requirement <- behaviorRequirements]",
           "  witnessGroups = Map.fromListWith (flip (<>)) [(behaviorWitnessKey witness, [witness]) | witness <- witnesses]",
           "  executions =",
           "    [ (requirement, runWitness requirement witness)",
           "    | (key, [witness]) <- Map.toList witnessGroups",
           "    , not (isPending witness)",
           "    , Just requirement <- [Map.lookup key requiredByKey]",
           "    ]",
           "  failures = [behaviorFailure | (_, Left behaviorFailure) <- executions]",
           "",
           "behaviorConformancePassed :: BehaviorConformanceReport -> Bool",
           "behaviorConformancePassed = behaviorConformancePassedWith False",
           "",
           "behaviorConformancePassedWith :: Bool -> BehaviorConformanceReport -> Bool",
           "behaviorConformancePassedWith failOnUnverified report =",
           "  null (reportPending report)",
           "    && null (reportMissing report)",
           "    && null (reportDuplicate report)",
           "    && null (reportStale report)",
           "    && null (reportFailed report)",
           "    && (not failOnUnverified || null (reportUnverified report))",
           "",
           "renderBehaviorConformanceText :: BehaviorConformanceReport -> Text",
           "renderBehaviorConformanceText report = T.unlines",
           "  [ \"behavior conformance: " <> name <> "\"",
           "  , \"schema: keiro/behavior-conformance/1\"",
           "  , countLine \"required\" (reportRequired report)",
           "  , countLine \"filled\" (reportFilled report)",
           "  , countLine \"pending\" (reportPending report)",
           "  , countLine \"missing\" (reportMissing report)",
           "  , countLine \"duplicate\" (reportDuplicate report)",
           "  , countLine \"stale\" (reportStale report)",
           "  , \"failed: \" <> tshow (length (reportFailed report))",
           "  , countLine \"verified\" (reportVerified report)",
           "  , countLine \"unverified\" (reportUnverified report)",
           "  ] <> T.unlines [\"FAIL \" <> unBehaviorKey (failureKey behaviorFailure) <> \" \" <> failureSubject behaviorFailure <> \" [\" <> failureCode behaviorFailure <> \"] \" <> failureDetail behaviorFailure | behaviorFailure <- reportFailed report]",
           "",
           "runWitness :: BehaviorRequirement -> BehaviorWitness -> Either BehaviorFailure ()",
           "runWitness requirement witness = case witness of",
           "  Pending _ -> failure requirement \"pending\" \"witness is still Pending\"",
           "  LiveWitness _ history command expectation -> runLive requirement history command expectation",
           "  ReplayWitness _ prefix chunk -> runReplay requirement prefix chunk",
           "",
           "runLive :: BehaviorRequirement -> [" <> name <> "Event] -> " <> name <> "Command -> LiveExpectation -> Either BehaviorFailure ()",
           "runLive requirement history command expectation = do",
           "  settled <- settleHistory requirement \"history\" history",
           "  ensure requirement (K.replaySuccessState settled == requirementSource requirement) \"history-wrong-source\" \"history does not settle at the required source vertex\"",
           "  ensure requirement (commandKind command == requirementCommandName requirement) \"command-mismatch\" \"witness command constructor does not match the required state/command cell\"",
           "  case requirementKind requirement of",
           "    ReplayTransition -> failure requirement \"witness-kind\" \"a replay-only requirement needs ReplayWitness\"",
           "    RequiredRejection -> runRejection requirement (K.replaySuccessState settled, K.replaySuccessRegs settled) command expectation",
           "    LiveTransition -> runAcceptance requirement (K.replaySuccessState settled, K.replaySuccessRegs settled) command expectation",
           "",
           "runRejection :: BehaviorRequirement -> (" <> aVertexType aggregate <> ", K.RegFile " <> name <> "Regs) -> " <> name <> "Command -> LiveExpectation -> Either BehaviorFailure ()",
           "runRejection requirement seed command expectation = case expectation of",
           "  Emits _ -> failure requirement \"expectation-kind\" \"a rejection requirement cannot expect emitted events\""
         ]
      <> outcomeGenericRejectionCases
      <> [ "  NoOp -> failure requirement \"expectation-kind\" \"a rejection requirement cannot expect an accepted no-op\"",
           "  Rejects expectedClass -> case K.stepDetailedEither " <> valueStem <> "Transducer seed command of",
           "    Left K.NoOutgoingEdges {} -> ensure requirement (expectedClass == RejectNoOutgoingEdges) \"rejection-class\" \"expected NoMatchingEdge but runtime returned NoOutgoingEdges\"",
           "    Left K.NoMatchingEdge {} -> ensure requirement (expectedClass == RejectNoMatchingEdge) \"rejection-class\" \"expected NoOutgoingEdges but runtime returned NoMatchingEdge\"",
           "    Left K.AmbiguousEdges {} -> failure requirement \"ambiguous-edges\" \"AmbiguousEdges can never satisfy a rejection witness\"",
           "    Right _ -> failure requirement \"unexpected-acceptance\" \"runtime accepted a command required to reject\"",
           "",
           "runAcceptance :: BehaviorRequirement -> (" <> aVertexType aggregate <> ", K.RegFile " <> name <> "Regs) -> " <> name <> "Command -> LiveExpectation -> Either BehaviorFailure ()",
           "runAcceptance requirement seed command expectation = case expectation of",
           "  Rejects _ -> failure requirement \"expectation-kind\" \"a live-transition requirement needs Emits or NoOp\""
         ]
      <> outcomeExactAcceptanceCases
      <> genericNoOpAcceptanceLines
      <> [ "  Emits expectedEvents -> case K.stepDetailedEither " <> valueStem <> "Transducer seed command of",
           "    Left stepFailure -> failure requirement \"unexpected-rejection\" (tshow stepFailure)",
           "    Right success -> do",
           "      checkAcceptedEnvelope requirement success",
           "      let expected = NonEmpty.toList expectedEvents",
           "          actual = K.stepSuccessOutputs success",
           "      ensure requirement (actual == expected) \"event-value-mismatch\" (\"runtime event values differ from the exact witness expectation; actual=\" <> tshow actual <> \" expected=\" <> tshow expected)",
           "      ensure requirement (map eventKind actual == requirementEventKinds requirement) \"event-envelope-mismatch\" (\"runtime event kinds differ from the declared ordered envelope; actual=\" <> tshow (map eventKind actual) <> \" expected=\" <> tshow (requirementEventKinds requirement))",
           "      decoded <- either (failure requirement \"emitted-codec-decode\") Right (decodeEvents actual)",
           "      replayed <- case K.applyEventsDetailedEither " <> valueStem <> "Transducer seed decoded of",
           "        Left replayFailure -> failure requirement \"emitted-replay-failed\" (tshow replayFailure)",
           "        Right replaySuccess -> Right replaySuccess",
           "      ensure requirement (K.replaySuccessState replayed == K.stepSuccessState success) \"forward-replay-vertex\" \"decoded emissions replay to a different vertex\"",
           "      ensure requirement (regsEqual (K.replaySuccessRegs replayed) (K.stepSuccessRegs success)) \"forward-replay-registers\" \"decoded emissions replay to different registers\"",
           "      checkSingleAttribution requirement K.Live (length decoded) (K.replaySuccessTrace replayed)"
         ]
      <> outcomeSilentRunnerLines
      <> [ "",
           "checkAcceptedEnvelope :: BehaviorRequirement -> K.StepSuccess " <> name <> "Regs " <> aVertexType aggregate <> " " <> name <> "Event -> Either BehaviorFailure ()",
           "checkAcceptedEnvelope requirement success = do",
           "  ensure requirement (K.stepSuccessMode success == K.Live) \"forward-mode\" (\"forward execution selected a non-live edge; actual=\" <> tshow (K.stepSuccessMode success) <> \" expected=\" <> tshow K.Live)",
           "  ensure requirement (Just (K.stepSuccessEdge success) == requirementExpectedEdge requirement) \"edge-attribution\" (\"runtime selected a different guarded sibling; actual=\" <> tshow (Just (K.stepSuccessEdge success)) <> \" expected=\" <> tshow (requirementExpectedEdge requirement))",
           "  ensure requirement (Just (K.stepSuccessState success) == requirementTarget requirement) \"target-mismatch\" (\"runtime reached a different target vertex; actual=\" <> tshow (Just (K.stepSuccessState success)) <> \" expected=\" <> tshow (requirementTarget requirement))",
           "",
           "runReplay :: BehaviorRequirement -> [" <> name <> "Event] -> [" <> name <> "Event] -> Either BehaviorFailure ()",
           "runReplay requirement prefix chunk = case requirementKind requirement of",
           "  ReplayTransition -> do",
           "    settled <- settleHistory requirement \"history-prefix\" prefix",
           "    ensure requirement (K.replaySuccessState settled == requirementSource requirement) \"history-wrong-source\" \"history prefix does not settle at the replay edge source\"",
           "    ensure requirement (not (null chunk)) \"empty-replay-chunk\" \"a replay-only edge has no observable empty chunk\"",
           "    decoded <- either (failure requirement \"replay-chunk-codec-decode\") Right (decodeEvents chunk)",
           "    replayed <- case K.applyEventsDetailedEither " <> valueStem <> "Transducer (K.replaySuccessState settled, K.replaySuccessRegs settled) decoded of",
           "      Left replayFailure -> failure requirement \"replay-chunk-failed\" (tshow replayFailure)",
           "      Right replaySuccess -> Right replaySuccess",
           "    ensure requirement (Just (K.replaySuccessState replayed) == requirementTarget requirement) \"target-mismatch\" (\"replay chunk reached a different target vertex; actual=\" <> tshow (Just (K.replaySuccessState replayed)) <> \" expected=\" <> tshow (requirementTarget requirement))",
           "    checkSingleAttribution requirement K.ReplayOnly (length decoded) (K.replaySuccessTrace replayed)",
           "  _ -> failure requirement \"witness-kind\" \"ReplayWitness supplied for a non-replay requirement\"",
           "",
           "checkSingleAttribution :: BehaviorRequirement -> K.EdgeMode -> Int -> [K.ReplayAttribution " <> aVertexType aggregate <> "] -> Either BehaviorFailure ()",
           "checkSingleAttribution requirement expectedMode eventCount trace = case trace of",
           "  [attribution] -> do",
           "    ensure requirement (Just (K.replayAttributionEdge attribution) == requirementExpectedEdge requirement) \"replay-edge-attribution\" (\"replay selected a different edge; actual=\" <> tshow (Just (K.replayAttributionEdge attribution)) <> \" expected=\" <> tshow (requirementExpectedEdge requirement))",
           "    ensure requirement (K.replayAttributionMode attribution == expectedMode) \"replay-mode-attribution\" (\"replay selected the wrong live/replay-only phase; actual=\" <> tshow (K.replayAttributionMode attribution) <> \" expected=\" <> tshow expectedMode)",
           "    ensure requirement (K.replayAttributionSource attribution == requirementSource requirement) \"replay-source-attribution\" (\"replay attribution starts at the wrong source; actual=\" <> tshow (K.replayAttributionSource attribution) <> \" expected=\" <> tshow (requirementSource requirement))",
           "    ensure requirement (Just (K.replayAttributionTarget attribution) == requirementTarget requirement) \"replay-target-attribution\" (\"replay attribution ends at the wrong target; actual=\" <> tshow (Just (K.replayAttributionTarget attribution)) <> \" expected=\" <> tshow (requirementTarget requirement))",
           "    ensure requirement (K.replayAttributionSpan attribution == K.ReplayEventSpan 0 eventCount) \"replay-span-attribution\" (\"replay attribution did not consume the exact chunk; actual=\" <> tshow (K.replayAttributionSpan attribution) <> \" expected=\" <> tshow (K.ReplayEventSpan 0 eventCount))",
           "  _ -> failure requirement \"replay-trace-cardinality\" \"expected exactly one completed-edge attribution\"",
           "",
           "settleHistory :: BehaviorRequirement -> Text -> [" <> name <> "Event] -> Either BehaviorFailure (K.ReplaySuccess " <> name <> "Regs " <> aVertexType aggregate <> ")",
           "settleHistory requirement label history = do",
           "  decoded <- either (failure requirement (label <> \"-codec-decode\")) Right (decodeEvents history)",
           "  case K.applyEventsDetailedEither " <> valueStem <> "Transducer (" <> initialVertex aggregate <> ", initial" <> name <> "Regs) decoded of",
           "    Left replayFailure -> failure requirement (label <> \"-replay-failed\") (tshow replayFailure)",
           "    Right replaySuccess -> Right replaySuccess",
           "",
           "decodeEvents :: [" <> name <> "Event] -> Either Text [" <> name <> "Event]",
           "decodeEvents = traverse (\\event -> parse" <> name <> "Event (Codec.eventType " <> valueStem <> "Codec event) (encode" <> name <> "Event event))"
         ]
      <> renderCommandKind aggregate
      <> [ "",
           "eventKind :: " <> name <> "Event -> Text",
           "eventKind event = case Codec.eventType " <> valueStem <> "Codec event of Codec.EventType tag -> tag",
           "",
           "regsEqual :: K.RegFile " <> name <> "Regs -> K.RegFile " <> name <> "Regs -> Bool",
           regsEqualityExpression aggregate,
           "",
           "proofStrength :: BehaviorRequirement -> Bool",
           "proofStrength requirement =",
           "  requirementEvidence requirement == GeneratedAuthoritative",
           "    && requirementGuardCoverage requirement `elem` [GuardTotal, GuardNotApplicable]",
           "",
           "behaviorWitnessKey :: BehaviorWitness -> BehaviorKey",
           "behaviorWitnessKey witness = case witness of",
           "  Pending key -> key",
           "  LiveWitness { witnessKey = key } -> key",
           "  ReplayWitness { witnessKey = key } -> key",
           "",
           "isPending :: BehaviorWitness -> Bool",
           "isPending Pending {} = True",
           "isPending _ = False",
           "",
           "ensure :: BehaviorRequirement -> Bool -> Text -> Text -> Either BehaviorFailure ()",
           "ensure requirement condition code detail = if condition then Right () else failure requirement code detail",
           "failure :: BehaviorRequirement -> Text -> Text -> Either BehaviorFailure failed",
           "failure requirement code detail =",
           "  Left",
           "    ( BehaviorFailure",
           "        (requirementKey requirement)",
           "        (tshow (requirementSource requirement) <> \" x \" <> requirementCommandName requirement <> \": \" <> kindPhrase <> \" (\" <> BehaviorSourceMap.renderBehaviorSourceLocation (unBehaviorKey (requirementKey requirement)) <> \")\")",
           "        code",
           "        detail",
           "    )",
           " where",
           "  kindPhrase = case requirementKind requirement of",
           "    LiveTransition -> \"live transition\"",
           "    RequiredRejection -> \"required rejection\"",
           "    ReplayTransition -> \"replay-only transition\"",
           "sortedKeys :: [BehaviorKey] -> [BehaviorKey]",
           "sortedKeys = sortOn unBehaviorKey",
           "keyTexts :: [BehaviorKey] -> [Text]",
           "keyTexts = map unBehaviorKey",
           "countLine :: Text -> [BehaviorKey] -> Text",
           "countLine label values = label <> \": \" <> tshow (length values)",
           "tshow :: Show value => value -> Text",
           "tshow = T.pack . show"
         ]
  where
    name = aName aggregate
    valueStem = lowerFirst name
    handlerName = valueStem <> "DomainCommandHandler"
    outcomeResultTypes = case aDomainOutcomeTypes aggregate of
      Nothing -> []
      Just outcomeTypes -> [resolvedRejectionType outcomeTypes, resolvedNoOpType outcomeTypes]
    outcomeImportPlan = eventStreamImportPlan aggregate outcomeResultTypes []
    outcomeGeneratedNominals = generatedNominalsInTypes outcomeResultTypes
    outcomeBehaviorImports = case aDomainOutcomeTypes aggregate of
      Nothing -> []
      Just _ ->
        ["import " <> aGenPrefix aggregate <> ".EventStream (" <> handlerName <> ")"]
          <> [ "import "
                 <> generatedNominalModule (aContext aggregate)
                 <> " ("
                 <> T.intercalate ", " (map resolvedNominalName (stableNominals outcomeGeneratedNominals))
                 <> ")"
             | not (null outcomeGeneratedNominals)
             ]
          <> T.lines (renderPlannedImports outcomeImportPlan)
          <> ["import Keiro.Command (DomainCommandHandler (..), SilentCommandContext (..), SilentDomainDecision (..))"]
    outcomeExpectationConstructors = case aDomainOutcomeTypes aggregate of
      Nothing -> []
      Just outcomeTypes ->
        [ "  | RejectedWith " <> renderDomainType outcomeImportPlan aggregate (resolvedRejectionType outcomeTypes),
          "  | NoOpWith " <> renderDomainType outcomeImportPlan aggregate (resolvedNoOpType outcomeTypes)
        ]
    outcomeGenericRejectionCases = case aDomainOutcomeTypes aggregate of
      Nothing -> []
      Just _ ->
        [ "  RejectedWith _ -> failure requirement \"expectation-kind\" \"an unmatched-command rejection cannot expect a selected domain rejection\"",
          "  NoOpWith _ -> failure requirement \"expectation-kind\" \"an unmatched-command rejection cannot expect a selected domain no-op\""
        ]
    genericNoOpAcceptanceLines = case aDomainOutcomeTypes aggregate of
      Just _ -> ["  NoOp -> failure requirement \"expectation-kind\" \"an outcome-enabled transition requires RejectedWith or NoOpWith exact reason evidence\""]
      Nothing ->
        [ "  NoOp -> case K.stepDetailedEither " <> valueStem <> "Transducer seed command of",
          "    Left stepFailure -> failure requirement \"unexpected-rejection\" (tshow stepFailure)",
          "    Right success -> do",
          "      checkAcceptedEnvelope requirement success",
          "      ensure requirement (null (K.stepSuccessOutputs success)) \"noop-emitted\" \"NoOp emitted one or more events\"",
          "      ensure requirement (K.stepSuccessState success == fst seed) \"noop-vertex-change\" \"NoOp changed the control vertex\"",
          "      ensure requirement (regsEqual (K.stepSuccessRegs success) (snd seed)) \"noop-register-change\" \"NoOp changed one or more registers\""
        ]
    outcomeExactAcceptanceCases = case aDomainOutcomeTypes aggregate of
      Nothing -> []
      Just _ ->
        [ "  RejectedWith expectedReason -> do",
          "    decision <- runSilentDecision requirement seed command",
          "    case decision of",
          "      SilentRejected actualReason -> ensure requirement (actualReason == expectedReason) \"domain-rejection-reason\" (\"selected rejection reason differs; actual=\" <> tshow actualReason <> \" expected=\" <> tshow expectedReason)",
          "      SilentNoOp actualReason -> failure requirement \"domain-outcome-kind\" (\"expected a selected rejection but classifier returned no-op \" <> tshow actualReason)",
          "  NoOpWith expectedReason -> do",
          "    decision <- runSilentDecision requirement seed command",
          "    case decision of",
          "      SilentRejected actualReason -> failure requirement \"domain-outcome-kind\" (\"expected a selected no-op but classifier returned rejection \" <> tshow actualReason)",
          "      SilentNoOp actualReason -> ensure requirement (actualReason == expectedReason) \"domain-noop-reason\" (\"selected no-op reason differs; actual=\" <> tshow actualReason <> \" expected=\" <> tshow expectedReason)"
        ]
    outcomeSilentRunnerLines = case aDomainOutcomeTypes aggregate of
      Nothing -> []
      Just outcomeTypes ->
        [ "",
          "runSilentDecision",
          "  :: BehaviorRequirement",
          "  -> (" <> aVertexType aggregate <> ", K.RegFile " <> name <> "Regs)",
          "  -> " <> name <> "Command",
          "  -> Either BehaviorFailure (SilentDomainDecision " <> renderDomainType outcomeImportPlan aggregate (resolvedRejectionType outcomeTypes) <> " " <> renderDomainType outcomeImportPlan aggregate (resolvedNoOpType outcomeTypes) <> ")",
          "runSilentDecision requirement seed command = case K.stepDetailedEither " <> valueStem <> "Transducer seed command of",
          "  Left stepFailure -> failure requirement \"unexpected-rejection\" (tshow stepFailure)",
          "  Right success -> do",
          "    checkAcceptedEnvelope requirement success",
          "    ensure requirement (null (K.stepSuccessOutputs success)) \"silent-emitted\" \"typed silent outcome emitted one or more events\"",
          "    ensure requirement (K.stepSuccessState success == fst seed) \"silent-vertex-change\" \"typed silent outcome changed the control vertex\"",
          "    ensure requirement (regsEqual (K.stepSuccessRegs success) (snd seed)) \"silent-register-change\" \"typed silent outcome changed one or more registers\"",
          "    case " <> handlerName <> " of",
          "      DomainCommandHandler _ classify ->",
          "        Right (classify (SilentCommandContext (fst seed) (snd seed) command (K.stepSuccessEdge success)))"
        ]
    behaviorCoreImports =
      [ "EdgeMode (..)",
        "EdgeRef (..)",
        "RegFile",
        "ReplayAttribution (..)",
        "ReplayEventSpan (..)",
        "ReplaySuccess (..)",
        "StepFailure (..)",
        "StepSuccess (..)",
        "applyEventsDetailedEither",
        "stepDetailedEither"
      ]
        <> ["(!)" | not (null (aRegs aggregate))]

renderCommandKind :: Agg -> [Text]
renderCommandKind aggregate = case aCommands aggregate of
  [] -> ["", "commandKind :: " <> aName aggregate <> "Command -> Text", "commandKind _ = \"\""]
  commands ->
    [ "",
      "commandKind :: " <> aName aggregate <> "Command -> Text",
      "commandKind command = case command of"
    ]
      <> ["  " <> rcName command <> " _ -> " <> tshow (rcName command) | command <- commands]

renderBehaviorRequirementList :: Agg -> [Text]
renderBehaviorRequirementList aggregate =
  case behaviorRequirementsFor aggregate of
    [] -> ["  []"]
    requirements ->
      concat
        [ render index requirement
        | (index, requirement) <- zip [0 ..] requirements
        ]
        <> ["  ]"]
  where
    render index requirement =
      [ (if index == (0 :: Int) then "  [ -- " else "  , -- ") <> behaviorRequirementLabel aggregate requirement,
        "    BehaviorRequirement",
        "      { requirementKey = BehaviorKey " <> tshow (Behavior.unBehaviorKey (Behavior.requirementKey requirement)),
        "      , requirementKind = " <> T.pack (show (Behavior.requirementKind requirement)),
        "      , requirementEvidence = " <> T.pack (show (Behavior.requirementEvidence requirement)),
        "      , requirementGuardCoverage = " <> T.pack (show (Behavior.requirementGuardCoverage requirement)),
        "      , requirementSource = " <> vertexCtor aggregate (Behavior.requirementSource requirement),
        "      , requirementCommandName = " <> tshow (Behavior.requirementCommand requirement),
        "      , requirementExpectedEdge = " <> edgeExpr aggregate requirement,
        "      , requirementTarget = " <> maybe "Nothing" (\target -> "Just " <> vertexCtor aggregate target) (Behavior.requirementTarget requirement),
        "      , requirementEventKinds = " <> renderBehaviorTextList (Behavior.requirementEvents requirement),
        "      }"
      ]

behaviorRequirementLabel :: Agg -> Behavior.BehaviorRequirement -> Text
behaviorRequirementLabel aggregate requirement =
  vertexCtor aggregate (Behavior.requirementSource requirement)
    <> " x "
    <> Behavior.requirementCommand requirement
    <> ": "
    <> ( case Behavior.requirementKind requirement of
           Behavior.LiveTransition -> "live transition"
           Behavior.RequiredRejection -> "required rejection"
           Behavior.ReplayTransition -> "replay-only transition"
       )

edgeExpr :: Agg -> Behavior.BehaviorRequirement -> Text
edgeExpr aggregate requirement = case Behavior.requirementKind requirement of
  Behavior.RequiredRejection -> "Nothing"
  _ -> case behaviorEdgeIndex aggregate requirement of
    Nothing -> error ("required behavior transition missing from resolved aggregate: " <> T.unpack (Behavior.requirementCanonical requirement))
    Just edgeIndex ->
      "(Just (K.EdgeRef "
        <> vertexCtor aggregate (Behavior.requirementSource requirement)
        <> " "
        <> tshow' edgeIndex
        <> "))"

behaviorEdgeIndex :: Agg -> Behavior.BehaviorRequirement -> Maybe Int
behaviorEdgeIndex aggregate requirement = case Behavior.requirementOrigin requirement of
  Behavior.RejectionRequirementOrigin {} -> Nothing
  Behavior.TransitionRequirementOrigin originAggregate (SourceIndex.TransitionOrdinal ordinal) -> do
    transition <- case drop ordinal (aTransitions aggregate) of
      candidate : _ -> Just candidate
      [] -> Nothing
    if originAggregate == aName aggregate
      && tSource transition == Behavior.requirementSource requirement
      && tCommand transition == Behavior.requirementCommand requirement
      then
        Just
          ( length
              [ ()
              | candidate <- take ordinal (aTransitions aggregate),
                tSource candidate == tSource transition
              ]
          )
      else Nothing

behaviorRequirementsFor :: Agg -> [Behavior.BehaviorRequirement]
behaviorRequirementsFor aggregate =
  case Behavior.deriveAggregateBehaviorRequirements (aSpec aggregate) (aAggregate aggregate) of
    Left derivationError -> error ("validated aggregate failed behavior derivation: " <> show derivationError)
    Right requirements -> sortOn Behavior.requirementKey requirements

renderBehaviorTextList :: [Text] -> Text
renderBehaviorTextList values = "[" <> T.intercalate ", " (map tshow values) <> "]"

regsEqualityExpression :: Agg -> Text
regsEqualityExpression aggregate = case aRegs aggregate of
  [] -> "regsEqual _ _ = True"
  registers ->
    "regsEqual left right = "
      <> T.intercalate
        " && "
        [ "(left K.! #" <> rrName register <> ") == (right K.! #" <> rrName register <> ")"
        | register <- registers
        ]

behaviorHoleModule :: Agg -> ScaffoldModule
behaviorHoleModule aggregate =
  ScaffoldModule
    { modulePath = T.unpack (T.replace "." "/" (aHolePrefix aggregate) <> "/BehaviorHoles.hs"),
      moduleText = emitBehaviorHoles aggregate,
      kind = HoleStub,
      origin = nodeOrigin "aggregate behavior witnesses" (aName aggregate) (aLoc aggregate)
    }

emitBehaviorHoles :: Agg -> Text
emitBehaviorHoles aggregate =
  nl $
    [ "-- Consumer-owned behavioral witnesses. Created once; never overwritten.",
      "module " <> aHolePrefix aggregate <> ".BehaviorHoles (behaviorWitnesses) where",
      "",
      "import " <> aGenPrefix aggregate <> ".BehaviorContract",
      "",
      "behaviorWitnesses :: [BehaviorWitness]",
      "behaviorWitnesses ="
    ]
      <> case behaviorRequirementsFor aggregate of
        [] -> ["  []"]
        requirements ->
          [ (if index == (0 :: Int) then "  [ " else "  , ")
              <> "Pending (BehaviorKey "
              <> tshow (Behavior.unBehaviorKey (Behavior.requirementKey requirement))
              <> ") -- "
              <> behaviorRequirementLabel aggregate requirement
          | (index, requirement) <- zip [0 ..] requirements
          ]
            <> ["  ]"]

-- | Emit the context-wide replay-audit target assembly.
--
-- There is one existential target per aggregate declaration. Process saga
-- aggregates are ordinary aggregate nodes referenced by 'SagaRef', so they are
-- included by the same single source of truth rather than being duplicated from
-- the process declaration.
scaffoldReplayAudit :: Context -> Spec -> [ScaffoldModule]
scaffoldReplayAudit ctx spec
  | null aggregates = []
  | otherwise =
      [ ScaffoldModule
          { modulePath = T.unpack (T.replace "." "/" moduleName <> ".hs"),
            moduleText = emitReplayAudit,
            kind = Generated,
            origin = "context " <> specContext spec <> " replay-audit assembly"
          }
      ]
  where
    aggregates = [aggregate | NAggregate aggregate <- specNodes spec]
    moduleName = contextGeneratedPrefix ctx <> ".ReplayAudit"
    emitReplayAudit =
      nl $
        renderGeneratedLanguagePragmas []
          <> [ generatedBanner,
               "--",
               "-- Deployment contract:",
               "--   * replay-neutral diff: no data audit is required;",
               "--   * affected diff: run AuditTargeted with the emitted affected set",
               "--     against a production copy under the candidate binary;",
               "--   * one-time runtime cutover: run AuditFull;",
               "--   * any non-zero audit exit blocks deployment.",
               "module " <> moduleName <> " (auditTargets) where",
               ""
             ]
          ++ [ "import " <> genPrefixFor ctx (aggName aggregate) <> ".EventStream qualified as " <> aggName aggregate
             | aggregate <- aggregates
             ]
          ++ [ "import Keiro.ReplayAudit (AuditTarget (..), SomeAuditTarget (..), streamInCategory)",
               "import Keiro.Stream qualified as Stream",
               "",
               "auditTargets :: [SomeAuditTarget]",
               "auditTargets ="
             ]
          ++ concat
            [ [ if index == (0 :: Int) then "  [ SomeAuditTarget" else "  , SomeAuditTarget",
                "      AuditTarget",
                "        { eventStream = " <> aggregateName <> "." <> lowerFirst aggregateName <> "EventStream",
                "        , category = Stream.categoryText " <> aggregateName <> "." <> lowerFirst aggregateName <> "Category",
                "        , mkStream = streamInCategory (Stream.categoryText " <> aggregateName <> "." <> lowerFirst aggregateName <> "Category)",
                "        }"
              ]
            | (index, aggregate) <- zip [0 ..] aggregates,
              let aggregateName = aggName aggregate
            ]
          ++ ["  ]"]

genModule :: Agg -> Text -> Text -> ScaffoldModule
genModule a name body =
  ScaffoldModule
    { modulePath = T.unpack (T.replace "." "/" (aGenPrefix a) <> "/" <> name <> ".hs"),
      moduleText = body,
      kind = Generated,
      origin = nodeOrigin "aggregate" (aName a) (aLoc a)
    }

holeModule :: Agg -> Text -> ScaffoldModule
holeModule a body =
  ScaffoldModule
    { modulePath = T.unpack (T.replace "." "/" (aHolePrefix a) <> "/" <> "Holes.hs"),
      moduleText = body,
      kind = HoleStub,
      origin = nodeOrigin "aggregate" (aName a) (aLoc a)
    }

--------------------------------------------------------------------------------
-- Integration contract (EP-4): a self-contained payload ADT + codec
--------------------------------------------------------------------------------

-- | Emit the deterministic, symbol-free contract layer: a payload ADT
-- (per-event records), the topic constants, the @messageType@ discriminator, and a
-- strict encode\/decode keyed by it. Self-contained (base\/text\/aeson), so it
-- compiles standalone — the cross-service schema both producer and consumer agree
-- on. No keiki symbolic operator (firewall holds).
scaffoldContract :: Context -> ContractNode -> [ScaffoldModule]
scaffoldContract ctx = scaffoldContractWithLanguage ctx (effectiveLanguageContract LegacyUnversioned)

-- | Emit a contract under the checked service's released semantic contract.
-- Language versions 1 through 3 retain the legacy Text representation; only
-- runtime semantics 3 lowers declared TypeID fields to prefix-indexed KindIDs.
scaffoldContractForService :: Context -> CheckedService -> ContractNode -> [ScaffoldModule]
scaffoldContractForService ctx service = scaffoldContractWithLanguage ctx (checkedLanguageContract service)

scaffoldContractWithLanguage :: Context -> EffectiveLanguageContract -> ContractNode -> [ScaffoldModule]
scaffoldContractWithLanguage ctx languageContract c =
  [ ScaffoldModule
      { modulePath = T.unpack (T.replace "." "/" genPrefix <> "/Contract.hs"),
        moduleText = emitContractGen languageContract genPrefix c,
        kind = Generated,
        origin = nodeOrigin "contract" (ctrName c) (ctrLoc c)
      }
  ]
  where
    genPrefix = genPrefixFor ctx (pascal (ctrName c))

emitContractGen :: EffectiveLanguageContract -> Text -> ContractNode -> Text
emitContractGen languageContract genPrefix c =
  ( nl $
      pragmas
        ++ [generatedBanner]
        ++ moduleHeader
        ++ [ "",
             -- A typed-TypeID field decodes through explicitParseField, so a
             -- contract whose every field is one never uses (.:) and would warn
             -- under -Wunused-imports.
             "import Data.Aeson ("
               <> T.intercalate ", " (["Value", "object", "withObject", "withText"] <> ["(.:)" | usesPlainFieldDecode] <> ["(.=)"])
               <> ")",
             aesonTypesImport
           ]
        ++ typedKindIdImports
        ++ [ "import Data.Text (Text)",
             "import qualified Data.Text as T"
           ]
        ++ ["import Keiro.Codec.IdDomain (parseKindIdV7Value)" | hasTypedTypeIds]
        ++ [ "",
             "-- topic constants"
           ]
        ++ topicConstants
        ++ [ "",
             "-- the closed payload set (discriminated by " <> tshow (ctrDiscriminator c) <> ")"
           ]
        ++ [emitPayloadAdt languageContract payloadTy (ctrEvents c)]
        ++ [ "",
             "messageTypeOf :: " <> payloadTy <> " -> Text",
             "messageTypeOf = \\case"
           ]
        ++ ["  " <> ceName e <> " {} -> " <> tshow (ceName e) | e <- ctrEvents c]
        ++ [ "",
             "encode" <> payloadTy <> " :: " <> payloadTy <> " -> Value",
             "encode" <> payloadTy <> " = \\case"
           ]
        ++ concatMap encodeArm (ctrEvents c)
        ++ [ "",
             "parse" <> payloadTy <> " :: Value -> Either Text " <> payloadTy,
             "parse" <> payloadTy <> " = mapLeftText . parseEither (withObject " <> tshow payloadTy <> " go)",
             "  where",
             "    go o = do",
             "      kind <- explicitParseField (withText " <> tshow (ctrDiscriminator c) <> " validateMessageType) o " <> tshow (ctrDiscriminator c),
             "      case kind of"
           ]
        ++ concatMap decodeArm (ctrEvents c)
        ++ [ "        _ -> fail \"validated message type was not handled\"",
             "",
             "mapLeftText :: Either String b -> Either Text b",
             "mapLeftText = either (Left . T.pack) Right",
             "",
             "validateMessageType :: Text -> Parser Text",
             "validateMessageType kind",
             "  | kind `elem` " <> renderTextList (map ceName (ctrEvents c)) <> " = pure kind",
             "  | otherwise = " <> renderUnknownFailure "message type" "kind" (map ceName (ctrEvents c))
           ]
  )
    <> if hasTypedTypeIds then "\n" else ""
  where
    payloadTy = pascal (ctrName c) <> "Payload"
    hasTypedTypeIds = any (any (isTypedTypeId . cfType) . ceFields) (ctrEvents c)
    usesPlainFieldDecode = any (any (not . isTypedTypeId . cfType) . ceFields) (ctrEvents c)
    pragmas =
      renderGeneratedLanguagePragmas
        ( [ExtDuplicateRecordFields | contractNeedsDuplicateRecordFields c]
            <> [ExtOverloadedRecordDot | contractUsesRecordDot c]
        )
    typedKindIdImports
      | hasTypedTypeIds = ["import Data.KindID (KindID)", "import qualified Data.KindID as KindID"]
      | otherwise = []
    moduleHeader =
      [ "module " <> genPrefix <> ".Contract",
        "  ( " <> payloadTy <> " (..)"
      ]
        ++ ["  , " <> ceName event <> "Data (..)" | event <- ctrEvents c]
        ++ ["  , " <> lowerFirst alias <> "Topic" | (alias, _) <- ctrTopics c]
        ++ [ "  , messageTypeOf",
             "  , encode" <> payloadTy,
             "  , parse" <> payloadTy,
             "  ) where"
           ]
    topicConstants
      | hasTypedTypeIds =
          [ T.intercalate
              "\n\n"
              [lowerFirst alias <> "Topic :: Text\n" <> lowerFirst alias <> "Topic = " <> tshow topic | (alias, topic) <- ctrTopics c]
          ]
      | otherwise = [lowerFirst alias <> "Topic :: Text\n" <> lowerFirst alias <> "Topic = " <> tshow topic | (alias, topic) <- ctrTopics c]
    isTypedTypeId (CTypeId prefix) = isJust (contractIdDomainContractFor languageContract prefix)
    isTypedTypeId _ = False
    aesonTypesImport = "import Data.Aeson.Types (Parser, explicitParseField, parseEither)"
    encodeArm e =
      [ "  " <> ceName e <> " payload ->",
        "    object"
      ]
        ++ objectEntriesFor ((tshow (ctrDiscriminator c) <> " .= (" <> tshow (ceName e) <> " :: Text)") : map encodeField (ceFields e))
        ++ ["      ]"]
    lead 0 kv = "      [ " <> kv
    lead _ kv = "      , " <> kv
    objectEntriesFor entries
      | hasTypedTypeIds =
          [ (if index == 0 then "      [ " else "        ")
              <> entry
              <> if index < length entries - 1 then "," else ""
          | (index, entry) <- zip [(0 :: Int) ..] entries
          ]
      | otherwise = [lead index entry | (index, entry) <- zip [(0 :: Int) ..] entries]
    decodeArm e =
      ["        " <> tshow (ceName e) <> " ->"]
        ++ case ceFields e of
          [] -> ["          pure (" <> ceName e <> " " <> ceName e <> "Data)"]
          fields ->
            [ "          " <> ceName e,
              "            <$> ( " <> ceName e <> "Data"
            ]
              ++ [ (if index == 0 then "                    <$> " else "                    <*> ") <> decodeField field
                 | (index, field) <- zip [(0 :: Int) ..] fields
                 ]
              ++ ["                )"]
    encodeField field =
      tshow (fieldWireKey identity)
        <> " .= "
        <> case cfType field of
          CTypeId prefix
            | isJust (contractIdDomainContractFor languageContract prefix) -> "KindID.toText payload." <> fieldSelector identity
          _ -> "payload." <> fieldSelector identity
      where
        identity = resolveContractFieldIdentity field
    decodeField field = case cfType field of
      CTypeId prefix
        | isJust (contractIdDomainContractFor languageContract prefix) ->
            "explicitParseField (parseKindIdV7Value @" <> tshow prefix <> ") o " <> tshow wireKey
      _ -> "o .: " <> tshow wireKey
      where
        wireKey = fieldWireKey (resolveContractFieldIdentity field)

contractNeedsDuplicateRecordFields :: ContractNode -> Bool
contractNeedsDuplicateRecordFields = hasDuplicateNames . concatMap (map (fieldSelector . resolveContractFieldIdentity) . ceFields) . ctrEvents

contractUsesRecordDot :: ContractNode -> Bool
contractUsesRecordDot = any (not . null . ceFields) . ctrEvents

emitPayloadAdt :: EffectiveLanguageContract -> Text -> [ContractEvent] -> Text
emitPayloadAdt languageContract tyName events =
  sectionsOf [map dataRecord events, [sumDecl]]
  where
    hasTypedTypeIds = any (any (isTypedTypeId . cfType) . ceFields) events
    isTypedTypeId (CTypeId prefix) = isJust (contractIdDomainContractFor languageContract prefix)
    isTypedTypeId _ = False
    hsType CText = "Text"
    hsType CInt = "Int"
    hsType (CTypeId prefix)
      | isJust (contractIdDomainContractFor languageContract prefix) = "(KindID " <> tshow prefix <> ")"
      | otherwise = "Text"
    dataRecord e =
      "data "
        <> ceName e
        <> "Data = "
        <> ceName e
        <> (if hasTypedTypeIds then "Data {" else "Data { ")
        <> T.intercalate ", " [fieldSelector (resolveContractFieldIdentity f) <> " :: !" <> hsType (cfType f) | f <- ceFields e]
        <> (if hasTypedTypeIds then "}\n  deriving stock (Eq, Show)" else " }\n  deriving stock (Eq, Show)")
    arm e = ceName e <> " !" <> ceName e <> "Data"
    sumDecl = case events of
      [] -> "data " <> tyName <> " = " <> tyName <> "Empty\n  deriving stock (Eq, Show)"
      (e : es) ->
        nl
          ( (if hasTypedTypeIds then ["data " <> tyName, "  = " <> arm e] else ["data " <> tyName <> " = " <> arm e])
              ++ ["  | " <> arm e2 | e2 <- es]
              ++ ["  deriving stock (Eq, Show)"]
          )

--------------------------------------------------------------------------------
-- Integration intake (EP-4): inbox disposition vs the live Keiro.Inbox runtime
--------------------------------------------------------------------------------

-- | Emit the inbox node's deterministic disposition wiring compiled against the
-- LIVE @Keiro.Inbox.Types@: the dedupe policy (a real 'InboxDedupePolicy') and a
-- disposition function over the real @InboxResult@ (including handler
-- failures). This pins the dangerous inversions
-- (duplicate ⇒ ackOk, previouslyFailed ⇒ deadLetter) as compiled code over the
-- runtime types. The complete declared classification table is also available
-- to handler holes through a closed generated outcome type. Firewall holds (no
-- keiki symbolic operator).
scaffoldIntake :: Context -> IntakeNode -> [ScaffoldModule]
scaffoldIntake ctx i =
  [ ScaffoldModule
      { modulePath = T.unpack (T.replace "." "/" genPrefix <> "/Inbox.hs"),
        moduleText = emitIntakeGen genPrefix i,
        kind = Generated,
        origin = nodeOrigin "intake" (inkName i) (inkLoc i)
      }
  ]
  where
    genPrefix = genPrefixFor ctx (pascal (inkName i))

emitIntakeGen :: Text -> IntakeNode -> Text
emitIntakeGen genPrefix i =
  nl $
    renderGeneratedLanguagePragmas []
      <> [ generatedBanner,
           "module " <> genPrefix <> ".Inbox",
           "  ( InboxFailure (..)",
           "  , " <> outcomeType <> " (..)",
           "  , " <> dispositionType <> " (..)",
           "  , inboxDedupePolicy",
           "  , inboxPersistence",
           "  , inboxDispositionFor",
           "  , inboxDisposition",
           "  ) where",
           "",
           "import Data.Text (Text)",
           "import Keiro.Inbox.Types (InboxDedupePolicy (..), InboxPersistence (..), InboxResult (..), RetryDelay (..))",
           "",
           "-- The dedupe policy (hole-kind 4), lowered to the live InboxDedupePolicy.",
           "inboxDedupePolicy :: InboxDedupePolicy",
           "inboxDedupePolicy = " <> inkDedupePolicy i,
           "",
           "-- | Success-path envelope retention passed to runInboxTransactionWith.",
           "-- Failures always retain their full operator-facing dead-letter envelope.",
           "-- Dedupe-only success rows decode with an empty payload.",
           "inboxPersistence :: InboxPersistence",
           "inboxPersistence = " <> persistenceCtor (inkPersist i),
           "",
           "-- Runtime failure detail retained when the inbox wrapper reports a failed handler attempt.",
           "data InboxFailure = InboxFailure",
           "  { inboxFailureReason :: !Text",
           "  , inboxFailureAttempt :: !(Maybe Int)",
           "  }",
           "  deriving stock (Eq, Show)",
           "",
           "-- Every classification named by the spec. Keeping this closed makes the",
           "-- generated table exhaustive and gives handler holes typed inputs.",
           "data " <> outcomeType,
           "  = " <> T.intercalate "\n  | " outcomeConstructors,
           "  deriving stock (Eq, Show)",
           "",
           "-- The service's declared acknowledgement decision, including its details.",
           "data " <> dispositionType,
           "  = InboxAccept",
           "  | InboxRetryAfter !RetryDelay !(Maybe InboxFailure)",
           "  | InboxDeadLetter !(Maybe Text) !(Maybe InboxFailure)",
           "  deriving stock (Eq, Show)",
           "",
           "-- The complete disposition table (hole-kind 2).",
           "inboxDispositionFor :: " <> outcomeType <> " -> " <> dispositionType,
           "inboxDispositionFor outcome = case outcome of"
         ]
      ++ ["  " <> outcomeConstructor (drOutcome row) <> " -> " <> actionExpression (drAction row) | row <- inkDisposition i]
      ++ [ "",
           "-- Lower the LIVE Keiro.Inbox.Types.InboxResult without an open fallback.",
           "inboxDisposition :: InboxResult a -> " <> dispositionType,
           "inboxDisposition r = case r of",
           "  InboxProcessed _ -> inboxDispositionFor " <> outcomeConstructor "processed",
           "  InboxDuplicate -> inboxDispositionFor " <> outcomeConstructor "duplicate",
           "  InboxInProgress -> inboxDispositionFor " <> outcomeConstructor "inProgress",
           "  InboxPreviouslyFailed failureReason ->",
           "    maybe (inboxDispositionFor " <> outcomeConstructor "previouslyFailed" <> ")",
           "      (\\reason -> attachFailure (InboxFailure reason Nothing) (inboxDispositionFor " <> outcomeConstructor "previouslyFailed" <> "))",
           "      failureReason",
           "  InboxHandlerFailed reason attempts ->",
           "    attachFailure (InboxFailure reason (Just attempts)) (inboxDispositionFor " <> outcomeConstructor "storeFailed" <> ")",
           "",
           "attachFailure :: InboxFailure -> " <> dispositionType <> " -> " <> dispositionType,
           "attachFailure failure disposition = case disposition of",
           "  InboxRetryAfter delay _ -> InboxRetryAfter delay (Just failure)",
           "  InboxDeadLetter reason _ -> InboxDeadLetter reason (Just failure)",
           "  InboxAccept -> InboxAccept"
         ]
  where
    stem = pascal (inkName i)
    outcomeType = stem <> "Outcome"
    dispositionType = stem <> "Disposition"
    outcomeConstructor = (stem <>) . pascal
    outcomeConstructors = map (outcomeConstructor . drOutcome) (inkDisposition i)
    actionExpression IAckOk = "InboxAccept"
    actionExpression (IRetry win) = "InboxRetryAfter (RetryDelay " <> windowText win <> ") Nothing"
    actionExpression (IDeadLetter mr) = "InboxDeadLetter " <> maybe "Nothing" (\reason -> "(Just " <> tshow reason <> ")") mr <> " Nothing"
    persistenceCtor InkPersistFull = "PersistFullEnvelope"
    persistenceCtor InkPersistDedupeOnly = "PersistDedupeOnly"

--------------------------------------------------------------------------------
-- Integration publisher (EP-4): config vs the live Keiro.Outbox runtime
--------------------------------------------------------------------------------

-- | Emit the publisher's at-least-once policy compiled against the LIVE
-- @Keiro.Outbox.Types@: the ordering policy (a real 'OrderingPolicy'), the backoff
-- curve (a real 'BackoffSchedule'), and the max-attempts ceiling. Firewall holds.
scaffoldPublisher :: Context -> PublisherNode -> [ScaffoldModule]
scaffoldPublisher ctx pb =
  [ ScaffoldModule
      { modulePath = T.unpack (T.replace "." "/" genPrefix <> "/Publisher.hs"),
        moduleText = emitPublisherGen genPrefix pb,
        kind = Generated,
        origin = nodeOrigin "publisher" (pubName pb) (pubLoc pb)
      }
  ]
  where
    genPrefix = genPrefixFor ctx (pascal (pubName pb))

emitPublisherGen :: Text -> PublisherNode -> Text
emitPublisherGen genPrefix pb =
  nl
    [ generatedBanner,
      "module " <> genPrefix <> ".Publisher",
      "  ( publisherOrdering",
      "  , publisherBackoff",
      "  , publisherMaxAttempts",
      "  ) where",
      "",
      -- Only an exponential schedule mentions ExponentialBackoffOptions, and an
      -- unconditional import makes a constant-backoff publisher warn under
      -- -Wunused-imports. Generated code compiles under -Werror.
      "import Keiro.Outbox.Types (BackoffSchedule (..), OrderingPolicy (..)"
        <> (if boKind (pubBackoff pb) == "exponential" then ", ExponentialBackoffOptions (..)" else "")
        <> ")",
      "",
      "publisherOrdering :: OrderingPolicy",
      "publisherOrdering = " <> pubOrdering pb,
      "",
      "publisherBackoff :: BackoffSchedule",
      "publisherBackoff = " <> backoffExpr (pubBackoff pb),
      "",
      "publisherMaxAttempts :: Int",
      "publisherMaxAttempts = " <> tshow' (pubMaxAttempts pb)
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

-- | Emit the deterministic, symbol-free pgmq layer: the Job payload record, the
-- field→wire-name JSON codec, and the captured physical\/dlq\/table name constants.
-- Self-contained (base\/text\/aeson). The fan-out body and the raw-SQL dedup
-- predicate are holes (not emitted). Firewall holds.
scaffoldWorkqueue :: Context -> WorkqueueNode -> [ScaffoldModule]
scaffoldWorkqueue ctx w =
  scaffoldWorkqueueWithQueueText ctx w (emitWorkqueueGen genPrefix w)
  where
    genPrefix = genPrefixFor ctx (pascal (wqName w))

-- | Service-aware workqueue generation resolves candidate type expressions
-- against the checked graph. Legacy scalar workqueues deliberately stay on
-- 'emitWorkqueueGen' so their generated bytes cannot drift.
scaffoldWorkqueueForService :: Context -> CheckedService -> WorkqueueNode -> [ScaffoldModule]
scaffoldWorkqueueForService ctx service workqueue =
  scaffoldWorkqueueWithQueueText ctx workqueue queueText
  where
    genPrefix = genPrefixFor ctx (pascal (wqName workqueue))
    queueText
      | any isTypedQueueField (wqPayload workqueue) =
          case resolveTypeGraph (checkedSpec service) of
            Left errors -> error ("checked workqueue type graph failed: " <> show errors)
            Right graph -> emitMappedWorkqueueGen ctx genPrefix graph workqueue
      | otherwise = emitWorkqueueGen genPrefix workqueue

scaffoldWorkqueueWithQueueText :: Context -> WorkqueueNode -> Text -> [ScaffoldModule]
scaffoldWorkqueueWithQueueText ctx w queueText =
  [ ScaffoldModule
      { modulePath = T.unpack (T.replace "." "/" genPrefix <> "/Queue.hs"),
        moduleText = queueText,
        kind = Generated,
        origin = nodeOrigin "workqueue" (wqName w) (wqLoc w)
      },
    ScaffoldModule
      { modulePath = T.unpack (T.replace "." "/" genPrefix <> "/QueuePolicy.hs"),
        moduleText = emitQueuePolicy genPrefix w,
        kind = Generated,
        origin = nodeOrigin "workqueue" (wqName w) (wqLoc w)
      },
    ScaffoldModule
      { modulePath = T.unpack (T.replace "." "/" genPrefix <> "/QueueCodec.hs"),
        moduleText = emitQueueCodec genPrefix w,
        kind = Generated,
        origin = nodeOrigin "workqueue" (wqName w) (wqLoc w)
      }
  ]
  where
    genPrefix = genPrefixFor ctx (pascal (wqName w))

isTypedQueueField :: WqField -> Bool
isTypedQueueField field = case wqfType field of
  LegacyQueueScalar {} -> False
  TypedQueueExpression {} -> True

emitWorkqueueGen :: Text -> WorkqueueNode -> Text
emitWorkqueueGen genPrefix w =
  nl $
    renderGeneratedLanguagePragmas [ExtOverloadedRecordDot | workqueueUsesRecordDot w]
      <> [ generatedBanner,
           "module " <> genPrefix <> ".Queue",
           "  ( " <> payloadTy <> " (..)",
           "  , encode" <> payloadTy,
           "  , parse" <> payloadTy,
           "  , queuePhysical, queueDlq, queueTable",
           groupKeyExport,
           "  ) where",
           "",
           "import Data.Aeson (Value, object, withObject, (.:), (.=))",
           "import Data.Aeson.Types (parseEither)",
           "import Data.Text (Text)",
           "import qualified Data.Text as T",
           "",
           "queuePhysical, queueDlq, queueTable :: Text",
           "queuePhysical = " <> tshow (wqPhysical w),
           "queueDlq = " <> tshow (wqDlq w),
           "queueTable = " <> tshow (wqTable w),
           ""
         ]
      ++ groupKeyLines
      ++ [ "data " <> payloadTy <> " = " <> payloadTy,
           "  { " <> T.intercalate "\n  , " [wqfName f <> " :: !" <> payloadFieldType f | f <- wqPayload w],
           "  }",
           "  deriving stock (Eq, Show)",
           "",
           "encode" <> payloadTy <> " :: " <> payloadTy <> " -> Value",
           "encode" <> payloadTy <> " p =",
           "  object"
         ]
      ++ [lead i (tshow (wqfWire f) <> " .= p." <> wqfName f) | (i, f) <- zip [(0 :: Int) ..] (wqPayload w)]
      ++ [ "    ]",
           "",
           "parse" <> payloadTy <> " :: Value -> Either Text " <> payloadTy,
           "parse" <> payloadTy <> " = mapLeftText . parseEither (withObject " <> tshow payloadTy <> " go)",
           "  where",
           "    go o = " <> payloadTy <> fieldApps (wqPayload w),
           "",
           "mapLeftText :: Either String b -> Either Text b",
           "mapLeftText = either (Left . T.pack) Right"
         ]
  where
    payloadTy = wqPayloadName w
    payloadFieldType field = case wqfType field of
      LegacyQueueScalar scalar -> hsType (queueScalarName scalar)
      TypedQueueExpression _ -> error "keiro-dsl internal invariant: mapped queue lowering is pending"
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
            [ "groupKeyField :: Text",
              "groupKeyField = " <> tshow (gkField groupKey),
              ""
            ]
          derivationLines key
            | gkVia key == "raw" =
                [ "groupKeyFor :: " <> payloadTy <> " -> Text",
                  "groupKeyFor payload = payload." <> gkField key,
                  ""
                ]
            | otherwise =
                [ "-- Opaque group-key derivation '" <> gkVia key <> "' remains hand-owned.",
                  "-- Captured fixture: " <> fromMaybe "<missing>" (gkFixture key),
                  ""
                ]
    hsType "bool" = "Bool"
    hsType "int" = "Int"
    hsType _ = "Text"
    lead 0 kv = "    [ " <> kv
    lead _ kv = "    , " <> kv
    fieldApps [] = ""
    fieldApps fs = " <$> " <> T.intercalate " <*> " ["o .: " <> tshow (wqfWire f) | f <- fs]

data ResolvedQueueField = ResolvedQueueField
  { resolvedQueueField :: !WqField,
    resolvedQueueExpression :: !(Maybe ResolvedTypeExpr),
    resolvedQueueCodecPlan :: !(Maybe MappedCodecPlan)
  }

emitMappedWorkqueueGen :: Context -> Text -> TypeGraph -> WorkqueueNode -> Text
emitMappedWorkqueueGen ctx genPrefix graph workqueue =
  nl $
    renderGeneratedLanguagePragmas [ExtOverloadedRecordDot | workqueueUsesRecordDot workqueue]
      <> [ generatedBanner,
           "module " <> genPrefix <> ".Queue",
           "  ( " <> payloadType <> " (..)",
           "  , encode" <> payloadType,
           "  , parse" <> payloadType
         ]
      <> concatMap mappedCodecExports structuralDeclarations
      <> [ "  , queuePhysical, queueDlq, queueTable",
           groupKeyExport,
           "  ) where",
           ""
         ]
      <> mappedQueueImports
      <> [ "",
           "queuePhysical, queueDlq, queueTable :: Text",
           "queuePhysical = " <> tshow (wqPhysical workqueue),
           "queueDlq = " <> tshow (wqDlq workqueue),
           "queueTable = " <> tshow (wqTable workqueue),
           ""
         ]
      <> groupKeyLines
      <> [ "data " <> payloadType <> " = " <> payloadType,
           "  { " <> T.intercalate "\n  , " [wqfName raw <> " :: " <> strictQueueFieldType (queueFieldType field) | field@ResolvedQueueField {resolvedQueueField = raw} <- fields],
           "  }",
           "  deriving stock (Eq, Show)",
           ""
         ]
      <> (if hasStructural then [T.intercalate "\n\n" [emitStructuralCodec importPlan ctx graph declaration shape | ResolvedStructural declaration shape <- declarations], ""] else [])
      <> [ "encode" <> payloadType <> " :: " <> payloadType <> " -> Value",
           "encode" <> payloadType <> " payload =",
           "  object"
         ]
      <> [queueLead index (tshow (wqfWire raw) <> " .= " <> encodeQueueField field) | (index, field@ResolvedQueueField {resolvedQueueField = raw}) <- zip [(0 :: Int) ..] fields]
      <> [ "    ]",
           "",
           "parse" <> payloadType <> " :: Value -> Either Text " <> payloadType,
           "parse" <> payloadType <> " = mapLeftText . parseEither (withObject " <> tshow payloadType <> " go)",
           "  where",
           "    go objectValue = " <> payloadType <> queueFieldApplications fields,
           "",
           "mapLeftText :: Either String b -> Either Text b",
           "mapLeftText = either (Left . T.pack) Right"
         ]
      <> optionalFieldHelper
      <> unknownFieldHelper
  where
    payloadType = wqPayloadName workqueue
    fields = map resolveField (wqPayload workqueue)
    resolveField raw = case wqfType raw of
      LegacyQueueScalar {} -> ResolvedQueueField raw Nothing Nothing
      TypedQueueExpression expression ->
        case resolveTypeExpression graph owner (wqfLoc raw) expression of
          Left failure -> error ("checked queue expression failed: " <> show failure)
          Right resolved ->
            ResolvedQueueField raw (Just resolved) (Just (mappedCodecPlanOrDie graph resolved))
      where
        owner = "workqueue '" <> wqName workqueue <> "' payload field '" <> wqfName raw <> "'"
    plans = [plan | ResolvedQueueField {resolvedQueueCodecPlan = Just plan} <- fields]
    rootExpressions = [expression | ResolvedQueueField {resolvedQueueExpression = Just expression} <- fields]
    selectedKeys = Set.unions (map (dependencies . consumerType) plans)
    declarations = mapMaybe (`Map.lookup` tgDeclarations graph) (Set.toAscList selectedKeys)
    structuralDeclarations = [(declaration, shape) | ResolvedStructural declaration shape <- declarations]
    mappedCodecExports (declaration, _) =
      [ "  , encode" <> sdName declaration <> "Mapped",
        "  , decode" <> sdName declaration <> "Mapped"
      ]
    hasStructural = not (null structuralDeclarations)
    allExpressions = rootExpressions <> concatMap (shapeTypeExpressions . snd) structuralDeclarations
    importsPlanReferences =
      Set.unions (map (consumerTypeReferences . consumerType) plans)
        <> Set.fromList
          [ reference
          | (declaration, shape) <- structuralDeclarations,
            reference <-
              haskellTypeReference (sdHaskell declaration)
                : qualifiedValueReference (sdBinding declaration)
                : structuralShapeReferences ctx declaration shape
          ]
    importPlan =
      planImportsOrDie
        (genPrefix <> ".Queue")
        (Set.singleton payloadType)
        importsPlanReferences
    plannedModules = Set.map referenceModule importsPlanReferences
    opaqueInstanceImports =
      sort . nub $
        [ hsModule (odHaskell declaration) <> " ()"
        | ResolvedOpaque declaration <- declarations,
          Set.notMember (hsModule (odHaskell declaration)) plannedModules
        ]
    usesMap = any typeUsesMap allExpressions
    usesOptionalValue = any typeUsesOptional allExpressions
    usesNatural = any typeUsesNatural rootExpressions
    usesTime = any typeUsesTime rootExpressions
    usesParseJson = any (typeUsesParseJson graph) allExpressions
    usesToJson = any (typeUsesToJson graph) allExpressions
    usesValueConstructors = usesOptionalValue || any isEnumShape (map snd structuralDeclarations)
    usesWithText = any isTextShape (map snd structuralDeclarations)
    usesUnknownRejection = any rejectsUnknown (map snd structuralDeclarations)
    usesOptionalField = any hasOptionalField (map snd structuralDeclarations)
    usesKeyMap = usesUnknownRejection || usesOptionalField
    usesParser = hasStructural || any typeUsesParserAnnotation allExpressions
    usesLegacyDecoder = any isLegacy fields
    mappedQueueImports =
      ["import Control.Monad (unless)" | usesUnknownRejection]
        <> ["import Data.Aeson (" <> T.intercalate ", " aesonImports <> ")"]
        <> ["import Data.Aeson.Key qualified as Key" | usesKeyMap]
        <> ["import Data.Aeson.KeyMap qualified as KeyMap" | usesKeyMap]
        <> ["import Data.Aeson.Types (" <> T.intercalate ", " aesonTypesImports <> ")"]
        <> (if usesMap then ["import Data.Map.Strict (Map)", "import Data.Map.Strict qualified as Map"] else [])
        <> ["import Numeric.Natural (Natural)" | usesNatural]
        <> ["import Data.Time (UTCTime)" | usesTime]
        <> [ "import Data.Text (Text)",
             "import qualified Data.Text as T"
           ]
        <> ["import Keiro.Codec.Structural (bindingFromShape, bindingToShape)" | hasStructural]
        <> map ("import " <>) opaqueInstanceImports
        <> T.lines (renderPlannedImports importPlan)
    aesonImports =
      [if usesValueConstructors then "Value (..)" else "Value", "object"]
        <> ["parseJSON" | usesParseJson]
        <> ["toJSON" | usesToJson]
        <> ["withObject"]
        <> ["withText" | usesWithText]
        <> ["(.:)" | usesLegacyDecoder]
        <> ["(.=)"]
    aesonTypesImports =
      ["Parser" | usesParser]
        <> ["explicitParseField", "parseEither"]
    queueFieldType ResolvedQueueField {resolvedQueueField = raw, resolvedQueueExpression = Nothing} = legacyQueueType raw
    queueFieldType ResolvedQueueField {resolvedQueueExpression = Just expression} =
      unHaskellTypeOccurrence $
        either
          (error . ("validated queue consumer type rendering failed: " <>) . show)
          id
          (renderConsumerType importPlan graph expression)
    strictQueueFieldType rendered
      | T.any (== ' ') rendered && not ("[" `T.isPrefixOf` rendered) = "!(" <> rendered <> ")"
      | otherwise = "!" <> rendered
    legacyQueueType raw = case wqfType raw of
      LegacyQueueScalar scalar -> case queueScalarName scalar of
        "bool" -> "Bool"
        "int" -> "Int"
        _ -> "Text"
      TypedQueueExpression {} -> error "typed queue field reached legacy type rendering"
    encodeQueueField ResolvedQueueField {resolvedQueueField = raw, resolvedQueueCodecPlan = Nothing} = "payload." <> wqfName raw
    encodeQueueField ResolvedQueueField {resolvedQueueField = raw, resolvedQueueCodecPlan = Just plan} =
      renderMappedEncode graph ConsumerValueBoundary plan ("payload." <> wqfName raw)
    decodeQueueField ResolvedQueueField {resolvedQueueField = raw, resolvedQueueCodecPlan = Nothing} =
      "objectValue .: " <> tshow (wqfWire raw)
    decodeQueueField ResolvedQueueField {resolvedQueueField = raw, resolvedQueueCodecPlan = Just plan} =
      "explicitParseField ("
        <> renderMappedParse graph ConsumerValueBoundary plan
        <> ") objectValue "
        <> tshow (wqfWire raw)
    queueFieldApplications [] = ""
    queueFieldApplications values = " <$> " <> T.intercalate " <*> " (map decodeQueueField values)
    groupKeyExport = case wqGroupKey workqueue of
      Nothing -> ""
      Just groupKey
        | gkVia groupKey == "raw" -> "  , groupKeyField, groupKeyFor"
        | otherwise -> "  , groupKeyField"
    groupKeyLines = case wqGroupKey workqueue of
      Nothing -> []
      Just groupKey ->
        [ "groupKeyField :: Text",
          "groupKeyField = " <> tshow (gkField groupKey),
          ""
        ]
          <> if gkVia groupKey == "raw"
            then
              [ "groupKeyFor :: " <> payloadType <> " -> Text",
                "groupKeyFor payload = payload." <> gkField groupKey,
                ""
              ]
            else
              [ "-- Opaque group-key derivation '" <> gkVia groupKey <> "' remains hand-owned.",
                "-- Captured fixture: " <> fromMaybe "<missing>" (gkFixture groupKey),
                ""
              ]
    optionalFieldHelper =
      if usesOptionalField
        then
          [ "",
            "parseOptionalField :: Parser fieldValue -> (Value -> Parser fieldValue) -> KeyMap.KeyMap Value -> Key.Key -> Parser fieldValue",
            "parseOptionalField onMissing parseItem objectValue key =",
            "  case KeyMap.lookup key objectValue of",
            "    Nothing -> onMissing",
            "    Just _ -> explicitParseField parseItem objectValue key"
          ]
        else []
    unknownFieldHelper =
      if usesUnknownRejection
        then
          [ "",
            "rejectUnknownFields :: String -> [Text] -> KeyMap.KeyMap Value -> Parser ()",
            "rejectUnknownFields label allowed objectValue =",
            "  unless (null extras) (fail (label <> \" contains unknown fields: \" <> show extras))",
            "  where",
            "    extras = filter (`notElem` allowed) (map Key.toText (KeyMap.keys objectValue))"
          ]
        else []
    isLegacy ResolvedQueueField {resolvedQueueCodecPlan = Nothing} = True
    isLegacy ResolvedQueueField {resolvedQueueCodecPlan = Just _} = False
    isEnumShape REnum {} = True
    isEnumShape _ = False
    isTextShape REnum {} = True
    isTextShape RUnion {} = True
    isTextShape _ = False
    rejectsUnknown (RRecord _ RejectUnknown _) = True
    rejectsUnknown (RUnion encoding _) = ueUnknownFields encoding == RejectUnknown
    rejectsUnknown _ = False
    hasOptionalField (RRecord _ _ shapeFields) = any ((== POptional) . rwfPresence) shapeFields
    hasOptionalField _ = False

queueLead :: Int -> Text -> Text
queueLead 0 keyValue = "    [ " <> keyValue
queueLead _ keyValue = "    , " <> keyValue

typeUsesNatural :: ResolvedTypeExpr -> Bool
typeUsesNatural = foldTypeExpr (falseAlgebra {onNatural = True})
  where
    falseAlgebra = TypeExprAlgebra False False False False False False False id id id (const False)

typeUsesTime :: ResolvedTypeExpr -> Bool
typeUsesTime = foldTypeExpr (falseAlgebra {onTime = True})
  where
    falseAlgebra = TypeExprAlgebra False False False False False False False id id id (const False)

typeUsesText :: ResolvedTypeExpr -> Bool
typeUsesText = foldTypeExpr (falseAlgebra {onText = True, onMap = const True})
  where
    falseAlgebra = TypeExprAlgebra False False False False False False False id id id (const False)

typeUsesJson :: ResolvedTypeExpr -> Bool
typeUsesJson = foldTypeExpr (falseAlgebra {onJson = True})
  where
    falseAlgebra = TypeExprAlgebra False False False False False False False id id id (const False)

typeUsesParserAnnotation :: ResolvedTypeExpr -> Bool
typeUsesParserAnnotation = foldTypeExpr (falseAlgebra {onList = const True, onMap = const True})
  where
    falseAlgebra = TypeExprAlgebra False False False False False False False id id id (const False)

typeUsesParseJson :: TypeGraph -> ResolvedTypeExpr -> Bool
typeUsesParseJson graph =
  foldTypeExpr
    TypeExprAlgebra
      { onText = True,
        onInt = True,
        onInteger = True,
        onBool = True,
        onNatural = True,
        onTime = True,
        onJson = False,
        onOptional = id,
        onList = const True,
        onMap = const True,
        onRef = \key -> case Map.lookup key (tgDeclarations graph) of
          Just ResolvedOpaque {} -> True
          _ -> False
      }

typeUsesToJson :: TypeGraph -> ResolvedTypeExpr -> Bool
typeUsesToJson = typeUsesParseJson

workqueueUsesRecordDot :: WorkqueueNode -> Bool
workqueueUsesRecordDot workqueue =
  not (null (wqPayload workqueue))
    || maybe False ((== "raw") . gkVia) (wqGroupKey workqueue)

-- | Emit the versioned PGMQ envelope adapter.  The payload record remains
-- symbol-free and dependency-light in Queue.hs; this runtime-facing module is
-- the opt-in assembly point applications import into their Job values.
emitQueueCodec :: Text -> WorkqueueNode -> Text
emitQueueCodec genPrefix w =
  nl
    [ generatedBanner,
      "-- | Versioned job payload envelope: @{\\\"v\\\",\\\"t\\\",\\\"data\\\"}@.",
      "--",
      "-- Deploy workers before producers when raising its schema version. Do not",
      "-- adopt this codec on a non-empty bare-payload queue without draining it",
      "-- (or supplying a transitional codec), or in-flight messages will",
      "-- dead-letter. This is telemetry-neutral:",
      "-- docs/adr/0001-keiro-pgmq-job-processing-telemetry-contract.md owns",
      "-- spans and acknowledgement vocabulary.",
      "module " <> genPrefix <> ".QueueCodec (" <> stem <> "PayloadCodec, " <> stem <> "JobCodec) where",
      "",
      "import Data.List.NonEmpty (NonEmpty (..))",
      "import Keiro.Codec (Codec (..), EventType (..))",
      "import Keiro.PGMQ.Codec (JobCodec, keiroJobCodec)",
      "import " <> genPrefix <> ".Queue (" <> payloadTy <> ", encode" <> payloadTy <> ", parse" <> payloadTy <> ")",
      "",
      stem <> "PayloadCodec :: Codec " <> payloadTy,
      stem <> "PayloadCodec =",
      "  Codec",
      "    { eventTypes = EventType " <> tshow payloadTy <> " :| []",
      "    , eventType = \\_ -> EventType " <> tshow payloadTy,
      "    , schemaVersion = 1",
      "    , encode = encode" <> payloadTy,
      "    , decode = \\_ -> parse" <> payloadTy,
      "    , upcasters = []",
      "    }",
      "",
      stem <> "JobCodec :: JobCodec " <> payloadTy,
      stem <> "JobCodec = keiroJobCodec " <> stem <> "PayloadCodec"
    ]
  where
    payloadTy = wqPayloadName w
    stem = lowerFirst (T.concat (map pascal (T.splitOn "_" (wqName w))))

-- | Emit the pgmq retry policy + JobOutcome disposition compiled against the
-- LIVE @Keiro.PGMQ.Job@ runtime (RetryPolicy / JobOutcome / RetryDelay). This pins
-- the dangerous inversions over the runtime types: storeFailure ⇒ Retry (transient)
-- and decodeFailure ⇒ Dead (poison).
emitQueuePolicy :: Text -> WorkqueueNode -> Text
emitQueuePolicy genPrefix w =
  nl $
    [ generatedBanner,
      "module " <> genPrefix <> ".QueuePolicy",
      "  ( " <> outcomeType <> " (..)",
      "  , retryPolicy, jobOutcomeFor",
      "  , jobOrdering, jobTuningFor, queueProvision",
      "  ) where",
      "",
      "import Keiro.PGMQ.Job (" <> T.intercalate ", " queuePolicyImports <> ")",
      "",
      "jobOrdering :: JobOrdering",
      "jobOrdering = " <> orderingCtor,
      "",
      "-- Deployment owns visibility timeout, batch size, and polling; the spec owns ordering.",
      "jobTuningFor :: JobTuning -> JobTuning",
      "jobTuningFor = withOrdering jobOrdering",
      "",
      "-- Pass this to ensureJobQueueWith at worker startup. FIFO adds the required GIN index; the DLQ remains standard.",
      "queueProvision :: QueueProvision",
      "queueProvision = " <> provisionExpr,
      "",
      "retryPolicy :: RetryPolicy",
      "retryPolicy =",
      "  RetryPolicy",
      "    { maxRetries = " <> tshow' (wqMaxRetries w),
      "    , defaultRetryDelay = RetryDelay " <> windowText (wqDelay w),
      "    , useDeadLetter = " <> (if wqDlqOn w then "True" else "False"),
      "    }",
      "",
      "-- The consumer JobOutcome disposition over the spec's named domain outcomes,",
      "-- lowered to the live Keiro.PGMQ.Job.JobOutcome.",
      "data " <> outcomeType,
      "  = " <> T.intercalate "\n  | " (map (pascal . wqdOutcome) (wqDisposition w)),
      "  deriving stock (Eq, Show)",
      "",
      "jobOutcomeFor :: " <> outcomeType <> " -> JobOutcome",
      "jobOutcomeFor o = case o of"
    ]
      ++ ["  " <> pascal (wqdOutcome r) <> " -> " <> outcome (wqdAction r) | r <- wqDisposition w]
  where
    outcomeType = T.concat (map pascal (T.splitOn "_" (wqName w))) <> "Outcome"
    queuePolicyImports =
      [ "JobOrdering (..)",
        "JobOutcome (..)",
        "JobTuning",
        "QueueProvision",
        "RetryDelay (..)",
        "RetryPolicy (..)"
      ]
        <> ( case wqProvision w of
               WqStandard -> ["standardProvision"]
               WqUnlogged -> ["unloggedProvision"]
               WqPartitioned {} -> ["PartitionSpec (..)", "partitionedProvision"]
           )
        <> ["withFifoIndexProvision" | wqOrdering w /= WqUnordered]
        <> ["withOrdering"]
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

-- | Emit an acyclic three-module read-model vertical. @ReadModelTable@ owns the
-- qualified-table constant shared by the hand-owned query and the generated
-- runtime record; @ReadModel@ re-exports it as part of the public surface.
scaffoldReadModel :: Context -> ReadModelNode -> [ScaffoldModule]
scaffoldReadModel ctx readModel =
  [ generated "ReadModelTable" (emitReadModelTable tableModule stem readModel),
    generated "ReadModel" (emitReadModelGen ctx readModelModule tableModule readModelHolePrefix stem readModel),
    ScaffoldModule
      { modulePath = modulePathFor readModelHolePrefix "ReadModelHoles",
        moduleText = emitReadModelHoles tableModule readModelHolePrefix stem readModel,
        kind = HoleStub,
        origin = readModelOrigin
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
        { modulePath = modulePathFor readModelModule leaf,
          moduleText = body,
          kind = Generated,
          origin = readModelOrigin
        }

-- | Service-aware read-model generation adds a generated query contract only
-- for the candidate typed query pair. Legacy read models stay on
-- 'scaffoldReadModel' so their generated and create-once bytes remain exact.
scaffoldReadModelForService :: Context -> CheckedService -> ReadModelNode -> [ScaffoldModule]
scaffoldReadModelForService ctx service readModel = case queryTypes readModel of
  Nothing -> scaffoldReadModel ctx readModel
  Just queryPair ->
    [ generated "ReadModelTable" (emitReadModelTable tableModule stem readModel),
      generated "QueryContract" (emitReadModelQueryContract queryContractModule graph stem readModel queryPair),
      generated "ReadModel" (emitReadModelGenWithContract ctx readModelModule tableModule readModelHolePrefix (Just queryContractModule) stem readModel),
      ScaffoldModule
        { modulePath = modulePathFor readModelHolePrefix "ReadModelHoles",
          moduleText = emitTypedReadModelHoles tableModule queryContractModule readModelHolePrefix stem readModel,
          kind = HoleStub,
          origin = readModelOrigin
        }
    ]
  where
    nodeSegment = pascal (rmName readModel)
    stem = readModelStem readModel
    readModelModule = genPrefixFor ctx nodeSegment
    tableModule = readModelModule <> ".ReadModelTable"
    queryContractModule = readModelModule <> ".QueryContract"
    readModelHolePrefix = holePrefixFor ctx nodeSegment
    readModelOrigin = nodeOrigin "readmodel" (rmName readModel) (rmLoc readModel)
    graph = case resolveTypeGraph (checkedSpec service) of
      Left errors -> error ("checked read-model type graph failed: " <> show errors)
      Right value -> value
    generated leaf body =
      ScaffoldModule
        { modulePath = modulePathFor readModelModule leaf,
          moduleText = body,
          kind = Generated,
          origin = readModelOrigin
        }

-- | Generate one service-level catalog facade and one create-once module that
-- owns application handler/decoder bodies. The checked DSL graph owns every
-- identity and relationship; the hole supplies only executable projection
-- sets, never a second inventory.
scaffoldProjectionCatalog :: Context -> Spec -> [ScaffoldModule]
scaffoldProjectionCatalog ctx spec
  | null catalogNodes = []
  | otherwise =
      [ ScaffoldModule
          { modulePath = modulePathFor (contextGeneratedPrefix ctx) "ProjectionCatalog",
            moduleText = emitProjectionCatalog ctx spec,
            kind = Generated,
            origin = "projection-catalog " <> contextName ctx
          },
        ScaffoldModule
          { modulePath = modulePathFor (holePrefixFor ctx "ProjectionCatalog") "ProjectionCatalogHoles",
            moduleText = emitProjectionCatalogHoles ctx owners,
            kind = HoleStub,
            origin = "projection-catalog " <> contextName ctx
          }
      ]
  where
    catalogNodes = [() | node <- specNodes spec, isCatalogNode node]
    owners = sortOn poOrder [owner | NProjectionOwner owner <- specNodes spec]
    isCatalogNode NProjectionTarget {} = True
    isCatalogNode NRebuildGroup {} = True
    isCatalogNode NProjectionOwner {} = True
    isCatalogNode _ = False

emitProjectionCatalog :: Context -> Spec -> Text
emitProjectionCatalog ctx spec =
  nl $
    [ generatedBanner,
      "{-# LANGUAGE OverloadedStrings #-}",
      "module " <> moduleName,
      "  ( projectionCatalog",
      "  , validatedProjectionCatalog",
      "  , projectionCatalogInventory",
      "  , projectionCatalogRegistrations",
      "  , projectionCatalogAsyncRegistrations",
      "  , registerProjectionCatalog"
    ]
      ++ map (("  , " <>) . ownerSetName) owners
      ++ map (("  , " <>) . ownerInlineViewName) inlineOwners
      ++ concatMap groupExports groups
      ++ [ "  ) where",
           "",
           "import Data.List.NonEmpty (NonEmpty (..))",
           "import Effectful (Eff, IOE, (:>))"
         ]
      ++ concatMap aggregateImports aggregateSources
      ++ projectionImports
      ++ [ "import Keiro.Projection.Catalog qualified as Catalog",
           "import Keiro.ReadModel.Rebuild qualified as Rebuild",
           "import Kiroku.Store.Effect (Store)",
           "import Kiroku.Store.Types qualified as Kiroku"
         ]
      ++ ["import Kiroku.Store.Subscription.Types qualified as KirokuSubscription" | not (null asyncOwners)]
      ++ ["import " <> holesModule <> " qualified as Holes"]
      ++ map readModelImport readModels
      ++ [ "",
           "must :: Show error => Either error value -> value",
           "must = either (error . show) id"
         ]
      ++ concatMap ownerDefinition owners
      ++ [ "",
           "projectionCatalog :: Catalog.ProjectionCatalog",
           "projectionCatalog =",
           "  Catalog.ProjectionCatalog",
           "    " <> renderList sourceExpr sources,
           "    " <> renderList targetExpr targets,
           "    " <> renderList groupExpr groups,
           "    " <> renderList subscriptionExpr asyncOwners,
           "    " <> renderList dedupExpr asyncOwners,
           "    " <> renderList queryExpr boundReadModels,
           "    " <> renderList (("Catalog.SomeProjectionSet " <>) . ownerSetName) owners,
           "",
           "validatedProjectionCatalog :: Catalog.ValidatedProjectionCatalog",
           "validatedProjectionCatalog = case Catalog.validateProjectionCatalog projectionCatalog of",
           "  Catalog.Success catalog -> catalog",
           "  Catalog.Failure diagnostics -> error (\"keiro-dsl generated an invalid projection catalog: \" <> show diagnostics)",
           "",
           "projectionCatalogInventory :: Catalog.CatalogInventory",
           "projectionCatalogInventory = Catalog.catalogInventory validatedProjectionCatalog",
           "",
           "projectionCatalogRegistrations :: [Catalog.CatalogRegistration]",
           "projectionCatalogRegistrations = Catalog.catalogRegistrations validatedProjectionCatalog",
           "",
           "projectionCatalogAsyncRegistrations :: [Catalog.AsyncProjectionRegistration]",
           "projectionCatalogAsyncRegistrations = Catalog.asyncProjectionRegistrations validatedProjectionCatalog",
           "",
           "registerProjectionCatalog :: (Store :> es) => Eff es (Either Rebuild.CatalogRegistrationError [Rebuild.GroupRebuildMetadata])",
           "registerProjectionCatalog = Rebuild.registerProjectionCatalog validatedProjectionCatalog"
         ]
      ++ concatMap groupDefinitions groups
  where
    moduleName = contextGeneratedPrefix ctx <> ".ProjectionCatalog"
    holesModule = holePrefixFor ctx "ProjectionCatalog" <> ".ProjectionCatalogHoles"
    targets = [target | NProjectionTarget target <- specNodes spec]
    groups = [groupNode | NRebuildGroup groupNode <- specNodes spec]
    -- The catalog's list order is the declared total handler order. Keeping the
    -- sort here (rather than in the runtime) makes generated inventory and replay
    -- behavior agree even when declarations are arranged for readability.
    owners = sortOn poOrder [owner | NProjectionOwner owner <- specNodes spec]
    inlineOwners = [owner | owner <- owners, poFeed owner == RmInline]
    sources = nub (concatMap poSources owners)
    aggregateSources = nub [aggregateName | CatalogAggregate aggregateName <- sources]
    replayableAggregateSources =
      nub
        [ aggregateName
        | owner <- owners,
          poReplay owner == ProjectionReplayExplicit,
          CatalogAggregate aggregateName <- poSources owner
        ]
    asyncOwners = [owner | owner <- owners, poFeed owner == RmSubscription]
    projectionImports = case (null asyncOwners, null inlineOwners) of
      (False, False) -> ["import Keiro.Projection (AsyncProjection (..), InlineProjection (..))"]
      (False, True) -> ["import Keiro.Projection (AsyncProjection (..))"]
      (True, False) -> ["import Keiro.Projection (InlineProjection (..))"]
      (True, True) -> []
    readModels = [readModel | NReadModel readModel <- specNodes spec]
    boundReadModels = [readModel | readModel <- readModels, isJust (rmGroup readModel)]
    readModelAlias readModel = "RM" <> pascal (rmName readModel)
    readModelImport readModel = "import " <> genPrefixFor ctx (pascal (rmName readModel)) <> ".ReadModel qualified as " <> readModelAlias readModel
    aggregateImports aggregateName =
      [ "import " <> genPrefixFor ctx aggregateName <> ".Codec qualified as " <> aggregateCodecAlias aggregateName
      | aggregateName `elem` replayableAggregateSources
      ]
        <> ["import " <> genPrefixFor ctx aggregateName <> ".Domain qualified as " <> aggregateDomainAlias aggregateName]
    aggregateCodecAlias aggregateName = pascal aggregateName <> "Codec"
    aggregateDomainAlias aggregateName = pascal aggregateName <> "Domain"
    sourceExpr source =
      "Catalog.SourceDeclaration "
        <> smart "mkSourceId" (catalogSourceId source)
        <> " "
        <> sourceScope source
        <> " "
        <> tshow (sourceFingerprint source)
        <> " "
        <> claim ("source " <> catalogSourceId source)
    sourceScope CatalogAll = "Catalog.AllStreams"
    sourceScope (CatalogCategory categoryName) = "(Catalog.CategorySource (Kiroku.CategoryName " <> tshow categoryName <> "))"
    sourceScope (CatalogAggregate aggregateName) = "(Catalog.CategorySource (Kiroku.CategoryName " <> tshow (lowerFirst aggregateName) <> "))"
    sourceFingerprint CatalogAll = "all-streams/generated-codec/v1"
    sourceFingerprint (CatalogCategory categoryName) = "category:" <> categoryName <> "/application-decoder/v1"
    sourceFingerprint (CatalogAggregate aggregateName) = projectionAggregateSourceFingerprint spec aggregateName
    targetExpr target =
      "Catalog.TargetDeclaration "
        <> smart "mkTargetId" (ptName target)
        <> " (Catalog.QualifiedTable "
        <> tshow (ptSchema target)
        <> " "
        <> tshow (ptTable target)
        <> ") "
        <> (case ptReset target of TargetClear -> "Catalog.ClearBeforeReplay"; TargetPreserve -> "Catalog.PreserveAndReconcile")
        <> " "
        <> renderList (smart "mkTargetId") (ptDependsOn target)
        <> " "
        <> claim ("target " <> ptName target)
    groupExpr groupNode =
      "Catalog.RebuildGroupDeclaration "
        <> smart "mkRebuildGroupId" (rgName groupNode)
        <> " "
        <> renderList (smart "mkTargetId") (rgOrder groupNode)
        <> " [] "
        <> claim ("rebuild-group " <> rgName groupNode)
    subscriptionExpr owner =
      "Catalog.SubscriptionDeclaration "
        <> smart "mkSubscriptionId" (fromMaybe "" (poSubscription owner))
        <> " "
        <> tshow (fromMaybe "" (poSubscription owner))
        <> " "
        <> smart "mkSourceId" (catalogSourceId (ownerPrimarySource owner))
        <> " "
        <> checkpointOnMissingExpr owner
        <> " "
        <> claim ("projection-owner " <> poName owner <> " subscription")
    dedupExpr owner =
      "Catalog.DedupKeyDeclaration "
        <> smart "mkDedupKeyId" (fromMaybe "" (poDedup owner))
        <> " "
        <> tshow (fromMaybe "" (poDedup owner))
        <> " "
        <> claim ("projection-owner " <> poName owner <> " dedup")
    queryExpr readModel =
      "Catalog.SomeQueryModelBinding (Catalog.QueryModelBinding "
        <> smart "mkQueryModelId" (rmName readModel)
        <> " "
        <> readModelAlias readModel
        <> "."
        <> readModelStem readModel
        <> "ReadModel "
        <> smart "mkRebuildGroupId" (fromMaybe "" (rmGroup readModel))
        <> " "
        <> renderList (smart "mkTargetId") (rmObservedTargets readModel)
        <> " "
        <> claim ("readmodel " <> rmName readModel)
        <> ")"
    ownerSetName owner = lowerFirst (pascal (poName owner)) <> "ProjectionSet"
    ownerInlineViewName owner = lowerFirst (pascal (poName owner)) <> "InlineProjections"
    ownerEventType owner = case ownerPrimarySource owner of
      CatalogAggregate aggregateName -> aggregateDomainAlias aggregateName <> "." <> pascal aggregateName <> "Event"
      _ -> "Holes." <> pascal (poName owner) <> "Event"
    ownerDefinition owner =
      [ "",
        ownerSetName owner <> " :: Catalog.ProjectionSet " <> ownerEventType owner,
        ownerSetName owner <> " =",
        "  Catalog.ProjectionSet",
        "    " <> smart "mkSourceId" (catalogSourceId (ownerPrimarySource owner)),
        "    (Catalog.ProjectionDefinition",
        "      " <> smart "mkProjectionId" (poName owner),
        "      " <> smart "mkRebuildGroupId" (poGroup owner),
        "      " <> nonEmptyList (smart "mkTargetId") (poTargets owner),
        "      " <> replayPolicyExpr owner,
        "      (" <> handlerExpr owner <> " :| [])",
        "      " <> claim ("projection-owner " <> poName owner),
        "      :| [])",
        "    " <> claim ("projection-owner " <> poName owner <> " source")
      ]
        ++ if poFeed owner == RmInline
          then
            [ "",
              ownerInlineViewName owner <> " :: [InlineProjection " <> ownerEventType owner <> "]",
              ownerInlineViewName owner <> " = Catalog.typedInlineProjections validatedProjectionCatalog " <> ownerSetName owner
            ]
          else []
    replayPolicyExpr owner = case poReplay owner of
      ProjectionLiveOnly reason -> "(Catalog.LiveOnly (Catalog.LiveOnlyReason " <> tshow reason <> "))"
      ProjectionReplayExplicit -> case ownerPrimarySource owner of
        CatalogAggregate aggregateName ->
          "(Catalog.Replayable (Catalog.replayAdapterFromCodec "
            <> aggregateCodecAlias aggregateName
            <> "."
            <> lowerFirst aggregateName
            <> "Codec Holes."
            <> ownerReplayApplyName owner
            <> "))"
        _ ->
          "(Catalog.Replayable (Catalog.ReplayAdapter Holes."
            <> ownerReplayDecodeName owner
            <> " Holes."
            <> ownerReplayApplyName owner
            <> "))"
    handlerExpr owner = case poFeed owner of
      RmInline ->
        "Catalog.InlineHandler (InlineProjection "
          <> tshow (poName owner)
          <> " Holes."
          <> ownerLiveApplyName owner
          <> ") "
          <> claim ("projection-owner " <> poName owner <> " inline-handler")
      RmSubscription ->
        "Catalog.AsyncHandler (AsyncProjection "
          <> tshow (fromMaybe "" (poDedup owner))
          <> " "
          <> tshow (ownerQueryRegistry owner)
          <> " "
          <> tshow (fromMaybe "" (poSubscription owner))
          <> " Holes."
          <> ownerLiveApplyName owner
          <> " Holes."
          <> ownerIdempotencyName owner
          <> ") "
          <> smart "mkSubscriptionId" (fromMaybe "" (poSubscription owner))
          <> " "
          <> smart "mkDedupKeyId" (fromMaybe "" (poDedup owner))
          <> " "
          <> claim ("projection-owner " <> poName owner <> " async-handler")
    ownerQueryRegistry owner = case matchingReadModels owner of
      readModel : _ -> registryNameFor (contextName ctx) readModel
      [] -> ""
    matchingReadModels owner =
      [ readModel
      | readModel <- boundReadModels,
        rmGroup readModel == Just (poGroup owner),
        any (`elem` poTargets owner) (rmObservedTargets readModel)
      ]
    ownerLiveApplyName owner = "apply" <> pascal (poName owner) <> "Live"
    ownerReplayApplyName owner = "apply" <> pascal (poName owner) <> "Replay"
    ownerReplayDecodeName owner = "decode" <> pascal (poName owner) <> "Replay"
    ownerIdempotencyName owner = lowerFirst (pascal (poName owner)) <> "IdempotencyKey"
    groupIdName groupNode = lowerFirst (pascal (rgName groupNode)) <> "RebuildGroupId"
    groupStartName groupNode = "start" <> pascal (rgName groupNode) <> "Rebuild"
    groupExports groupNode = ["  , " <> groupIdName groupNode, "  , " <> groupStartName groupNode]
    groupDefinitions groupNode =
      [ "",
        groupIdName groupNode <> " :: Catalog.RebuildGroupId",
        groupIdName groupNode <> " = " <> smart "mkRebuildGroupId" (rgName groupNode),
        "",
        groupStartName groupNode <> " :: (IOE :> es, Store :> es) => Rebuild.RebuildOptions -> Eff es (Either Rebuild.CatalogRebuildError Rebuild.RebuildRunReport)",
        groupStartName groupNode <> " = Rebuild.startCatalogRebuild validatedProjectionCatalog " <> groupIdName groupNode
      ]
    smart constructor value = "(must (Catalog." <> constructor <> " " <> tshow value <> "))"
    claim value = smart "mkClaimSite" value
    renderList render values = "[" <> T.intercalate ", " (map render values) <> "]"
    nonEmptyList _ [] = "error \"keiro-dsl invariant: validated projection owner has no targets\""
    nonEmptyList render (value : values) = "(" <> render value <> " :| " <> renderList render values <> ")"
    ownerPrimarySource owner = case poSources owner of
      source : _ -> source
      [] -> CatalogAll
    checkpointOnMissingExpr owner = case poCheckpointOnMissing owner of
      [CheckpointFromBeginning] -> "KirokuSubscription.FromBeginning"
      [CheckpointFromCurrentHead] -> "KirokuSubscription.FromCurrentHead"
      [CheckpointFail] -> "KirokuSubscription.FailIfMissing"
      _ -> "error \"keiro-dsl invariant: validated subscription owner must declare exactly one checkpoint-on-missing policy\""

emitProjectionCatalogHoles :: Context -> [ProjectionOwnerNode] -> Text
emitProjectionCatalogHoles ctx owners =
  nl $
    [ "-- This is a HAND-OWNED hole module. keiro-dsl creates it once and never overwrites it.",
      "module " <> moduleName,
      "  ( " <> T.intercalate "\n  , " exports,
      "  ) where",
      ""
    ]
      ++ ["import " <> genPrefixFor ctx aggregateName <> ".Domain (" <> pascal aggregateName <> "Event)" | aggregateName <- aggregateSources]
      ++ [ "import Hasql.Transaction qualified as Tx",
           "import Keiro.Projection.Catalog qualified as Catalog",
           "import Kiroku.Store.Types (EventId, RecordedEvent)",
           ""
         ]
      ++ concatMap ownerStubs owners
  where
    moduleName = holePrefixFor ctx "ProjectionCatalog" <> ".ProjectionCatalogHoles"
    aggregateSources = nub [aggregateName | owner <- owners, CatalogAggregate aggregateName <- poSources owner]
    exports = concatMap ownerExports owners
    ownerExports owner =
      [pascal (poName owner) <> "Event" | not (isAggregateSource owner)]
        <> [ownerLiveApplyName owner]
        <> [ownerIdempotencyName owner | poFeed owner == RmSubscription]
        <> case poReplay owner of
          ProjectionLiveOnly _ -> []
          ProjectionReplayExplicit -> [ownerReplayApplyName owner] <> [ownerReplayDecodeName owner | not (isAggregateSource owner)]
    ownerStubs owner =
      ["-- Projection owner " <> poName owner <> " (order " <> T.pack (show (poOrder owner)) <> ")."]
        <> ["data " <> ownerEventType owner <> " = " <> ownerEventType owner | not (isAggregateSource owner)]
        <> [ownerLiveSignature owner, ownerLiveApplyName owner <> " = error \"HOLE: fill " <> poName owner <> " live apply\""]
        <> ( if poFeed owner == RmSubscription
               then
                 [ ownerIdempotencyName owner <> " :: RecordedEvent -> EventId",
                   ownerIdempotencyName owner <> " = error \"HOLE: return the durable event id for " <> poName owner <> "\""
                 ]
               else []
           )
        <> replayStubs owner
        <> [""]
    replayStubs owner = case poReplay owner of
      ProjectionLiveOnly _ -> []
      ProjectionReplayExplicit ->
        ( if not (isAggregateSource owner)
            then
              [ ownerReplayDecodeName owner <> " :: RecordedEvent -> Catalog.ReplayDecodeResult " <> ownerEventType owner,
                ownerReplayDecodeName owner <> " = error \"HOLE: classify and decode every " <> poName owner <> " source event\""
              ]
            else []
        )
          <> [ ownerReplayApplyName owner <> " :: " <> ownerEventType owner <> " -> RecordedEvent -> Tx.Transaction ()",
               ownerReplayApplyName owner <> " = error \"HOLE: fill " <> poName owner <> " replay apply without live-only side effects\""
             ]
    ownerLiveSignature owner =
      ownerLiveApplyName owner <> " :: " <> case poFeed owner of
        RmInline -> ownerEventType owner <> " -> RecordedEvent -> Tx.Transaction ()"
        RmSubscription -> "RecordedEvent -> Tx.Transaction ()"
    ownerEventType owner = case ownerPrimarySource owner of
      CatalogAggregate aggregateName -> pascal aggregateName <> "Event"
      _ -> pascal (poName owner) <> "Event"
    isAggregateSource owner = case ownerPrimarySource owner of CatalogAggregate {} -> True; _ -> False
    ownerPrimarySource owner = case poSources owner of source : _ -> source; [] -> CatalogAll
    ownerLiveApplyName owner = "apply" <> pascal (poName owner) <> "Live"
    ownerReplayApplyName owner = "apply" <> pascal (poName owner) <> "Replay"
    ownerReplayDecodeName owner = "decode" <> pascal (poName owner) <> "Replay"
    ownerIdempotencyName owner = lowerFirst (pascal (poName owner)) <> "IdempotencyKey"

catalogSourceId :: CatalogSource -> Text
catalogSourceId CatalogAll = "all"
catalogSourceId (CatalogCategory categoryName) = "category:" <> categoryName
catalogSourceId (CatalogAggregate aggregateName) = "aggregate:" <> aggregateName

modulePathFor :: Text -> Text -> FilePath
modulePathFor prefix leaf = T.unpack (T.replace "." "/" prefix <> "/" <> leaf <> ".hs")

readModelStem :: ReadModelNode -> Text
readModelStem = lowerFirst . T.concat . map pascal . T.splitOn "_" . rmName

emitReadModelTable :: Text -> Text -> ReadModelNode -> Text
emitReadModelTable tableModule stem readModel =
  nl
    [ generatedBanner,
      "module " <> tableModule <> " (" <> qualifiedName <> ") where",
      "",
      "import Data.Text (Text)",
      "import Keiro.Connection (qualifyTable)",
      "",
      "-- The fully-qualified, double-quoted data-table reference.",
      qualifiedName <> " :: Text",
      qualifiedName <> " = qualifyTable " <> tshow (rmSchema readModel) <> " " <> tshow (rmTable readModel)
    ]
  where
    qualifiedName = stem <> "QualifiedTable"

emitReadModelQueryContract :: Text -> TypeGraph -> Text -> ReadModelNode -> ReadModelQueryTypes -> Text
emitReadModelQueryContract queryContractModule graph stem readModel queryPair =
  nl $
    [ generatedBanner,
      "module " <> queryContractModule,
      "  ( " <> queryInputType,
      "  , " <> queryResultType,
      "  ) where",
      ""
    ]
      <> imports
      <> ["" | not (null imports)]
      <> [ "type " <> queryInputType <> " = " <> renderType inputExpression,
           "type " <> queryResultType <> " = " <> renderType resultExpression
         ]
  where
    queryInputType = pascal stem <> "QueryInput"
    queryResultType = pascal stem <> "QueryResult"
    inputExpression = resolve "input" (inputLoc queryPair) (input queryPair)
    resultExpression = resolve "result" (resultLoc queryPair) (result queryPair)
    expressions = [inputExpression, resultExpression]
    plans = map plan expressions
    references = Set.unions (map consumerTypeReferences plans)
    reservedNames = Set.fromList [queryInputType, queryResultType, "Map", "Natural", "Text", "UTCTime", "Value"]
    importPlan = planImportsOrDie queryContractModule reservedNames references
    imports =
      ["import Data.Aeson (Value)" | any typeUsesJson expressions]
        <> ["import Data.Map.Strict (Map)" | any typeUsesMap expressions]
        <> ["import Data.Text (Text)" | any typeUsesText expressions]
        <> ["import Data.Time (UTCTime)" | any typeUsesTime expressions]
        <> ["import Numeric.Natural (Natural)" | any typeUsesNatural expressions]
        <> T.lines (renderPlannedImports importPlan)
    resolve position location expression =
      either
        (\failure -> error ("checked read-model query " <> T.unpack position <> " failed: " <> show failure))
        id
        (resolveTypeExpression graph owner location expression)
      where
        owner = "readmodel '" <> rmName readModel <> "' query " <> position
    plan expression =
      either
        (error . ("validated read-model consumer type planning failed: " <>) . show)
        id
        (planConsumerType graph expression)
    renderType expression =
      unHaskellTypeOccurrence $
        either
          (error . ("validated read-model consumer type rendering failed: " <>) . show)
          id
          (renderConsumerType importPlan graph expression)

emitReadModelGen :: Context -> Text -> Text -> Text -> Text -> ReadModelNode -> Text
emitReadModelGen ctx readModelModule tableModule readModelHolePrefix stem readModel =
  emitReadModelGenWithContract ctx readModelModule tableModule readModelHolePrefix Nothing stem readModel

emitReadModelGenWithContract :: Context -> Text -> Text -> Text -> Maybe Text -> Text -> ReadModelNode -> Text
emitReadModelGenWithContract ctx readModelModule tableModule readModelHolePrefix queryContractModule stem readModel =
  nl $
    renderGeneratedLanguagePragmas [ExtOverloadedRecordDot | emitsLegacyAsync]
      <> [ generatedBanner,
           "module " <> readModelModule <> ".ReadModel",
           "  ( " <> T.intercalate "\n  , " exports,
           "  ) where",
           ""
         ]
      ++ (if not catalogManaged then ["import Data.Functor (void)", "import Effectful (Eff, (:>))"] else [])
      ++ ["import " <> tableModule <> " (" <> qualifiedName <> ")"]
      ++ ["import " <> contractModule <> " (" <> queryInputType <> ", " <> queryResultType <> ")" | Just contractModule <- [queryContractModule]]
      ++ ["import " <> readModelHolePrefix <> ".ReadModelHoles (" <> T.intercalate ", " holeImports <> ")"]
      ++ asyncImports
      ++ [ "import Keiro.ReadModel (" <> readModelImports <> ")"
         ]
      ++ (if not catalogManaged then ["import Keiro.ReadModel.Rebuild qualified as Rebuild", "import Kiroku.Store.Effect (Store)", "import Kiroku.Store.Types (" <> kirokuTypes <> ")"] else [])
      ++ [ "",
           readModelName <> " :: ReadModel " <> queryInputType <> " " <> queryResultType,
           readModelName <> " =",
           "  ReadModel",
           "    { name = " <> tshow registryName,
           "    , tableName = " <> tshow (rmTable readModel),
           "    , schema = " <> tshow (rmSchema readModel),
           "    , subscriptionName = " <> tshow subscriptionName,
           "    , version = " <> tshow' (rmVersion readModel),
           "    , shapeHash = " <> tshow (rmShape readModel),
           "    , defaultConsistency = " <> consistencyExpr (rmConsistency readModel),
           "    , strongScope = " <> scopeExpr (rmScope readModel),
           "    , query = " <> queryName,
           "    }"
         ]
      ++ legacyLifecycleDefinitions
      ++ asyncDefinition
  where
    catalogManaged = rmGroup readModel /= Nothing
    emitsLegacyAsync = not catalogManaged && rmFeed readModel == RmSubscription
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
      [ readModelName,
        qualifiedName
      ]
        ++ (if not catalogManaged then [registerName, startName, finishName, abandonName] else [])
        ++ [asyncValueName | emitsLegacyAsync]
    holeImports = (if queryContractModule == Nothing then [queryInputType, queryResultType] else []) ++ [queryName] ++ [applyName | emitsLegacyAsync]
    asyncImports = ["import Keiro.Projection (AsyncProjection (..))" | emitsLegacyAsync]
    readModelImports =
      "ConsistencyMode (..), ReadModel (..)"
        <> if catalogManaged
          then ", StrongScope (..)"
          else ", ReadModelMetadata, StrongScope (..), registerReadModel"
    kirokuTypes = case rmFeed readModel of
      RmInline -> "GlobalPosition"
      RmSubscription -> "GlobalPosition, RecordedEvent (..)"
    projectionNames = case rmFeed readModel of
      RmInline -> "[]"
      RmSubscription -> "[" <> tshow asyncName <> "]"
    legacyLifecycleDefinitions
      | not catalogManaged =
          [ "",
            "-- Call once at projection startup before serving queries.",
            registerName <> " :: (Store :> es) => Eff es ()",
            registerName <> " =",
            "  void (registerReadModel " <> tshow registryName <> " " <> tshow' (rmVersion readModel) <> " " <> tshow (rmShape readModel) <> ")",
            "",
            startName <> " :: (Store :> es) => GlobalPosition -> Eff es ReadModelMetadata",
            startName <> " =",
            "  Rebuild.startRebuild " <> readModelName <> " " <> projectionNames,
            "",
            finishName <> " :: (Store :> es) => GlobalPosition -> Eff es (Either Rebuild.RebuildError ReadModelMetadata)",
            finishName <> " =",
            "  Rebuild.finishRebuild " <> readModelName <> " " <> projectionNames,
            "",
            abandonName <> " :: (Store :> es) => Eff es ReadModelMetadata",
            abandonName <> " = Rebuild.abandonRebuild " <> readModelName
          ]
      | otherwise = []
    asyncDefinition
      | emitsLegacyAsync =
          [ "",
            asyncValueName <> " :: AsyncProjection",
            asyncValueName <> " =",
            "  AsyncProjection",
            "    { name = " <> tshow asyncName,
            "    , readModelName = " <> tshow registryName,
            "    , subscriptionName = " <> tshow subscriptionName,
            "    , applyRecorded = " <> applyName,
            "    , idempotencyKey = \\recorded -> recorded.eventId",
            "    }"
          ]
      | otherwise = []
    consistencyExpr Strong = "Strong"
    consistencyExpr Eventual = "Eventual"
    scopeExpr Nothing = "EntireLog"
    scopeExpr (Just RmEntireLog) = "EntireLog"
    scopeExpr (Just (RmCategory categoryName)) = "CategoryHead " <> tshow categoryName

emitReadModelHoles :: Text -> Text -> Text -> ReadModelNode -> Text
emitReadModelHoles tableModule readModelHolePrefix stem readModel =
  nl $
    [ "-- This is a HAND-OWNED hole module. keiro-dsl creates it once and never overwrites it.",
      "module " <> readModelHolePrefix <> ".ReadModelHoles",
      "  ( " <> T.intercalate "\n  , " exports,
      "  ) where",
      "",
      "import " <> tableModule <> " (" <> qualifiedName <> ")",
      "import Hasql.Transaction qualified as Tx"
    ]
      ++ ["import Kiroku.Store.Types (RecordedEvent(..))" | emitsLegacyAsync]
      ++ [ "",
           "-- HOLE: replace these aliases with the real query input and result types.",
           "type " <> queryInputType <> " = ()",
           "type " <> queryResultType <> " = ()",
           "",
           "-- HOLE: query " <> qualifiedTableLiteral readModel <> " via " <> qualifiedName <> "; never rely on search_path.",
           "-- Declared columns:"
         ]
      ++ map (("--   " <>) . readModelColumnDoc) (rmColumns readModel)
      ++ [ queryName <> " :: " <> queryInputType <> " -> Tx.Transaction " <> queryResultType,
           queryName <> " _input = " <> qualifiedName <> " `seq` error " <> tshow ("HOLE: fill " <> rmName readModel <> " query")
         ]
      ++ applyStub
  where
    qualifiedName = stem <> "QualifiedTable"
    queryInputType = pascal stem <> "QueryInput"
    queryResultType = pascal stem <> "QueryResult"
    queryName = stem <> "Query"
    applyName = "apply" <> pascal stem
    emitsLegacyAsync = rmGroup readModel == Nothing && rmFeed readModel == RmSubscription
    exports = [queryInputType, queryResultType, queryName] ++ [applyName | emitsLegacyAsync]
    applyStub
      | emitsLegacyAsync =
          [ "",
            "-- HOLE: apply one recorded event; runtime deduplication makes redelivery safe.",
            applyName <> " :: RecordedEvent -> Tx.Transaction ()",
            applyName <> " _recorded = error " <> tshow ("HOLE: fill " <> rmName readModel <> " async apply")
          ]
      | otherwise = []

emitTypedReadModelHoles :: Text -> Text -> Text -> Text -> ReadModelNode -> Text
emitTypedReadModelHoles tableModule queryContractModule readModelHolePrefix stem readModel =
  nl $
    [ "-- This is a HAND-OWNED hole module. keiro-dsl creates it once and never overwrites it.",
      "module " <> readModelHolePrefix <> ".ReadModelHoles",
      "  ( " <> T.intercalate "\n  , " exports,
      "  ) where",
      "",
      "import " <> tableModule <> " (" <> qualifiedName <> ")",
      "import " <> queryContractModule <> " (" <> queryInputType <> ", " <> queryResultType <> ")",
      "import Hasql.Transaction qualified as Tx"
    ]
      ++ ["import Kiroku.Store.Types (RecordedEvent(..))" | emitsLegacyAsync]
      ++ [ "",
           "-- HOLE: query " <> qualifiedTableLiteral readModel <> " via " <> qualifiedName <> "; never rely on search_path.",
           "-- The generated QueryContract owns query input/result type identity.",
           "-- Declared columns:"
         ]
      ++ map (("--   " <>) . readModelColumnDoc) (rmColumns readModel)
      ++ [ queryName <> " :: " <> queryInputType <> " -> Tx.Transaction " <> queryResultType,
           queryName <> " _input = " <> qualifiedName <> " `seq` error " <> tshow ("HOLE: fill " <> rmName readModel <> " query")
         ]
      ++ applyStub
  where
    qualifiedName = stem <> "QualifiedTable"
    queryInputType = pascal stem <> "QueryInput"
    queryResultType = pascal stem <> "QueryResult"
    queryName = stem <> "Query"
    applyName = "apply" <> pascal stem
    emitsLegacyAsync = rmGroup readModel == Nothing && rmFeed readModel == RmSubscription
    exports = [queryName] ++ [applyName | emitsLegacyAsync]
    applyStub
      | emitsLegacyAsync =
          [ "",
            "-- HOLE: apply one recorded event; runtime deduplication makes redelivery safe.",
            applyName <> " :: RecordedEvent -> Tx.Transaction ()",
            applyName <> " _recorded = error " <> tshow ("HOLE: fill " <> rmName readModel <> " async apply")
          ]
      | otherwise = []

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
      { modulePath = modulePathFor genPrefix "Router",
        moduleText = emitRouterGen genPrefix router,
        kind = Generated,
        origin = routerOrigin
      },
    ScaffoldModule
      { modulePath = modulePathFor holePrefix "RouterHoles",
        moduleText = emitRouterHoles holePrefix router,
        kind = HoleStub,
        origin = routerOrigin
      }
  ]
  where
    genPrefix = genPrefixFor ctx (rtId router)
    holePrefix = holePrefixFor ctx (rtId router)
    routerOrigin = nodeOrigin "router" (rtId router) (rtLoc router)

-- | Service-aware router generation preserves the historical custom resolver
-- vertical byte-for-byte, while a checked declarative selection becomes one
-- fully generated module and owns no selection hole.
scaffoldRouterForService :: Context -> CheckedService -> RouterNode -> [ScaffoldModule]
scaffoldRouterForService ctx service router = case rvSource (rtResolve router) of
  ResolveDeclarative {} ->
    [ ScaffoldModule
        { modulePath = modulePathFor genPrefix "Router",
          moduleText = emitDeclarativeRouterGen ctx graph selection readModel targetAggregate targetCommand genPrefix router,
          kind = Generated,
          origin = routerOrigin
        }
    ]
  _ -> scaffoldRouter ctx router
  where
    spec = checkedSpec service
    genPrefix = genPrefixFor ctx (rtId router)
    routerOrigin = nodeOrigin "router" (rtId router) (rtLoc router)
    graph = case resolveTypeGraph spec of
      Left errors -> error ("checked declarative router type graph failed: " <> show errors)
      Right value -> value
    selection = case checkRouterSelection (checkedLanguageContract service) graph spec router of
      Left diagnostics -> error ("checked declarative router selection failed: " <> show diagnostics)
      Right value -> value
    readModel = case [value | NReadModel value <- specNodes spec, rmName value == checkedQueryName (checkedQuery selection)] of
      [value] -> value
      _ -> error "checked declarative router read model disappeared"
    targetAggregate = case [aggregate | NAggregate aggregate <- specNodes spec, aggName aggregate == checkedTarget selection] of
      [aggregate] -> aggregate
      _ -> error "checked declarative router target aggregate disappeared"
    targetCommand = case [command | command <- aggCommands targetAggregate, cmdName command == checkedCommand selection] of
      [command] -> command
      _ -> error "checked declarative router target command disappeared"

emitRouterGen :: Text -> RouterNode -> Text
emitRouterGen genPrefix router =
  nl $
    [ generatedBanner,
      "module " <> genPrefix <> ".Router",
      "  ( " <> stem <> "Name",
      "  , " <> stem <> "WorkerOptions",
      "  ) where",
      "",
      "import Data.Text (Text)"
    ]
      ++ workerPolicyImports (rtPoison router)
      ++ [ "",
           "-- The STABLE router name. It participates in every target-keyed",
           "-- deterministicRouterCommandId; renaming it re-keys replayed dispatches.",
           stem <> "Name :: Text",
           stem <> "Name = " <> tshow (rtName router),
           "",
           "-- Runtime-owned dispatch id inputs: (name, key, sourceEventId,",
           "-- targetStreamName, occurrence). Target-keyed, not positional.",
           "",
           "-- Node-level worker policy lowered from the spec. Pass this value to",
           "-- Keiro.Router.runRouterWorkerWith; do not silently use defaultWorkerOptions."
         ]
      ++ workerOptionsLines (stem <> "WorkerOptions") (rtRejected router) (rtPoison router)
  where
    stem = lowerFirst (rtId router)

emitDeclarativeRouterGen :: Context -> TypeGraph -> CheckedRouterSelection -> ReadModelNode -> Aggregate -> Command -> Text -> RouterNode -> Text
emitDeclarativeRouterGen ctx graph selection readModel targetAggregate targetCommand genPrefix router =
  nl $
    [ generatedBanner,
      "module " <> genPrefix <> ".Router",
      "  ( " <> stem <> "Name",
      "  , " <> stem <> "WorkerOptions",
      "  , " <> stem <> "SelectionFingerprint",
      "  , " <> stem <> "SelectionContract",
      "  , " <> stem <> "Select",
      "  , " <> stem,
      "  ) where",
      "",
      "import Data.Text (Text)",
      "import Effectful (Eff, IOE, (:>))",
      "import " <> structuralProjectionModule ctx <> " qualified as StructuralProjections",
      "import " <> queryContractModule <> " (" <> queryInputType <> ")",
      "import " <> readModelModule <> ".ReadModel qualified as SelectionQuery",
      "import " <> targetModule <> ".Domain qualified as TargetDomain",
      "import " <> targetModule <> ".EventStream qualified as TargetStream"
    ]
      <> ["import " <> targetModule <> ".Projection qualified as TargetProjection" | not (null (rtProjections router))]
      <> [ "import Keiki.Core (HsPred, fieldWitnessGet)",
           "import Keiro.ProcessManager (PMCommand (..), PoisonPolicy (..), RejectedCommandPolicy (..), WorkerOptions (..))",
           "import Keiro.ReadModel (runQuery)",
           "import Keiro.Router",
           "  ( DeclarativeRouter (..)",
           "  , EmptySelectionPolicy (..)",
           "  , PartialDispatchPolicy (..)",
           "  , RedeliveryPolicy (..)",
           "  , RouterSelectionContract (..)",
           "  , RouterSelectionFailure (..)",
           "  , SelectionDedupe (..)",
           "  , SelectionFailurePolicy (..)",
           "  , SelectionFingerprint (..)",
           "  , SelectionIdentity (..)",
           "  , SelectionOrder (..)",
           "  , mkRecipientLimit",
           "  , mkSelectionVersion",
           "  )",
           "import Keiro.Stream (entityStream)",
           "import Kiroku.Store.Effect (Store)",
           "import Shibuya.Core.Ack (RetryDelay (..))"
         ]
      <> ["import Shibuya.Core.Types (Envelope)" | rtPoison router /= PolHalt]
      <> [ "",
           "-- The STABLE router name. It remains part of every target-keyed",
           "-- deterministic router command id; selection metadata never re-keys dispatches.",
           stem <> "Name :: Text",
           stem <> "Name = " <> tshow (rtName router),
           "",
           "-- SHA-256 of the checked selection semantics (locations and formatting excluded).",
           stem <> "SelectionFingerprint :: Text",
           stem <> "SelectionFingerprint = " <> tshow (checkedFingerprint selection),
           "",
           stem <> "SelectionContract :: RouterSelectionContract",
           stem <> "SelectionContract =",
           "  RouterSelectionContract",
           "    { identity = SelectionIdentity " <> tshow (checkedIdentity selection),
           "    , version = checkedSelectionVersion",
           "    , fingerprint = SelectionFingerprint " <> stem <> "SelectionFingerprint",
           "    , limit = checkedRecipientLimit",
           "    , order = OrderByTargetStream",
           "    , dedupe = DedupeByTargetStream",
           "    , emptyPolicy = " <> renderCheckedEmptyPolicy (checkedEmptyPolicy selection),
           "    , failurePolicy = " <> renderCheckedFailurePolicy (checkedFailurePolicy selection),
           "    , redeliveryPolicy = StableUnion",
           "    , partialPolicy = RetainSuccesses",
           "    }",
           "  where",
           "    checkedSelectionVersion = case mkSelectionVersion " <> T.pack (show (checkedVersion selection)) <> " of",
           "      Right value -> value",
           "      Left _ -> error \"keiro-dsl emitted a non-positive checked selection version\"",
           "    checkedRecipientLimit = case mkRecipientLimit " <> T.pack (show (checkedLimit selection)) <> " of",
           "      Right value -> value",
           "      Left _ -> error \"keiro-dsl emitted a non-positive checked recipient limit\"",
           "",
           stem <> "Select ::",
           "  (IOE :> es, Store :> es) =>",
           "  " <> queryInputType <> " ->",
           "  Eff es (Either RouterSelectionFailure [PMCommand TargetDomain." <> targetName <> "Command])",
           stem <> "Select input = do",
           "  queryResult <- runQuery Nothing SelectionQuery." <> readModelValue <> " input",
           "  pure $ case queryResult of",
           "    Left _ -> Left (SelectionQueryFailed " <> tshow ("read-model " <> checkedQueryName (checkedQuery selection) <> " query failed") <> ")",
           "    Right rows ->",
           "      Right",
           "        [ PMCommand",
           "            { target = entityStream TargetStream." <> targetCategory <> " (" <> renderCheckedScalar graph (checkedRecipient selection) <> ")",
           "            , command = " <> renderSelectionCommand graph selection targetCommand,
           "            }",
           "        | row <- rows",
           "        , " <> renderCheckedScalar graph (checkedPredicate selection),
           "        ]",
           "",
           stem <> " ::",
           "  (IOE :> es, Store :> es) =>",
           "  DeclarativeRouter",
           "    " <> queryInputType,
           "    (HsPred TargetDomain." <> targetName <> "Regs TargetDomain." <> targetName <> "Command)",
           "    TargetDomain." <> targetName <> "Regs",
           "    TargetDomain." <> targetName <> "Vertex",
           "    TargetDomain." <> targetName <> "Command",
           "    TargetDomain." <> targetName <> "Event",
           "    es",
           stem <> " =",
           "  DeclarativeRouter",
           "    { name = " <> stem <> "Name",
           "    , key = \\input -> " <> renderCheckedScalar graph (checkedKey selection),
           "    , selectionContract = " <> stem <> "SelectionContract",
           "    , select = " <> stem <> "Select",
           "    , targetEventStream = TargetStream." <> targetEventStream,
           "    , targetProjections = const " <> renderTargetProjections (rtProjections router),
           "    }",
           "",
           "-- Node-level worker policy. Pair it with runDeclarativeRouterWorkerWith.",
           "-- Selection empty/failure policy remains in the generated selection contract."
         ]
      <> workerOptionsLines (stem <> "WorkerOptions") (rtRejected router) (rtPoison router)
  where
    stem = lowerFirst (rtId router)
    targetName = aggName targetAggregate
    targetModule = genPrefixFor ctx targetName
    targetCategory = lowerFirst targetName <> "CommandCategory"
    targetEventStream = lowerFirst targetName <> "EventStream"
    readModelStemValue = readModelStem readModel
    queryInputType = pascal readModelStemValue <> "QueryInput"
    queryNodeSegment = pascal (rmName readModel)
    queryContractModule = genPrefixFor ctx queryNodeSegment <> ".QueryContract"
    readModelModule = genPrefixFor ctx queryNodeSegment
    readModelValue = readModelStemValue <> "ReadModel"
    renderTargetProjections [] = "[]"
    renderTargetProjections names = "[" <> T.intercalate ", " ["TargetProjection." <> lowerFirst name <> "Projection" | name <- names] <> "]"

renderCheckedEmptyPolicy :: CheckedEmptySelectionPolicy -> Text
renderCheckedEmptyPolicy = \case
  CheckedEmptyAck -> "EmptyAck"
  CheckedEmptyRetry -> "EmptyRetry"
  CheckedEmptyDeadLetter -> "EmptyDeadLetter"
  CheckedEmptyHalt -> "EmptyHalt"

renderCheckedFailurePolicy :: CheckedSelectionFailurePolicy -> Text
renderCheckedFailurePolicy = \case
  CheckedFailureRetry -> "FailureRetry"
  CheckedFailureDeadLetter -> "FailureDeadLetter"
  CheckedFailureHalt -> "FailureHalt"

renderCheckedScalar :: TypeGraph -> CheckedScalarExpr -> Text
renderCheckedScalar graph expression = case checkedScalarNode expression of
  CheckedPath root segments ->
    "(fieldWitnessGet StructuralProjections."
      <> witnessName segments
      <> " "
      <> rootName root
      <> ")"
  CheckedTextLiteral value -> tshow value
  CheckedIntegralLiteral value -> T.pack (show value)
  CheckedBoolLiteral value -> if value then "True" else "False"
  CheckedCompare operator left right ->
    "(" <> renderCheckedScalar graph left <> " " <> comparison operator <> " " <> renderCheckedScalar graph right <> ")"
  CheckedAnd left right -> "(" <> renderCheckedScalar graph left <> " && " <> renderCheckedScalar graph right <> ")"
  CheckedOr left right -> "(" <> renderCheckedScalar graph left <> " || " <> renderCheckedScalar graph right <> ")"
  where
    rootName SelectionInput = "input"
    rootName SelectionRow = "row"
    comparison OpEq = "=="
    comparison OpNeq = "/="
    comparison OpLt = "<"
    comparison OpLe = "<="
    comparison OpGt = ">"
    comparison OpGe = ">="
    witnessName [] = error "checked scalar path contained no fields"
    witnessName path@(first : _) =
      fromMaybe
        (error "checked scalar path has no generated structural witness")
        (projectionWitnessName graph (checkedPathOwner first) pointer)
      where
        pointer = T.concat ["/" <> escapePointer (checkedPathWireKey segment) | segment <- path]

renderSelectionCommand :: TypeGraph -> CheckedRouterSelection -> Command -> Text
renderSelectionCommand graph selection command =
  "TargetDomain."
    <> cmdName command
    <> " (TargetDomain."
    <> cmdName command
    <> "Data"
    <> T.concat [" (" <> renderCheckedScalar graph (commandExpression field) <> ")" | field <- cmdFields command]
    <> ")"
  where
    commandExpression field =
      fromMaybe
        (error "checked declarative router command field disappeared")
        (Map.lookup (aggregateFieldName field) (checkedCommandFields selection))

emitRouterHoles :: Text -> RouterNode -> Text
emitRouterHoles holePrefix router =
  nl
    [ "-- HAND-OWNED hole module for the router's behaviour-bearing bodies.",
      "-- keiro-dsl creates it once and never overwrites it.",
      "module " <> holePrefix <> ".RouterHoles () where",
      "",
      "-- HOLE resolve :: " <> inName (rtInput router) <> " -> Eff es [PMCommand targetCommand]",
      "--   Spec source: " <> resolveSourceText (rvSource (rtResolve router)) <> ".",
      "--   The spec's 'stable' keyword acknowledges that retry attempts accumulate",
      "--   the UNION of resolved target identities. Keep the recipient set stable",
      "--   for a source event whenever an exact recipient set matters.",
      "-- HOLE router value: assemble Keiro.Router.Router with name = " <> lowerFirst (rtId router) <> "Name,",
      "--   key, resolve, targetEventStream, and targetProjections; run it with",
      "--   runRouterWorkerWith " <> lowerFirst (rtId router) <> "WorkerOptions.",
      "-- HOLE targetProjections: spec projections = " <> renderNames (rtProjections router) <> ".",
      "-- NOTE on-duplicate AckOk is sound because Keiro.Router confirms a duplicate",
      "--   event id against the TARGET stream via confirmBenignDuplicate before",
      "--   returning PMCommandDuplicate. Hand-rolled dispatch paths must do likewise."
    ]
  where
    renderNames names = "[" <> T.intercalate ", " names <> "]"

resolveSourceText :: ResolveSource -> Text
resolveSourceText (ResolveReadModel name) = "read-model " <> name <> " (typically Keiro.ReadModel.runQuery)"
resolveSourceText ResolveHole = "typed resolver hole"
resolveSourceText (ResolveDeclarative selection) = "declarative selection " <> rsIdentity selection

workerPolicyImports :: PolicyChoice -> [Text]
workerPolicyImports poison =
  [ "import Keiro.ProcessManager (PoisonPolicy (..), RejectedCommandPolicy (..), WorkerOptions (..))",
    "import Shibuya.Core.Ack (RetryDelay (..))"
  ]
    ++ if poison == PolHalt
      then []
      else ["import Effectful (Eff)", "import Shibuya.Core.Types (Envelope)"]

workerOptionsLines :: Text -> PolicyChoice -> PolicyChoice -> [Text]
workerOptionsLines valueName rejected poison =
  [ valueName <> signature,
    valueName <> argument <> " =",
    "  WorkerOptions",
    "    { poisonPolicy = " <> poisonExpr <> ",",
    "      rejectedCommandPolicy = " <> rejectedExpr rejected <> ",",
    "      transientRetryDelay = RetryDelay 5, -- matches defaultWorkerOptions; runtime tuning",
    "      metrics = Nothing -- runtime configuration; install at call site",
    "    }"
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

-- | Emit the symbol-free deterministic wiring for a process manager + its timer
-- into a @Generated@ module, plus a create-if-absent @ProcessHoles@ module for the
-- behaviour-bearing bodies (the @handle@ reaction, the deadline window, and the
-- fire command). The @Generated@ module contains no keiki symbolic operator (the
-- saga's transducer is the separate aggregate hole), so the firewall invariant
-- holds. The timer worker uses the spec's @max-attempts@ ceiling, never the
-- dangerous @defaultTimerWorkerOptions@ (@Nothing@) default.
scaffoldProcess :: Context -> ProcessNode -> [ScaffoldModule]
scaffoldProcess ctx p =
  [ ScaffoldModule
      { modulePath = T.unpack (T.replace "." "/" genPrefix <> "/Process.hs"),
        moduleText = emitProcessGen sagaGenPrefix genPrefix holePrefix p,
        kind = Generated,
        origin = nodeOrigin "process" (procId p) (procLoc p)
      },
    ScaffoldModule
      { modulePath = T.unpack (T.replace "." "/" holePrefix <> "/ProcessHoles.hs"),
        moduleText = emitProcessHoles genPrefix holePrefix p,
        kind = HoleStub,
        origin = nodeOrigin "process" (procId p) (procLoc p)
      }
  ]
  where
    genPrefix = genPrefixFor ctx (procId p)
    holePrefix = holePrefixFor ctx (procId p)
    sagaGenPrefix = genPrefixFor ctx (pascal (sagaAgg (procSaga p)))

emitProcessGen :: Text -> Text -> Text -> ProcessNode -> Text
emitProcessGen sagaGenPrefix genPrefix _holePrefix p =
  nl $
    [ generatedBanner,
      "module " <> genPrefix <> ".Process",
      "  ( " <> lo <> "ProcessName",
      "  , " <> lo <> "Category",
      "  , " <> lo <> "ProcessWorkerOptions",
      "  , " <> lo <> "TimerRequest",
      "  , " <> lo <> "FireOutcome",
      "  ) where",
      "",
      "import Data.Aeson (Value, object, (.=))",
      "import Data.Text (Text)",
      "import qualified Data.Text as T",
      "import Data.Time (UTCTime)",
      "import Data.UUID (UUID)",
      "import qualified Data.UUID.V5 as UUID.V5",
      "import " <> sagaGenPrefix <> ".EventStream (" <> sagaEventStreamType <> ")",
      "import Keiro.Command (CommandError (..))",
      "import Keiro.Stream qualified as Stream",
      "import Keiro.Timer (TimerId (..), TimerRequest (..))"
    ]
      ++ workerPolicyImports (procPoison p)
      ++ [ "",
           "-- The define-once ProcessManager name (hole-kind 5: referenced, never retyped).",
           lo <> "ProcessName :: Text",
           lo <> "ProcessName = " <> tshow (procName p),
           "",
           "-- The validated saga stream category (hole-kind 5: referenced, never retyped).",
           "-- Saga streams are '<category>-<correlationId>' via Keiro.Stream.entityStream.",
           "-- categoryUnsafe is safe here because keiro-dsl check proved the literal legal.",
           lo <> "Category :: Stream.StreamCategory " <> sagaEventStreamType,
           lo <> "Category = Stream.categoryUnsafe " <> tshow categoryName,
           "",
           "-- Node-level worker policy lowered from the spec. Pass this value to",
           "-- Keiro.ProcessManager.runProcessManagerWorkerWith."
         ]
      ++ workerOptionsLines (lo <> "ProcessWorkerOptions") (procRejected p) (procPoison p)
      ++ [ "",
           "-- The deterministic timer-request builder: id derived from the correlation",
           "-- key (hole-kind 1), processManagerName referenced, payload from the spec.",
           "-- (timer id derived as uuidv5 of " <> tshow (idePrefix (tmId timer)) <> " <> correlationId)",
           lo <> "TimerRequest :: Text -> UTCTime -> TimerRequest",
           lo <> "TimerRequest correlationId fireAtTime =",
           "  TimerRequest",
           "    { timerId = TimerId (namedUuid (" <> tshow (idePrefix (tmId timer)) <> " <> correlationId))",
           "    , processManagerName = " <> lo <> "ProcessName",
           "    , correlationId = correlationId",
           "    , fireAt = fireAtTime",
           "    , payload = " <> payloadExpr (tmPayload timer),
           "    }",
           "",
           "-- The timer-fire disposition table (hole-kind 2), derived from the spec.",
           "-- on-reject => " <> showOutcome (onReject fd) <> " is the benign inversion.",
           "-- A duplicate append reaches on-error unless it is confirmed against the",
           "-- target stream. Use Keiro.ProcessManager.confirmBenignDuplicate:",
           "--   StreamName -> EventId -> CommandError -> Eff es Bool",
           "-- Fold True into the duplicate result and surface False as the failure.",
           lo <> "FireOutcome :: Either CommandError a -> Maybe ()",
           lo <> "FireOutcome result = case result of",
           "  Right{} -> " <> outcomeToMaybe (onOk fd),
           "  Left CommandRejected -> " <> outcomeToMaybe (onReject fd),
           "  Left (CommandAmbiguous _) -> " <> outcomeToMaybe (onAmbiguous fd) <> "  -- explicit definition-bug arm",
           "  Left{} -> " <> outcomeToMaybe (onError fd),
           "",
           "-- max-attempts = " <> tshow' (tmMaxAttempts timer) <> ", dead-letter = " <> tshow (tmDeadLetter timer),
           "-- (the timer worker must pass Just " <> tshow' (tmMaxAttempts timer) <> " to runTimerWorkerWith, never the",
           "--  defaultTimerWorkerOptions Nothing ceiling that retries forever).",
           "",
           "-- deterministic v5 UUID of a correlation-keyed string (hole-kind 1).",
           "namedUuid :: Text -> UUID",
           "namedUuid v = UUID.V5.generateNamed UUID.V5.namespaceURL (map (fromIntegral . fromEnum) (T.unpack v))"
         ]
  where
    lo = lowerFirst (procId p)
    sagaEventStreamType = pascal (sagaAgg (procSaga p)) <> "EventStreamDef"
    categoryName = staticCategory ("process " <> procId p) (sagaCategory (procSaga p))
    timer = procTimer p
    fd = fireDisposition (tmFire timer)

-- | The timer payload, restricted to the spec's literal (@name=\"value\"@)
-- bindings so it compiles in the deterministic builder. Bare fields and
-- ref-valued bindings are input-driven (the agent-written hole), not emitted.
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
    [ "-- HAND-OWNED hole module for the process manager's behaviour-bearing bodies.",
      "-- keiro-dsl creates it once and never overwrites it.",
      "module " <> holePrefix <> ".ProcessHoles () where",
      "",
      "-- HOLE handle: build the ProcessManagerAction (the self-advance",
      "--   '" <> advCommand (hAdvance (procHandle p)) <> "', the dispatch(es), and the timer) from the input.",
      "-- HOLE streams: build streamFor with entityStream " <> lowerFirst (procId p) <> "Category;",
      "--   build target streams with entityStream " <> lowerFirst (procTarget p) <> "CommandCategory. Never concatenate raw stream names.",
      "-- HOLE window: the deadline policy, e.g. surgeWindow :: NominalDiffTime;",
      "--   surgeDeadline observedAt = addUTCTime surgeWindow observedAt  (TIME INJECTED).",
      "-- HOLE fire command: construct " <> fireCommand (tmFire (procTimer p)) <> " for the timer fire,",
      "--   keyed by correlationId; the fired-event-id is the deterministic uuidv5 of",
      "--   " <> tshow (idePrefix (fireFiredEventId (tmFire (procTimer p)))) <> " <> correlationId.",
      "-- NOTE on-duplicate AckOk is sound because the runtime confirms a duplicate",
      "--   event id against the TARGET stream via confirmBenignDuplicate before",
      "--   returning PMCommandDuplicate. Its effective signature is:",
      "--     StreamName -> EventId -> CommandError -> Eff es Bool",
      "--   Hand-rolled paths must call it with the target stream and attempted event id,",
      "--   fold True into the duplicate result, and surface False as the original failure.",
      "--   Never pattern-match DuplicateEvent as success: event ids are globally unique."
    ]

--------------------------------------------------------------------------------
-- Domain module
--------------------------------------------------------------------------------

emitDomain :: Agg -> Text
emitDomain a =
  nl $
    renderGeneratedLanguagePragmas
      ( [ExtDeriveAnyClass | hasSnapshot a]
          <> [ExtDuplicateRecordFields | domainNeedsDuplicateRecordFields a]
          <> [ExtTemplateHaskell]
      )
      ++ [ generatedBanner,
           "module " <> aGenPrefix a <> ".Domain where",
           ""
         ]
      ++ ["import Data.Aeson (FromJSON, ToJSON)" | hasSnapshot a]
      ++ ["import Data.Proxy (Proxy (..))" | not (null (aRegs a))]
      ++ ["import Data.Text (Text)" | AggregateText `elem` aggregateTypes a]
      ++ [ "import GHC.Generics (Generic)",
           "import Keiki.Core (RegFile (..))"
         ]
      ++ ["import Keiki.Shape (CanonicalStateShape, CanonicalTypeName)" | hasSnapshot a]
      ++ generatedNominalDomainImports a
      ++ map ("import " <>) (domainStaticImports a)
      ++ T.lines (renderPlannedImports importPlan)
      ++ [ "import Keiki.Generics.TH (deriveAggregateCtorsAll, deriveWireCtorsAll)",
           "",
           sectionsOf
             [ [emitVertex a],
               map (emitRecord importPlan a) (aCommands a),
               [emitSum (aName a <> "Command") (aCommands a)],
               map (emitRecord importPlan a) (aEvents a),
               [emitSum (aName a <> "Event") (aEvents a)],
               [emitRegsType importPlan a, emitInitialRegs importPlan a],
               [ "$(deriveAggregateCtorsAll ''" <> aName a <> "Command ''" <> aName a <> "Regs)",
                 "",
                 "$(deriveWireCtorsAll ''" <> aName a <> "Event)"
               ]
             ]
         ]
  where
    importPlan = domainImportPlan a

domainNeedsDuplicateRecordFields :: Agg -> Bool
domainNeedsDuplicateRecordFields aggregate = hasDuplicateNames selectorNames
  where
    commandSelectors = concatMap (map (fieldSelector . fst) . rcFields) (aCommands aggregate)
    eventSelectors = concatMap (map (fieldSelector . fst) . rcFields) (aEvents aggregate)
    registerSelectors = map rrName (aRegs aggregate)
    -- deriveWireCtorsAll creates one event TermFields record that repeats each
    -- payload selector, so every field-bearing event contributes twice.
    selectorNames = commandSelectors <> eventSelectors <> eventSelectors <> registerSelectors

hasDuplicateNames :: [Text] -> Bool
hasDuplicateNames names = length names /= Set.size (Set.fromList names)

hasSnapshot :: Agg -> Bool
hasSnapshot = maybe False (const True) . aSnapshot

emitVertex :: Agg -> Text
emitVertex a =
  nl $
    [ "data " <> aVertexType a <> " = " <> T.intercalate " | " (map (vertexCtor a . stName) (aStates a)),
      "  deriving stock (Generic, Eq, Ord, Show, Enum, Bounded)"
    ]
      ++ ["  deriving anyclass (ToJSON, FromJSON)" | hasSnapshot a]
      ++ [ line
         | hasSnapshot a,
           line <-
             [ "instance CanonicalStateShape " <> aVertexType a,
               "instance CanonicalTypeName " <> aVertexType a
             ]
         ]

emitRecord :: HaskellImportPlan -> Agg -> ResolvedCtor -> Text
emitRecord importPlan a rc =
  nl $
    [ "data " <> rcName rc <> "Data = " <> rcName rc <> "Data"
    ]
      ++ recordFields [(fieldSelector identity, renderDomainType importPlan a fieldType) | (identity, fieldType) <- rcFields rc]
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
      [] -> ("data " <> tyName, [])
      (c : cs) ->
        ( "data " <> tyName <> " = " <> arm c,
          ["  | " <> arm c2 | c2 <- cs]
        )

emitRegsType :: HaskellImportPlan -> Agg -> Text
emitRegsType importPlan a =
  nl $
    ["type " <> aName a <> "Regs ="]
      ++ regListLines importPlan a (aRegs a)

regListLines :: HaskellImportPlan -> Agg -> [ResolvedRegister] -> [Text]
regListLines _ _ [] = ["  '[]"]
regListLines importPlan a rs =
  [ lead i <> "'(" <> tshow (rrName r) <> ", " <> renderDomainType importPlan a (rrType r) <> ")"
  | (i, r) <- zip [(0 :: Int) ..] rs
  ]
    ++ ["   ]"]
  where
    lead 0 = "  '[ "
    lead _ = "   , "

emitInitialRegs :: HaskellImportPlan -> Agg -> Text
emitInitialRegs importPlan a =
  nl $
    [ "initial" <> aName a <> "Regs :: RegFile " <> aName a <> "Regs",
      "initial" <> aName a <> "Regs ="
    ]
      ++ chain (aRegs a)
  where
    chain [] = ["  RNil"]
    chain rs =
      [ "  RCons (Proxy @" <> tshow (rrName r) <> ") " <> regInitialValue importPlan a r <> " $"
      | r <- init rs
      ]
        ++ ["  RCons (Proxy @" <> tshow (rrName lastR) <> ") " <> regInitialValue importPlan a lastR <> " RNil"]
      where
        lastR = last rs

-- | The Haskell initial value for a register, by the category of its type.
regInitialValue :: HaskellImportPlan -> Agg -> ResolvedRegister -> Text
regInitialValue importPlan aggregate register = case rrInitial register of
  InitialId name -> case find ((== name) . resolvedNominalName) (aGeneratedNominals aggregate) >>= generatedIdSampleHaskell aggregate of
    Just value -> value
    Nothing -> renderRegisterInitial (rrInitial register)
  InitialNominal _ value -> renderReferenceOrDie importPlan (qualifiedValueReference value)
  InitialMapped _ value -> renderReferenceOrDie importPlan (qualifiedValueReference value)
  _ -> renderRegisterInitial (rrInitial register)

domainImportPlan :: Agg -> HaskellImportPlan
domainImportPlan aggregate =
  planImportsOrDie
    (aGenPrefix aggregate <> ".Domain")
    localDeclarations
    (Set.unions (map aggregateSourceReferences (domainAggregateSources aggregate)) <> initialReferences)
  where
    localDeclarations =
      Set.fromList
        ( [ aVertexType aggregate,
            aName aggregate <> "Command",
            aName aggregate <> "Event",
            aName aggregate <> "Regs"
          ]
            <> [rcName constructor <> "Data" | constructor <- aCommands aggregate <> aEvents aggregate]
            <> map resolvedNominalName (aGeneratedNominals aggregate)
        )
    initialReferences =
      Set.fromList
        ( [ qualifiedValueReference initialValue
          | declaration <- mappedUses aggregate,
            initialValue <- maybeToListText (mappedInitial declaration)
          ]
            <> [ qualifiedValueReference initialValue
               | resolvedType <- aggregateTypes aggregate,
                 AggregateNominal nominal <- [resolvedType],
                 ConsumerNominal binding <- [resolvedNominalOwnership nominal],
                 initialValue <- maybeToListText (consumerNominalInitial binding)
               ]
        )

generatedNominalDomainImports :: Agg -> [Text]
generatedNominalDomainImports aggregate
  | null nominals = []
  | otherwise =
      [ "import "
          <> generatedNominalModule (aContext aggregate)
          <> " ("
          <> T.intercalate ", " (concatMap importsFor nominals)
          <> ")"
      ]
  where
    nominals = stableNominals (aGeneratedNominals aggregate)
    importsFor nominal = case resolvedNominalRepresentation nominal of
      IdRepresentation prefix
        | Just _ <- idDomainContractFor (aLanguageContract aggregate) prefix ->
            resolvedNominalName nominal
              : ["parse" <> resolvedNominalName nominal | needsParser nominal]
      _ -> [resolvedNominalName nominal <> " (..)"]
    needsParser nominal =
      any
        (\register -> rrType register == AggregateNominal nominal && case rrInitial register of InitialId {} -> True; _ -> False)
        (aRegs aggregate)

domainStaticImports :: Agg -> [Text]
domainStaticImports aggregate =
  Set.toAscList (Set.delete timeTypeImport sourceImports <> Set.fromList timeImports)
  where
    sourceImports = Set.unions (map aggregateSourceStaticImports (domainAggregateSources aggregate))
    timeTypeImport = "Data.Time.Clock (UTCTime)"
    usesTimeType = AggregateTime `elem` aggregateTypes aggregate
    usesTimeLiteral = any (\register -> case rrInitial register of InitialTime {} -> True; _ -> False) (aRegs aggregate)
    timeImports
      | usesTimeLiteral =
          [ "Data.Time.Calendar (fromGregorian)",
            "Data.Time.Clock (UTCTime (..), picosecondsToDiffTime)"
          ]
      | usesTimeType = [timeTypeImport]
      | otherwise = []

domainAggregateSources :: Agg -> [AggregateHaskellSource]
domainAggregateSources aggregate =
  map (aggregateConsumerHaskellSource (aSymbols aggregate)) (aggregateTypes aggregate)

aggregateTypes :: Agg -> [ResolvedAggregateType]
aggregateTypes aggregate =
  map snd (concatMap rcFields (aCommands aggregate <> aEvents aggregate)) <> map rrType (aRegs aggregate)

mappedUses :: Agg -> [ResolvedMappedDecl]
mappedUses a =
  [ declaration
  | resolvedType <-
      map snd (concatMap rcFields (aCommands a <> aEvents a))
        <> map rrType (aRegs a),
    declaration <- maybeToListText (mappedDeclFor a resolvedType)
  ]

mappedDeclFor :: Agg -> ResolvedAggregateType -> Maybe ResolvedMappedDecl
mappedDeclFor a resolvedType = do
  key <- case resolvedType of
    AggregateMapped mappedKey -> Just mappedKey
    _ -> Nothing
  graph <- aTypeGraph a
  Map.lookup key (tgDeclarations graph)

mappedInitial :: ResolvedMappedDecl -> Maybe QualifiedValueName
mappedInitial (ResolvedStructural declaration _) = sdInitial declaration
mappedInitial (ResolvedOpaque declaration) = odInitial declaration

renderDomainType :: HaskellImportPlan -> Agg -> ResolvedAggregateType -> Text
renderDomainType importPlan aggregate resolvedType =
  either
    (error . ("validated aggregate Haskell reference failed: " <>) . show)
    id
    (renderAggregateHaskellSource importPlan (aggregateConsumerHaskellSource (aSymbols aggregate) resolvedType))

maybeToListText :: Maybe value -> [value]
maybeToListText = maybe [] pure

--------------------------------------------------------------------------------
-- Codec module
--------------------------------------------------------------------------------

emitCodec :: Agg -> Text
emitCodec a =
  nl $
    renderGeneratedLanguagePragmas [ExtOverloadedRecordDot | codecUsesRecordDot a]
      ++ [ generatedBanner,
           "module " <> aGenPrefix a <> ".Codec (",
           "    " <> lowerFirst (aName a) <> "Codec,",
           "    parse" <> aName a <> "Event,",
           "    encode" <> aName a <> "Event,"
         ]
      ++ concatMap mappedExports (codecMappedDeclarations a)
      ++ [ ") where",
           "",
           "import " <> aGenPrefix a <> ".Domain"
         ]
      ++ generatedNominalCodecImports (aggregateCheckedService a) (aContext a) (codecGeneratedNominals a)
      ++ ["import Control.Monad (unless)" | codecUsesUnknownFieldRejection a]
      ++ [codecAesonImport a]
      ++ ["import Data.Aeson.Key qualified as Key" | codecUsesKeyMap a]
      ++ ["import Data.Aeson.KeyMap qualified as KeyMap" | codecUsesKeyMap a]
      ++ [ "import Data.Aeson.Types (" <> T.intercalate ", " (codecAesonTypesImports a) <> ")",
           "import Data.List.NonEmpty (NonEmpty (..))",
           "import Data.List.NonEmpty qualified as NonEmpty"
         ]
      ++ ( if codecUsesMap a
             then ["import Data.Map.Strict (Map)", "import Data.Map.Strict qualified as Map"]
             else []
         )
      ++ [ "import Data.Text (Text)",
           "import qualified Data.Text as T"
         ]
      ++ ["import Data.KindID qualified as KindID" | hasConsumerNominalIdCodec a]
      ++ ["import Keiro.Codec.IdDomain (typeIdV7Domain, validateIdDomainText)" | hasEnforcedConsumerNominalIdCodec a]
      ++ ["import Keiro.Codec.Nominal (nominalFromRepresentation, nominalToRepresentation)" | hasConsumerNominalCodec a]
      ++ ["import Keiro.Codec.Structural (bindingFromShape, bindingToShape)" | hasStructuralMappedCodec a]
      ++ [ "import Keiro.Codec (Codec (..), EventType (..))",
           upcasterImport a
         ]
      ++ [nl (map ("import " <>) (codecMappedImports a)) | hasMappedCodec a]
      ++ [nl (map ("import " <>) (codecNominalImports a)) | hasConsumerNominalCodec a]
      ++ T.lines (renderPlannedImports importPlan)
      ++ [ "",
           emitEnumParsers a,
           emitConsumerNominalParsers importPlan a
         ]
      ++ [emitMappedCodecs importPlan a | hasMappedCodec a]
      ++ [ "",
           emitEventTypes a,
           "",
           emitCodecValue a,
           "",
           emitEncode importPlan a,
           "",
           emitDecode importPlan a,
           "",
           "mapLeftText :: Either String b -> Either Text b",
           "mapLeftText = either (Left . T.pack) Right",
           "",
           "renderExpectedEventTypes :: NonEmpty EventType -> String",
           "renderExpectedEventTypes =",
           "  T.unpack",
           "    . T.intercalate \", \"",
           "    . map (\\(EventType eventTypeName) -> eventTypeName)",
           "    . NonEmpty.toList"
         ]
      ++ ( if codecUsesOptionalFieldHelper a
             then
               [ "",
                 "parseOptionalField :: Parser fieldValue -> (Value -> Parser fieldValue) -> KeyMap.KeyMap Value -> Key.Key -> Parser fieldValue",
                 "parseOptionalField onMissing parseItem objectValue key =",
                 "  case KeyMap.lookup key objectValue of",
                 "    Nothing -> onMissing",
                 "    Just _ -> explicitParseField parseItem objectValue key"
               ]
             else []
         )
      ++ ( if codecUsesUnknownFieldRejection a
             then
               [ "",
                 "rejectUnknownFields :: String -> [Text] -> KeyMap.KeyMap Value -> Parser ()",
                 "rejectUnknownFields label allowed objectValue =",
                 "  unless (null extras) (fail (label <> \" contains unknown fields: \" <> show extras))",
                 "  where",
                 "    extras = filter (`notElem` allowed) (map Key.toText (KeyMap.keys objectValue))"
               ]
             else []
         )
  where
    importPlan = codecImportPlan a
    mappedExports (ResolvedStructural declaration _) =
      [ "    encode" <> sdName declaration <> "Mapped,",
        "    decode" <> sdName declaration <> "Mapped,"
      ]
    mappedExports ResolvedOpaque {} = []

codecUsesRecordDot :: Agg -> Bool
codecUsesRecordDot = any (not . null . rcFields) . aEvents

hasMappedCodec :: Agg -> Bool
hasMappedCodec = not . null . codecMappedDeclarations

hasStructuralMappedCodec :: Agg -> Bool
hasStructuralMappedCodec = any isStructural . codecMappedDeclarations
  where
    isStructural ResolvedStructural {} = True
    isStructural ResolvedOpaque {} = False

codecAesonImport :: Agg -> Text
codecAesonImport aggregate =
  "import Data.Aeson (" <> T.intercalate ", " imports <> ")"
  where
    imports =
      [if codecUsesValueConstructors aggregate then "Value (..)" else "Value"]
        <> ["object" | codecUsesObject aggregate]
        <> ["parseJSON" | codecUsesParseJSON aggregate]
        <> ["toJSON" | codecUsesToJSON aggregate]
        <> ["withObject"]
        <> ["withText" | codecUsesWithText aggregate]
        <> ["(.:)" | codecUsesDotColon aggregate]
        <> ["(.=)" | codecUsesObject aggregate]

codecUsesObject :: Agg -> Bool
codecUsesObject aggregate =
  not (null (aEvents aggregate)) || any structuralUsesObject (codecMappedDeclarations aggregate)
  where
    structuralUsesObject (ResolvedStructural _ shape) = case shape of REnum {} -> False; _ -> True
    structuralUsesObject ResolvedOpaque {} = False

codecAesonTypesImports :: Agg -> [Text]
codecAesonTypesImports aggregate =
  ["Parser" | codecUsesParserType aggregate]
    <> ["explicitParseField" | codecUsesExplicitParseField aggregate]
    <> ["parseEither"]

codecUsesParserType :: Agg -> Bool
codecUsesParserType aggregate =
  codecUsesWithText aggregate || hasStructuralMappedCodec aggregate

codecUsesExplicitParseField :: Agg -> Bool
codecUsesExplicitParseField aggregate =
  codecUsesWithText aggregate || any structuralUsesExplicitParseField (codecMappedDeclarations aggregate)
  where
    structuralUsesExplicitParseField (ResolvedStructural _ shape) = case shape of
      RRecord _ _ fields -> not (null fields)
      REnum {} -> False
      RUnion {} -> True
    structuralUsesExplicitParseField ResolvedOpaque {} = False

codecUsesWithText :: Agg -> Bool
codecUsesWithText aggregate =
  any nominalUsesWithText (codecGeneratedNominals aggregate <> codecConsumerNominals aggregate)
    || any mappedUsesWithText (codecMappedDeclarations aggregate)
  where
    nominalUsesWithText nominal = case resolvedNominalRepresentation nominal of
      EnumRepresentation {} -> True
      IdRepresentation {} -> case resolvedNominalOwnership nominal of ConsumerNominal {} -> True; GeneratedNominal -> False
      ScalarRepresentation {} -> False
    mappedUsesWithText (ResolvedStructural _ shape) = case shape of
      REnum {} -> True
      RUnion {} -> True
      RRecord {} -> False
    mappedUsesWithText ResolvedOpaque {} = False

codecUsesDotColon :: Agg -> Bool
codecUsesDotColon aggregate = any fieldUsesDotColon (concatMap rcFields (aEvents aggregate))
  where
    fieldUsesDotColon (_, resolvedType) = case resolvedType of
      AggregateNominal nominal -> case (resolvedNominalOwnership nominal, resolvedNominalRepresentation nominal) of
        (GeneratedNominal, EnumRepresentation {}) -> False
        (ConsumerNominal {}, IdRepresentation {}) -> False
        (ConsumerNominal {}, EnumRepresentation {}) -> False
        _ -> True
      _ -> case fieldCat aggregate resolvedType of
        MappedStructuralCat {} -> False
        _ -> True

codecUsesKeyMap :: Agg -> Bool
codecUsesKeyMap aggregate = codecUsesOptionalFieldHelper aggregate || codecUsesUnknownFieldRejection aggregate

codecUsesUnknownFieldRejection :: Agg -> Bool
codecUsesUnknownFieldRejection = any declarationRejectsUnknown . codecMappedDeclarations
  where
    declarationRejectsUnknown (ResolvedStructural _ shape) = case shape of
      RRecord _ RejectUnknown _ -> True
      RUnion encoding _ -> ueUnknownFields encoding == RejectUnknown
      _ -> False
    declarationRejectsUnknown ResolvedOpaque {} = False

codecUsesMap :: Agg -> Bool
codecUsesMap = any declarationUsesMap . codecMappedDeclarations
  where
    declarationUsesMap (ResolvedStructural _ shape) = any typeUsesMap (shapeTypeExpressions shape)
    declarationUsesMap ResolvedOpaque {} = False

codecUsesParseJSON :: Agg -> Bool
codecUsesParseJSON aggregate = any (declarationUsesAesonConversion aggregate) (codecMappedDeclarations aggregate)

codecUsesToJSON :: Agg -> Bool
codecUsesToJSON aggregate =
  any directOpaqueField (concatMap rcFields (aEvents aggregate))
    || any (declarationUsesAesonConversion aggregate) (codecMappedDeclarations aggregate)
  where
    directOpaqueField (_, resolvedType) = case fieldCat aggregate resolvedType of MappedOpaqueCat {} -> True; _ -> False

codecUsesValueConstructors :: Agg -> Bool
codecUsesValueConstructors = any declarationUsesConstructors . codecMappedDeclarations
  where
    declarationUsesConstructors (ResolvedStructural _ shape) =
      case shape of REnum {} -> True; _ -> any typeUsesOptional (shapeTypeExpressions shape)
    declarationUsesConstructors ResolvedOpaque {} = False

declarationUsesAesonConversion :: Agg -> ResolvedMappedDecl -> Bool
declarationUsesAesonConversion aggregate (ResolvedStructural _ shape) =
  any (typeUsesAesonConversion aggregate) (shapeTypeExpressions shape)
declarationUsesAesonConversion _ ResolvedOpaque {} = False

shapeTypeExpressions :: ResolvedMappedShape -> [ResolvedTypeExpr]
shapeTypeExpressions = \case
  RRecord _ _ fields -> map rwfType fields
  REnum {} -> []
  RUnion _ arms -> mapMaybe rwaPayload arms

typeUsesMap :: ResolvedTypeExpr -> Bool
typeUsesMap =
  foldTypeExpr
    TypeExprAlgebra
      { onText = False,
        onInt = False,
        onInteger = False,
        onBool = False,
        onNatural = False,
        onTime = False,
        onJson = False,
        onOptional = id,
        onList = id,
        onMap = const True,
        onRef = const False
      }

typeUsesOptional :: ResolvedTypeExpr -> Bool
typeUsesOptional =
  foldTypeExpr
    TypeExprAlgebra
      { onText = False,
        onInt = False,
        onInteger = False,
        onBool = False,
        onNatural = False,
        onTime = False,
        onJson = False,
        onOptional = const True,
        onList = id,
        onMap = id,
        onRef = const False
      }

typeUsesAesonConversion :: Agg -> ResolvedTypeExpr -> Bool
typeUsesAesonConversion aggregate =
  foldTypeExpr
    TypeExprAlgebra
      { onText = True,
        onInt = True,
        onInteger = True,
        onBool = True,
        onNatural = True,
        onTime = True,
        onJson = False,
        onOptional = id,
        onList = const True,
        onMap = const True,
        onRef = \key -> case aTypeGraph aggregate >>= \graph -> Map.lookup key (tgDeclarations graph) of
          Just ResolvedOpaque {} -> True
          _ -> False
      }

codecUsesOptionalFieldHelper :: Agg -> Bool
codecUsesOptionalFieldHelper aggregate =
  any structuralHasOptionalField (codecMappedDeclarations aggregate)
  where
    structuralHasOptionalField (ResolvedStructural _ (RRecord _ _ fields)) =
      any ((== POptional) . rwfPresence) fields
    structuralHasOptionalField (ResolvedStructural _ _) = False
    structuralHasOptionalField ResolvedOpaque {} = False

hasConsumerNominalCodec :: Agg -> Bool
hasConsumerNominalCodec = not . null . codecConsumerNominals

hasConsumerNominalIdCodec :: Agg -> Bool
hasConsumerNominalIdCodec aggregate =
  any
    (\nominal -> case resolvedNominalRepresentation nominal of IdRepresentation {} -> True; _ -> False)
    (codecConsumerNominals aggregate)

hasEnforcedConsumerNominalIdCodec :: Agg -> Bool
hasEnforcedConsumerNominalIdCodec aggregate =
  any
    ( \nominal -> case resolvedNominalRepresentation nominal of
        IdRepresentation prefix -> isJust (idDomainContractFor (aLanguageContract aggregate) prefix)
        _ -> False
    )
    (codecConsumerNominals aggregate)

emitEnumParsers :: Agg -> Text
emitEnumParsers a =
  sectionsOf
    [ [emitEnumParser nominal | nominal <- codecGeneratedNominals a, EnumRepresentation {} <- [resolvedNominalRepresentation nominal]]
    ]

emitEnumParser :: ResolvedNominalType -> Text
emitEnumParser nominal = case resolvedNominalRepresentation nominal of
  EnumRepresentation constructors ->
    nl $
      [ "parse" <> name <> " :: Text -> Parser " <> name,
        "parse" <> name <> " = \\case"
      ]
        ++ ["  " <> tshow wire <> " -> pure " <> constructor | (constructor, wire) <- NE.toList constructors]
        ++ ["  tag -> " <> renderUnknownFailure name "tag" (map snd (NE.toList constructors))]
  _ -> error "non-enum reached generated enum parser emission"
  where
    name = resolvedNominalName nominal

emitConsumerNominalParsers :: HaskellImportPlan -> Agg -> Text
emitConsumerNominalParsers importPlan aggregate = sectionsOf [map emitParser (codecConsumerNominals aggregate)]
  where
    emitParser nominal = case (resolvedNominalRepresentation nominal, resolvedNominalOwnership nominal) of
      (IdRepresentation prefix, ConsumerNominal binding) ->
        nl $
          [ parserName nominal <> " :: Text -> Parser " <> renderReferenceOrDie importPlan (haskellTypeReference (consumerNominalHaskell binding))
          ]
            <> parserBody nominal prefix binding
      (EnumRepresentation constructors, ConsumerNominal binding) ->
        nl $
          [ parserName nominal <> " :: Text -> Parser " <> renderReferenceOrDie importPlan (haskellTypeReference (consumerNominalHaskell binding)),
            parserName nominal <> " = \\case"
          ]
            <> [ "  "
                   <> tshow wire
                   <> " -> pure (nominalFromRepresentation "
                   <> renderReferenceOrDie importPlan (qualifiedValueReference (consumerNominalBinding binding))
                   <> " "
                   <> renderReferenceOrDie importPlan (nominalRepresentationConstructorReference (aContext aggregate) nominal constructor)
                   <> ")"
               | (constructor, wire) <- NE.toList constructors
               ]
            <> ["  tag -> " <> renderUnknownFailure (resolvedNominalName nominal <> " wire value") "tag" (map snd (NE.toList constructors))]
      _ -> ""
    parserName nominal = "parse" <> resolvedNominalName nominal <> "Nominal"
    parserBody nominal prefix binding = case idDomainContractFor (aLanguageContract aggregate) prefix of
      Nothing ->
        [ parserName nominal <> " input = case KindID.parseText @" <> tshow prefix <> " input of",
          "  Left reason -> fail (show reason)",
          "  Right representation -> pure (nominalFromRepresentation " <> renderReferenceOrDie importPlan (qualifiedValueReference (consumerNominalBinding binding)) <> " representation)"
        ]
      Just _ ->
        [ parserName nominal <> " input = case validateIdDomainText (typeIdV7Domain " <> tshow prefix <> ") input of",
          "  Left reason -> fail (show reason)",
          "  Right () -> case KindID.parseText @" <> tshow prefix <> " input of",
          "    Left reason -> fail (show reason)",
          "    Right representation -> pure (nominalFromRepresentation " <> renderReferenceOrDie importPlan (qualifiedValueReference (consumerNominalBinding binding)) <> " representation)"
        ]

emitCodecValue :: Agg -> Text
emitCodecValue a =
  nl $
    [ lowerFirst (aName a) <> "Codec :: Codec " <> aName a <> "Event",
      lowerFirst (aName a) <> "Codec =",
      "  Codec",
      "    { eventTypes = " <> eventTypesName a,
      "    , eventType = \\case"
    ]
      ++ ["        " <> rcName e <> "{} -> EventType " <> tshow (rcName e) | e <- aEvents a]
      ++ [ "    , schemaVersion = " <> tshow' (maxEventVersion a),
           "    , encode = encode" <> aName a <> "Event",
           "    , decode = parse" <> aName a <> "Event",
           "    , upcasters = " <> upcastersExpr a,
           "    }"
         ]
      ++ upcasterRungDecls a

emitEventTypes :: Agg -> Text
emitEventTypes aggregate =
  nl
    [ eventTypesName aggregate <> " :: NonEmpty EventType",
      eventTypesName aggregate <> " = " <> eventTypesExpr
    ]
  where
    eventTypesExpr = case map rcName (aEvents aggregate) of
      [] -> "error \"no events\""
      event : rest -> "EventType " <> tshow event <> " :| [" <> T.intercalate ", " (map (("EventType " <>) . tshow) rest) <> "]"

eventTypesName :: Agg -> Text
eventTypesName aggregate = lowerFirst (aName aggregate) <> "EventTypes"

-- | The codec's @schemaVersion@: the maximum declared event version (EP-2).
maxEventVersion :: Agg -> Int
maxEventVersion a = maximum (1 : map rcVersion (aEvents a))

-- | One @(sourceVersion, upcasterName)@ entry per event that declares an
-- @upcast from@. The upcaster name is per-event (e.g. @upcastFooV1@) and its
-- body is a hole in the hand-owned Holes module.
upcasterEntries :: Agg -> [(Int, Text, Text)]
upcasterEntries a =
  [ (m, rcName e, "upcast" <> rcName e <> "V" <> tshow' m)
  | e <- aEvents a,
    Just m <- [rcUpcastFrom e]
  ]

upcastersExpr :: Agg -> Text
upcastersExpr a =
  "[" <> T.intercalate ", " ["(" <> tshow' m <> ", upcastRungV" <> tshow' m <> ")" | (m, _) <- upcasterRungs a] <> "]"

-- | Group event-specific holes into one migration rung per aggregate-global
-- source version.  Event metadata stamps every kind with the aggregate's
-- schema version, so a rung must explicitly pass foreign event kinds through.
upcasterRungs :: Agg -> [(Int, [(Text, Text)])]
upcasterRungs a =
  [ (source, [(eventName, fn) | (_, eventName, fn) <- entries])
  | entries@((source, _, _) : _) <- groupBy sameSource (sortOn firstSource (upcasterEntries a))
  ]
  where
    firstSource (source, _, _) = source
    sameSource (source, _, _) (otherSource, _, _) = source == otherSource

upcasterRungDecls :: Agg -> [Text]
upcasterRungDecls a = concatMap rung (upcasterRungs a)
  where
    rung (source, entries) =
      [ "",
        "upcastRungV" <> tshow' source <> " :: EventType -> Value -> Either Text Value"
      ]
        ++ [ "upcastRungV" <> tshow' source <> " (EventType " <> tshow eventName <> ") value = " <> fn <> " value"
           | (eventName, fn) <- entries
           ]
        ++ [ "-- Kinds whose shape did not change at this rung pass through unchanged; their",
             "-- stamped version is aggregate-global, not their own shape history.",
             "upcastRungV" <> tshow' source <> " _ value = Right value"
           ]

-- | When the codec references upcasters, it imports their (hole) definitions
-- from the hand-owned Holes module.
upcasterImport :: Agg -> Text
upcasterImport a = case upcasterEntries a of
  [] -> ""
  es -> "import " <> aHolePrefix a <> ".Holes (" <> T.intercalate ", " [fn | (_, _, fn) <- es] <> ")"

emitEncode :: HaskellImportPlan -> Agg -> Text
emitEncode importPlan a =
  nl $
    [ "encode" <> aName a <> "Event :: " <> aName a <> "Event -> Value",
      "encode" <> aName a <> "Event = \\case"
    ]
      ++ concatMap encodeArm (aEvents a)
  where
    encodeArm e =
      [ "  " <> rcName e <> " payload ->",
        "    object"
      ]
        ++ [ lead i <> kv
           | (i, kv) <- zip [(0 :: Int) ..] (("\"kind\" .= (" <> tshow (rcName e) <> " :: Text)") : map encodeField (rcFields e))
           ]
        ++ ["      ]"]
    lead 0 = "      [ "
    lead _ = "      , "
    encodeField (identity, ty) =
      tshow (fieldWireKey identity)
        <> " .= "
        <> encodeFieldValue (fieldSelector identity) ty
    encodeFieldValue selector ty = case ty of
      AggregateNominal nominal -> encodeNominalValue nominal ("payload." <> selector)
      _ -> case fieldCat a ty of
        MappedStructuralCat {} -> encodeMapped ty ("payload." <> selector)
        MappedOpaqueCat {} -> encodeMapped ty ("payload." <> selector)
        _ -> "payload." <> selector
    encodeMapped (AggregateMapped key) value = case aTypeGraph a of
      Nothing -> error "mapped aggregate field has no resolved type graph"
      Just graph ->
        renderMappedEncode graph ConsumerValueBoundary (mappedCodecPlanOrDie graph (RRef key)) value
    encodeMapped _ _ = error "non-mapped aggregate type reached mapped codec lowering"
    encodeNominalValue nominal value = case resolvedNominalOwnership nominal of
      GeneratedNominal -> case resolvedNominalRepresentation nominal of
        IdRepresentation {} -> lowerFirst (resolvedNominalName nominal) <> "Text " <> value
        EnumRepresentation {} -> lowerFirst (resolvedNominalName nominal) <> "Text " <> value
        ScalarRepresentation {} -> value
      ConsumerNominal binding -> case resolvedNominalRepresentation nominal of
        IdRepresentation {} -> "KindID.toText (nominalToRepresentation " <> bindingName binding <> " " <> value <> ")"
        EnumRepresentation {} ->
          renderReferenceOrDie importPlan (nominalRepresentationEncoderReference (aContext a) nominal)
            <> " (nominalToRepresentation "
            <> bindingName binding
            <> " "
            <> value
            <> ")"
        ScalarRepresentation {} -> "nominalToRepresentation " <> bindingName binding <> " " <> value
    bindingName = renderReferenceOrDie importPlan . qualifiedValueReference . consumerNominalBinding

emitDecode :: HaskellImportPlan -> Agg -> Text
emitDecode importPlan a =
  nl $
    [ "parse" <> aName a <> "Event :: EventType -> Value -> Either Text " <> aName a <> "Event",
      "parse" <> aName a <> "Event (EventType tag) = mapLeftText . parseEither (withObject " <> tshow (aName a <> "Event") <> " go)",
      "  where",
      "    go o = do",
      "      case tag of"
    ]
      ++ concatMap decodeArm (aEvents a)
      ++ ["        _ -> " <> renderUnknownEventTypeFailure a "tag"]
  where
    decodeArm e =
      ["        " <> tshow (rcName e) <> " ->"]
        ++ case rcFields e of
          [] -> ["          pure (" <> rcName e <> " " <> rcName e <> "Data)"]
          fields ->
            [ "          " <> rcName e,
              "            <$> ( " <> rcName e <> "Data"
            ]
              ++ [ (if index == 0 then "                    <$> " else "                    <*> ") <> decodeField field
                 | (index, field) <- zip [(0 :: Int) ..] fields
                 ]
              ++ ["                )"]
    decodeField (identity, ty) = case ty of
      AggregateNominal nominal -> decodeNominalField (fieldWireKey identity) nominal
      _ -> case fieldCat a ty of
        MappedStructuralCat {} -> decodeMapped ty (fieldWireKey identity)
        MappedOpaqueCat {} -> "o .: " <> tshow (fieldWireKey identity)
        _ -> "o .: " <> tshow (fieldWireKey identity)
    decodeMapped (AggregateMapped mappedKey) key = case aTypeGraph a of
      Nothing -> error "mapped aggregate field has no resolved type graph"
      Just graph ->
        "explicitParseField "
          <> renderMappedParse graph ConsumerValueBoundary (mappedCodecPlanOrDie graph (RRef mappedKey))
          <> " o "
          <> tshow key
    decodeMapped _ _ = error "non-mapped aggregate type reached mapped codec lowering"
    decodeNominalField name nominal = case resolvedNominalOwnership nominal of
      GeneratedNominal -> case resolvedNominalRepresentation nominal of
        IdRepresentation prefix -> case idDomainContractFor (aLanguageContract a) prefix of
          Nothing -> "(" <> resolvedNominalName nominal <> " <$> o .: " <> tshow name <> ")"
          Just _ -> "(" <> legacyNominalConstructorName nominal <> " <$> o .: " <> tshow name <> ")"
        EnumRepresentation {} ->
          "explicitParseField (withText "
            <> tshow (resolvedNominalName nominal)
            <> " parse"
            <> resolvedNominalName nominal
            <> ") o "
            <> tshow name
        ScalarRepresentation {} -> "o .: " <> tshow name
      ConsumerNominal binding -> case resolvedNominalRepresentation nominal of
        IdRepresentation {} -> consumerNominalFieldParser name nominal
        EnumRepresentation {} -> consumerNominalFieldParser name nominal
        ScalarRepresentation {} -> "(nominalFromRepresentation " <> renderReferenceOrDie importPlan (qualifiedValueReference (consumerNominalBinding binding)) <> " <$> o .: " <> tshow name <> ")"
    consumerNominalFieldParser fieldName nominal =
      "explicitParseField (withText "
        <> tshow (resolvedNominalName nominal)
        <> " parse"
        <> resolvedNominalName nominal
        <> "Nominal) o "
        <> tshow fieldName

codecConsumerNominals :: Agg -> [ResolvedNominalType]
codecConsumerNominals aggregate =
  Map.elems . Map.fromList $
    [ (resolvedNominalName nominal, nominal)
    | event <- aEvents aggregate,
      (_, AggregateNominal nominal) <- rcFields event,
      ConsumerNominal {} <- [resolvedNominalOwnership nominal]
    ]

codecGeneratedNominals :: Agg -> [ResolvedNominalType]
codecGeneratedNominals aggregate =
  generatedNominalsInTypes
    [ resolvedType
    | event <- aEvents aggregate,
      (_, resolvedType) <- rcFields event
    ]

codecImportPlan :: Agg -> HaskellImportPlan
codecImportPlan aggregate =
  planImportsOrDie
    (aGenPrefix aggregate <> ".Codec")
    (Set.fromList [aName aggregate <> "Event"])
    (Set.fromList (nominalReferences <> mappedReferences <> nominalRepresentationReferences <> shapeReferences))
  where
    nominalReferences =
      [ reference
      | nominal <- codecConsumerNominals aggregate,
        ConsumerNominal binding <- [resolvedNominalOwnership nominal],
        reference <- qualifiedValueReference (consumerNominalBinding binding) : nominalParserTypeReferences nominal binding
      ]
    nominalParserTypeReferences nominal binding = case resolvedNominalRepresentation nominal of
      IdRepresentation {} -> [haskellTypeReference (consumerNominalHaskell binding)]
      EnumRepresentation {} -> [haskellTypeReference (consumerNominalHaskell binding)]
      ScalarRepresentation {} -> []
    mappedReferences =
      [ reference
      | ResolvedStructural declaration _ <- codecMappedDeclarations aggregate,
        reference <-
          [ haskellTypeReference (sdHaskell declaration),
            qualifiedValueReference (sdBinding declaration)
          ]
      ]
    nominalRepresentationReferences =
      [ reference
      | nominal <- codecConsumerNominals aggregate,
        EnumRepresentation constructors <- [resolvedNominalRepresentation nominal],
        reference <-
          nominalRepresentationEncoderReference (aContext aggregate) nominal
            : [ nominalRepresentationConstructorReference (aContext aggregate) nominal constructor
              | (constructor, _) <- NE.toList constructors
              ]
      ]
    shapeReferences =
      [ reference
      | ResolvedStructural declaration shape <- codecMappedDeclarations aggregate,
        reference <- structuralShapeReferences (aContext aggregate) declaration shape
      ]

codecNominalImports :: Agg -> [Text]
codecNominalImports _ = []

codecMappedImports :: Agg -> [Text]
codecMappedImports a = case aTypeGraph a of
  Nothing -> []
  Just graph ->
    sort . nub $
      [ hsModule (odHaskell declaration) <> " ()"
      | ResolvedOpaque declaration <- codecMappedDeclarations a
      ]
        <> [ hsModule (odHaskell declaration) <> " ()"
           | ResolvedStructural _ shape <- codecMappedDeclarations a,
             key <- directShapeRefs shape,
             Just (ResolvedOpaque declaration) <- [Map.lookup key (tgDeclarations graph)]
           ]

codecMappedDeclarations :: Agg -> [ResolvedMappedDecl]
codecMappedDeclarations a = case aTypeGraph a of
  Nothing -> []
  Just graph ->
    mapMaybe (\key -> Map.lookup key (tgDeclarations graph)) (sort (Map.keys selected))
    where
      roots =
        [ key
        | event <- aEvents a,
          (_, AggregateMapped key) <- rcFields event,
          Map.member key (tgDeclarations graph)
        ]
      selected =
        Map.fromList
          [ (key, ())
          | root <- roots,
            key <- root : maybe [] (Map.keys . Map.fromSet (const ())) (Map.lookup root (tgReachability graph))
          ]

directShapeRefs :: ResolvedMappedShape -> [MappedKey]
directShapeRefs =
  foldMappedShape
    MappedShapeAlgebra
      { onRecord = \_ _ fields -> concatMap (exprRefs . rwfType) fields,
        onEnum = const [],
        onUnion = \_ arms -> concatMap (maybe [] exprRefs . rwaPayload) arms
      }

exprRefs :: ResolvedTypeExpr -> [MappedKey]
exprRefs =
  foldTypeExpr
    TypeExprAlgebra
      { onText = [],
        onInt = [],
        onInteger = [],
        onBool = [],
        onNatural = [],
        onTime = [],
        onJson = [],
        onOptional = id,
        onList = id,
        onMap = id,
        onRef = pure
      }

emitMappedCodecs :: HaskellImportPlan -> Agg -> Text
emitMappedCodecs importPlan a = case aTypeGraph a of
  Nothing -> ""
  Just graph ->
    T.intercalate
      "\n\n"
      [ emitStructuralCodec importPlan (aContext a) graph declaration shape
      | ResolvedStructural declaration shape <- codecMappedDeclarations a
      ]

emitStructuralCodec :: HaskellImportPlan -> Context -> TypeGraph -> StructuralDecl -> ResolvedMappedShape -> Text
emitStructuralCodec importPlan ctx graph declaration shape =
  nl
    [ "encode" <> name <> "Mapped :: " <> consumerType <> " -> Value",
      "encode" <> name <> "Mapped = encode" <> name <> "Shape . bindingToShape " <> binding,
      "",
      "parse" <> name <> "Mapped :: Value -> Parser " <> consumerType,
      "parse" <> name <> "Mapped value = bindingFromShape " <> binding <> " <$> parse" <> name <> "Shape value",
      "",
      "decode" <> name <> "Mapped :: Value -> Either Text " <> consumerType,
      "decode" <> name <> "Mapped = mapLeftText . parseEither parse" <> name <> "Mapped",
      "",
      "encode" <> name <> "Shape :: " <> shapeType <> " -> Value",
      emitShapeEncoder importPlan ctx graph declaration shape,
      "",
      "parse" <> name <> "Shape :: Value -> Parser " <> shapeType,
      emitShapeDecoder importPlan ctx graph declaration shape
    ]
  where
    name = sdName declaration
    consumerType = renderReferenceOrDie importPlan (haskellTypeReference (sdHaskell declaration))
    shapeType = renderReferenceOrDie importPlan (qualifiedTypeReference (structuralShapeModule ctx name) (name <> "Shape"))
    binding = renderReferenceOrDie importPlan (qualifiedValueReference (sdBinding declaration))

emitShapeEncoder :: HaskellImportPlan -> Context -> TypeGraph -> StructuralDecl -> ResolvedMappedShape -> Text
emitShapeEncoder importPlan ctx graph declaration =
  foldMappedShape
    MappedShapeAlgebra
      { onRecord = \_ _ fields ->
          nl $
            ["encode" <> name <> "Shape shape =", "  object"]
              <> objectEntries
                [ tshow (rwfKey field)
                    <> " .= "
                    <> encodeShapeExpr graph (rwfType field) (shapeValue (rwfHaskell field) <> " shape")
                | field <- fields
                ],
        onEnum = \entries ->
          nl $
            ["encode" <> name <> "Shape = \\case"]
              <> ["  " <> shapeConstructor (weCtor entry) <> " -> String " <> tshow (weTag entry) | entry <- entries],
        onUnion = \encoding arms ->
          nl $
            ["encode" <> name <> "Shape = \\case"]
              <> concatMap (unionEncodeArm encoding) arms
      }
  where
    name = sdName declaration
    shapeModuleName = structuralShapeModule ctx name
    shapeConstructor constructor = renderReferenceOrDie importPlan (constructorReference shapeModuleName constructor)
    shapeValue value = renderReferenceOrDie importPlan (HaskellReference shapeModuleName value ValueNamespace RequireQualified)
    unionEncodeArm encoding arm =
      [ "  " <> shapeConstructor (rwaCtor arm) <> payloadPattern <> " ->",
        "    object"
      ]
        <> objectEntries
          ( [tshow (ueTagField encoding) <> " .= (" <> tshow (rwaTag arm) <> " :: Text)"]
              <> [ tshow (ueContentsField encoding) <> " .= " <> encodeShapeExpr graph payload "payload"
                 | payload <- maybeToListText (rwaPayload arm)
                 ]
          )
      where
        payloadPattern = maybe "" (const " payload") (rwaPayload arm)

emitShapeDecoder :: HaskellImportPlan -> Context -> TypeGraph -> StructuralDecl -> ResolvedMappedShape -> Text
emitShapeDecoder importPlan ctx graph declaration =
  foldMappedShape
    MappedShapeAlgebra
      { onRecord = \constructor unknownFields fields ->
          nl $
            [ "parse" <> name <> "Shape = withObject " <> tshow (name <> "Shape") <> " $ \\objectValue -> do"
            ]
              <> rejectLine "  " unknownFields (map rwfKey fields) "objectValue"
              <> [ "  " <> shapeConstructor constructor,
                   "    <$> " <> T.intercalate "\n    <*> " (map (decodeRecordField importPlan ctx graph) fields)
                 ],
        onEnum = \entries ->
          nl $
            [ "parse" <> name <> "Shape = withText " <> tshow (name <> "Shape") <> " $ \\tag -> case tag of"
            ]
              <> ["  " <> tshow (weTag entry) <> " -> pure " <> shapeConstructor (weCtor entry) | entry <- entries]
              <> ["  unknownTag -> " <> renderUnknownFailure (name <> " wire value") "unknownTag" (map weTag entries)],
        onUnion = \encoding arms ->
          nl $
            [ "parse" <> name <> "Shape = withObject " <> tshow (name <> "Shape") <> " $ \\objectValue -> do",
              "  tag <- explicitParseField (withText " <> tshow (name <> " tag") <> " validate" <> name <> "Tag) objectValue " <> tshow (ueTagField encoding),
              "  case tag of"
            ]
              <> concatMap (unionDecodeArm encoding) arms
              <> [ "    _ -> fail \"validated union tag was not handled\"",
                   "",
                   "validate" <> name <> "Tag :: Text -> Parser Text",
                   "validate" <> name <> "Tag tag",
                   "  | tag `elem` " <> renderTextList (map rwaTag arms) <> " = pure tag",
                   "  | otherwise = " <> renderUnknownFailure (name <> " union tag") "tag" (map rwaTag arms)
                 ]
      }
  where
    name = sdName declaration
    shapeModuleName = structuralShapeModule ctx name
    shapeConstructor constructor = renderReferenceOrDie importPlan (constructorReference shapeModuleName constructor)
    rejectLine _ IgnoreUnknown _ _ = []
    rejectLine indent RejectUnknown allowed objectName =
      [indent <> "rejectUnknownFields " <> tshow name <> " " <> renderTextList allowed <> " " <> objectName]
    unionDecodeArm encoding arm =
      ["    " <> tshow (rwaTag arm) <> " -> do"]
        <> rejectLine "      " (ueUnknownFields encoding) allowed "objectValue"
        <> [ case rwaPayload arm of
               Nothing -> "      pure " <> shapeConstructor (rwaCtor arm)
               Just payload ->
                 "      "
                   <> shapeConstructor (rwaCtor arm)
                   <> " <$> explicitParseField ("
                   <> decodeShapeExpr graph payload
                   <> ") objectValue "
                   <> tshow (ueContentsField encoding)
           ]
      where
        allowed = ueTagField encoding : [ueContentsField encoding | rwaPayload arm /= Nothing]

decodeRecordField :: HaskellImportPlan -> Context -> TypeGraph -> ResolvedWireField -> Text
decodeRecordField importPlan ctx graph field = case rwfPresence field of
  PRequired ->
    "explicitParseField (" <> decoder <> ") objectValue " <> key
  POptional ->
    "parseOptionalField ("
      <> missing
      <> ") ("
      <> decoder
      <> ") objectValue "
      <> key
  where
    key = tshow (rwfKey field)
    decoder = decodeShapeExpr graph (rwfType field)
    missing = case rwfOnMissing field of
      Nothing -> "fail " <> tshow ("missing optional field without default: " <> rwfKey field)
      Just onMissing -> "pure " <> renderMissingDefault importPlan ctx graph (rwfType field) onMissing

encodeShapeExpr :: TypeGraph -> ResolvedTypeExpr -> Text -> Text
encodeShapeExpr graph expression =
  renderMappedEncode graph StructuralShapeBoundary (mappedCodecPlanOrDie graph expression)

decodeShapeExpr :: TypeGraph -> ResolvedTypeExpr -> Text
decodeShapeExpr graph expression =
  renderMappedParse graph StructuralShapeBoundary (mappedCodecPlanOrDie graph expression)

mappedCodecPlanOrDie :: TypeGraph -> ResolvedTypeExpr -> MappedCodecPlan
mappedCodecPlanOrDie graph expression =
  either
    (error . ("validated mapped codec plan failed: " <>) . show)
    id
    (planMappedCodec graph expression)

renderMissingDefault :: HaskellImportPlan -> Context -> TypeGraph -> ResolvedTypeExpr -> OnMissing -> Text
renderMissingDefault importPlan ctx graph expression = \case
  OmNull -> "Nothing"
  OmText value -> tshow value
  OmInt value -> T.pack (show value)
  OmBool value -> if value then "True" else "False"
  OmEmptyList -> "[]"
  OmEmptyMap -> "Map.empty"
  OmCtor constructor -> case expression of
    RRef key -> case Map.lookup key (tgDeclarations graph) of
      Just (ResolvedStructural declaration _) -> renderReferenceOrDie importPlan (constructorReference (structuralShapeModule ctx (sdName declaration)) constructor)
      _ -> constructor
    _ -> constructor

objectEntries :: [Text] -> [Text]
objectEntries entries =
  [lead index <> entry | (index, entry) <- zip [(0 :: Int) ..] entries]
    <> ["      ]"]
  where
    lead 0 = "      [ "
    lead _ = "      , "

renderTextList :: [Text] -> Text
renderTextList values = "[" <> T.intercalate ", " (map tshow values) <> "]"

-- | Emit a parser failure that names the rejected runtime value and the full,
-- deterministic wire set accepted at that point.
renderUnknownFailure :: Text -> Text -> [Text] -> Text
renderUnknownFailure label variable expected =
  "fail ("
    <> tshow ("unknown " <> label <> " ")
    <> " <> show "
    <> variable
    <> " <> "
    <> tshow ("; expected one of: " <> expectedText)
    <> ")"
  where
    expectedText = case expected of
      [] -> "<none>"
      values -> T.intercalate ", " values

renderUnknownEventTypeFailure :: Agg -> Text -> Text
renderUnknownEventTypeFailure aggregate variable =
  "fail ("
    <> tshow "unknown event type "
    <> " <> show "
    <> variable
    <> " <> "
    <> tshow "; expected one of: "
    <> " <> renderExpectedEventTypes "
    <> eventTypesName aggregate
    <> ")"

--------------------------------------------------------------------------------
-- Authoritative version-2 expressions and transducer
--------------------------------------------------------------------------------

hasVersion2Ownership :: Agg -> Bool
hasVersion2Ownership = any ((/= LegacyHoleImplementation) . tImplementation) . aTransitions

transitionEntries :: Agg -> [(Int, Transition)]
transitionEntries aggregate =
  [ (layoutDeclarationIndex entry, layoutTransition entry)
  | entry <- transitionLayout (aTransitions aggregate)
  ]

transitionStem :: Int -> Transition -> Text
transitionStem index transition =
  "transition"
    <> tshow' index
    <> pascal (tSource transition)
    <> pascal (tCommand transition)

guardFunctionName :: Int -> Transition -> Text
guardFunctionName index transition = transitionStem index transition <> "Guard"

writeFunctionName :: Int -> Transition -> Name -> Text
writeFunctionName index transition registerName =
  transitionStem index transition <> "Write" <> pascal registerName

holeFunctionName :: Int -> Transition -> Text
holeFunctionName index transition = transitionStem index transition <> "Hole"

holeFoldVersionName :: Int -> Transition -> Text
holeFoldVersionName index transition = holeFunctionName index transition <> "FoldVersion"

outputFunctionName :: Int -> Transition -> Int -> Name -> Text
outputFunctionName transitionIndex transition emitIndex eventName =
  transitionStem transitionIndex transition
    <> "Output"
    <> tshow' emitIndex
    <> pascal eventName

-- | Legacy create-once output-hook names made obsolete by authoritative
-- version-2 @fields(Command)@ generation.  Scaffolding reports these names as
-- safe-to-remove candidates without parsing or modifying consumer Haskell.
obsoleteGeneratedOutputHooks :: Spec -> [(Name, Text)]
obsoleteGeneratedOutputHooks spec =
  [ ( aggName aggregate,
      outputFunctionName transitionIndex transition emitIndex eventName
    )
  | aggregate <- [value | NAggregate value <- specNodes spec],
    entry <- transitionLayout (aggTransitions aggregate),
    let transitionIndex = layoutDeclarationIndex entry
        transition = layoutTransition entry,
    (emitIndex, eventName) <- zip [1 ..] (tEmits transition),
    Right GeneratedCommandIdentity {} <- [eventOutputMapping spec aggregate transition emitIndex eventName]
  ]

commandForTransition :: Agg -> Transition -> ResolvedCtor
commandForTransition aggregate transition =
  fromMaybe
    (error ("validated aggregate command disappeared: " <> T.unpack (tCommand transition)))
    (find ((== tCommand transition) . rcName) (aCommands aggregate))

eventForName :: Agg -> Name -> ResolvedCtor
eventForName aggregate eventName =
  fromMaybe
    (error ("validated aggregate event disappeared: " <> T.unpack eventName))
    (find ((== eventName) . rcName) (aEvents aggregate))

commandFieldsType :: Transition -> Text
commandFieldsType transition = "RegFieldsOf " <> tCommand transition <> "Data"

payloadProjectionType :: Agg -> Transition -> Text
payloadProjectionType aggregate transition =
  "B.PayloadProj "
    <> aName aggregate
    <> "Regs "
    <> aName aggregate
    <> "Command ("
    <> commandFieldsType transition
    <> ")"

data ResolvedGeneratedTransition = ResolvedGeneratedTransition
  { resolvedTransitionIndex :: !Int,
    resolvedTransitionSource :: !Transition,
    resolvedTransitionGuard :: !(Maybe TypedScalarExpr),
    resolvedTransitionWrites :: ![(Name, TypedScalarExpr)]
  }
  deriving stock (Eq, Show)

data SilentOutcomeKind = RejectedOutcome | NoOpOutcome
  deriving stock (Eq, Show)

data ResolvedSilentOutcome = ResolvedSilentOutcome
  { resolvedSilentLayout :: !TransitionLayoutEntry,
    resolvedSilentKind :: !SilentOutcomeKind,
    resolvedSilentReason :: !TypedScalarExpr
  }
  deriving stock (Eq, Show)

-- Resolve each generated-owned transition exactly once. Import analysis,
-- projection planning, and Haskell emission all consume this inventory.
resolvedGeneratedTransitions :: Agg -> [ResolvedGeneratedTransition]
resolvedGeneratedTransitions aggregate =
  [ ResolvedGeneratedTransition
      { resolvedTransitionIndex = index,
        resolvedTransitionSource = transition,
        resolvedTransitionGuard = resolvedGuard index transition <$> tGuard transition,
        resolvedTransitionWrites =
          [ (registerName, resolvedWrite index transition registerName expression)
          | (registerName, expression) <- tWrites transition
          ]
      }
  | (index, transition) <- transitionEntries aggregate,
    tImplementation transition == GeneratedImplementation
  ]
  where
    environment transition = expressionEnvironment (aSpec aggregate) (aAggregate aggregate) transition
    resolvedGuard index transition expression =
      expressionOrDie (guardFunctionName index transition) (resolveGuardExpr (environment transition) expression)
    resolvedWrite index transition registerName expression =
      expressionOrDie (writeFunctionName index transition registerName) (resolveWriteExpr (environment transition) registerName expression)

resolvedGeneratedExpressions :: Agg -> [TypedScalarExpr]
resolvedGeneratedExpressions = generatedTransitionExpressions . resolvedGeneratedTransitions

generatedTransitionExpressions :: [ResolvedGeneratedTransition] -> [TypedScalarExpr]
generatedTransitionExpressions = concatMap transitionExpressions
  where
    transitionExpressions resolved =
      maybe [] pure (resolvedTransitionGuard resolved)
        <> map snd (resolvedTransitionWrites resolved)

resolvedSilentOutcomes :: Agg -> [ResolvedSilentOutcome]
resolvedSilentOutcomes aggregate =
  [ ResolvedSilentOutcome
      { resolvedSilentLayout = entry,
        resolvedSilentKind = kind,
        resolvedSilentReason = resolveReason entry expected expression
      }
  | entry <- transitionLayout (aTransitions aggregate),
    let transition = layoutTransition entry,
    tMode transition == TmLive,
    (kind, expected, expression) <- outcomeReason transition
  ]
  where
    outcomeReason transition = case (aDomainOutcomeTypes aggregate, tOutcome transition) of
      (Just outcomeTypes, Just (OutcomeRejected expression _)) ->
        [(RejectedOutcome, resolvedRejectionType outcomeTypes, expression)]
      (Just outcomeTypes, Just (OutcomeNoOp expression _)) ->
        [(NoOpOutcome, resolvedNoOpType outcomeTypes, expression)]
      _ -> []
    resolveReason entry expected expression =
      let transition = layoutTransition entry
          owner = transitionStem (layoutDeclarationIndex entry) transition <> "OutcomeReason"
          environment = expressionEnvironment (aSpec aggregate) (aAggregate aggregate) transition
       in expressionOrDie owner (resolveScalarExpr environment (ExpectScalarType expected) expression)

resolvedOutcomeExpressions :: Agg -> [TypedScalarExpr]
resolvedOutcomeExpressions = map resolvedSilentReason . resolvedSilentOutcomes

-- | Guard expressions only.
--
-- A guard renders its operands as @K.Index … SomeType@ annotations and so needs
-- each operand type in scope. A write renders @B.slot \@"x" =: d.x@, whose type
-- is inferred — importing its source type adds an unused import, which is an
-- error under the generated-output @-Werror@. Literals name their type in either
-- position and are collected separately.
generatedTransitionGuards :: [ResolvedGeneratedTransition] -> [TypedScalarExpr]
generatedTransitionGuards = concatMap (maybe [] pure . resolvedTransitionGuard)

-- | Every literal node in an expression tree.
typedExpressionLiterals :: TypedScalarExpr -> [TypedScalarExpr]
typedExpressionLiterals expression = own <> concatMap typedExpressionLiterals (typedExpressionChildren expression)
  where
    own = case typedScalarNode expression of
      TypedLiteral {} -> [expression]
      _ -> []

-- | Types named by literal construction anywhere in an expression.
typedExpressionLiteralTypes :: TypedScalarExpr -> [ResolvedAggregateType]
typedExpressionLiteralTypes expression = own <> concatMap typedExpressionLiteralTypes (typedExpressionChildren expression)
  where
    own = case typedScalarNode expression of
      TypedLiteral {} -> [typedScalarType expression]
      _ -> []

anyTypedExpression :: (TypedScalarExpr -> Bool) -> TypedScalarExpr -> Bool
anyTypedExpression predicate expression =
  predicate expression || any (anyTypedExpression predicate) (typedExpressionChildren expression)

typedExpressionChildren :: TypedScalarExpr -> [TypedScalarExpr]
typedExpressionChildren expression = case typedScalarNode expression of
  TypedLiteral {} -> []
  TypedRoot {} -> []
  TypedProject {} -> []
  TypedAdd _ left right -> [left, right]
  TypedSubtract _ left right -> [left, right]
  TypedMultiply _ left right -> [left, right]
  TypedEqual left right -> [left, right]
  TypedNotEqual left right -> [left, right]
  TypedCompare _ left right -> [left, right]
  TypedAnd left right -> [left, right]
  TypedOr left right -> [left, right]

typedConsumerLiteralNominals :: TypedScalarExpr -> [ResolvedNominalType]
typedConsumerLiteralNominals expression = own <> concatMap typedConsumerLiteralNominals (typedExpressionChildren expression)
  where
    own = case (typedScalarType expression, typedScalarNode expression) of
      (AggregateNominal nominal, TypedLiteral ScalarEnumValue {})
        | ConsumerNominal {} <- resolvedNominalOwnership nominal -> [nominal]
      (AggregateNominal nominal, TypedLiteral ScalarIdValue {})
        | ConsumerNominal {} <- resolvedNominalOwnership nominal -> [nominal]
      _ -> []

typedGeneratedNominals :: TypedScalarExpr -> [ResolvedNominalType]
typedGeneratedNominals expression = own <> concatMap typedGeneratedNominals (typedExpressionChildren expression)
  where
    own = case typedScalarType expression of
      AggregateNominal nominal
        | GeneratedNominal <- resolvedNominalOwnership nominal -> [nominal]
      _ -> []

expressionOrDie :: Text -> Either (NonEmpty ExpressionDiagnostic) TypedScalarExpr -> TypedScalarExpr
expressionOrDie owner = either (error . (("validated expression disappeared for " <> T.unpack owner <> ": ") <>) . show) id

data ProjectionAliasTarget
  = StructuralProjectionAlias !ScalarRootProvenance !ResolvedScalarProjection
  | NominalProjectionAlias !ResolvedNominalType !ScalarRootProvenance
  deriving stock (Eq, Show)

data ProjectionAlias = ProjectionAlias
  { projectionAliasTarget :: !ProjectionAliasTarget,
    projectionAliasName :: !Text
  }
  deriving stock (Eq, Show)

projectionAliasesForTransition :: ResolvedGeneratedTransition -> [ProjectionAlias]
projectionAliasesForTransition resolved = allocateAliases targets
  where
    expressions =
      maybe [] pure (resolvedTransitionGuard resolved)
        <> map snd (resolvedTransitionWrites resolved)
    targets = nub (concatMap projectionAliasTargets expressions)

projectionAliasTargets :: TypedScalarExpr -> [ProjectionAliasTarget]
projectionAliasTargets expression = own <> comparisonTargets <> concatMap projectionAliasTargets children
  where
    children = typedExpressionChildren expression
    own = case typedScalarNode expression of
      TypedProject provenance projection -> [StructuralProjectionAlias provenance projection]
      _ -> []
    comparisonTargets = case typedScalarNode expression of
      TypedEqual left right -> mapMaybe nominalTarget [left, right]
      TypedNotEqual left right -> mapMaybe nominalTarget [left, right]
      _ -> []
    nominalTarget operand = case (typedScalarType operand, typedScalarNode operand) of
      (AggregateNominal nominal, TypedRoot provenance)
        | nominalComparisonProjection nominal -> Just (NominalProjectionAlias nominal provenance)
      _ -> Nothing

allocateAliases :: [ProjectionAliasTarget] -> [ProjectionAlias]
allocateAliases = snd . foldl allocate (Map.empty, [])
  where
    allocate (counts, aliases) target =
      let base = projectionAliasBase target
          occurrence = Map.findWithDefault 0 base counts + 1
          alias = if occurrence == 1 then base else base <> tshow' occurrence
       in (Map.insert base occurrence counts, aliases <> [ProjectionAlias target alias])

projectionAliasBase :: ProjectionAliasTarget -> Text
projectionAliasBase target = prefix <> pascal rootName <> pathSuffix
  where
    provenance = case target of
      StructuralProjectionAlias value _ -> value
      NominalProjectionAlias _ value -> value
    (prefix, rootName) = case provenance of
      ScalarRegisterRoot name _ -> ("register", name)
      ScalarCommandRoot name _ -> ("command", name)
    pathSuffix = case target of
      NominalProjectionAlias {} -> ""
      StructuralProjectionAlias _ projection ->
        T.concat
          [ normaliseAliasPart (unescapePointer segment)
          | segment <- filter (not . T.null) (T.splitOn "/" (scalarProjectionPointer projection))
          ]

normaliseAliasPart :: Text -> Text
normaliseAliasPart value = case filter (not . T.null) (T.split (not . isAlphaNum) value) of
  [] -> "Field"
  pieces -> T.concat (map pascal pieces)

unescapePointer :: Text -> Text
unescapePointer = T.replace "~0" "~" . T.replace "~1" "/"

projectionAliasFor :: [ProjectionAlias] -> ProjectionAliasTarget -> Text
projectionAliasFor aliases target =
  maybe
    (error ("resolved projection alias disappeared: " <> show target))
    projectionAliasName
    (find ((== target) . projectionAliasTarget) aliases)

data RenderAssociativity = RenderLeft | RenderRight | RenderNonAssociative
  deriving stock (Eq, Show)

data RenderOperandSide = RenderLeftOperand | RenderRightOperand
  deriving stock (Eq, Show)

data RenderedKeikiExpr = RenderedKeikiExpr
  { renderedKeikiText :: !Text,
    renderedKeikiPrecedence :: !Int
  }
  deriving stock (Eq, Show)

renderedAtom :: Text -> RenderedKeikiExpr
renderedAtom value = RenderedKeikiExpr value 10

renderedInfix :: Int -> RenderAssociativity -> Text -> RenderedKeikiExpr -> RenderedKeikiExpr -> RenderedKeikiExpr
renderedInfix precedence associativity operator left right =
  RenderedKeikiExpr
    ( renderInfixChild precedence associativity RenderLeftOperand left
        <> " "
        <> operator
        <> " "
        <> renderInfixChild precedence associativity RenderRightOperand right
    )
    precedence

renderInfixChild :: Int -> RenderAssociativity -> RenderOperandSide -> RenderedKeikiExpr -> Text
renderInfixChild parentPrecedence associativity side child
  | renderedKeikiPrecedence child > parentPrecedence = renderedKeikiText child
  | renderedKeikiPrecedence child < parentPrecedence = parenthesized
  | otherwise = case associativity of
      RenderLeft
        | side == RenderLeftOperand -> renderedKeikiText child
      RenderRight
        | side == RenderRightOperand -> renderedKeikiText child
      _ -> parenthesized
  where
    parenthesized = "(" <> renderedKeikiText child <> ")"

renderKeikiPredicate :: HaskellImportPlan -> [ProjectionAlias] -> Agg -> Transition -> TypedScalarExpr -> Text
renderKeikiPredicate importPlan aliases aggregate transition =
  renderedKeikiText . renderPredicate
  where
    renderPredicate expression = case typedScalarNode expression of
      TypedEqual left right -> comparison ".==" left right
      TypedNotEqual left right -> comparison "./=" left right
      TypedCompare operator left right -> comparison (renderComparisonOperator operator) left right
      TypedAnd left right -> boolean 3 RenderRight ".&&" left right
      TypedOr left right -> boolean 2 RenderRight ".||" left right
      _ ->
        renderedInfix
          4
          RenderNonAssociative
          ".=="
          (renderKeikiTerm importPlan aliases aggregate transition expression)
          (renderedAtom "K.lit True")
    comparison operator left right =
      renderedInfix
        4
        RenderNonAssociative
        operator
        (renderComparisonTerm importPlan aliases aggregate transition left)
        (renderComparisonTerm importPlan aliases aggregate transition right)
    boolean precedence associativity operator left right =
      renderedInfix precedence associativity operator (renderPredicate left) (renderPredicate right)

renderComparisonOperator :: CmpOp -> Text
renderComparisonOperator = \case
  OpEq -> ".=="
  OpNeq -> "./="
  OpLt -> ".<"
  OpLe -> ".<="
  OpGt -> ".>"
  OpGe -> ".>="

renderComparisonTerm :: HaskellImportPlan -> [ProjectionAlias] -> Agg -> Transition -> TypedScalarExpr -> RenderedKeikiExpr
renderComparisonTerm importPlan aliases aggregate transition expression = case (typedScalarType expression, typedScalarNode expression) of
  (AggregateNominal nominal, TypedRoot provenance)
    | nominalComparisonProjection nominal ->
        renderedAtom (projectionAliasFor aliases (NominalProjectionAlias nominal provenance))
  (AggregateNominal nominal, TypedLiteral (ScalarEnumValue _ constructor)) ->
    renderedAtom ("K.lit (" <> tshow (enumWireFor nominal constructor) <> " :: Text)")
  (AggregateNominal _, TypedLiteral (ScalarIdValue _ value)) ->
    renderedAtom ("K.lit (" <> tshow value <> " :: Text)")
  _ -> renderKeikiTerm importPlan aliases aggregate transition expression

nominalComparisonProjection :: ResolvedNominalType -> Bool
nominalComparisonProjection nominal = case resolvedNominalRepresentation nominal of
  IdRepresentation {} -> True
  EnumRepresentation {} -> True
  ScalarRepresentation {} -> case resolvedNominalOwnership nominal of
    ConsumerNominal {} -> True
    GeneratedNominal -> False

enumWireFor :: ResolvedNominalType -> Name -> Text
enumWireFor nominal constructor = case resolvedNominalRepresentation nominal of
  EnumRepresentation constructors -> fromMaybe (error "validated enum literal lost its wire spelling") (lookup constructor (NE.toList constructors))
  _ -> error "validated enum literal lost its enum representation"

renderNominalProjectionTerm :: HaskellImportPlan -> Agg -> Transition -> ResolvedNominalType -> ScalarRootProvenance -> Text
renderNominalProjectionTerm importPlan aggregate transition nominal provenance = case provenance of
  ScalarRegisterRoot registerName ownerType ->
    "K.regProj "
      <> projectionQualifier
      <> "."
      <> witness
      <> " (#"
      <> registerName
      <> " :: K.Index "
      <> aName aggregate
      <> "Regs "
      <> renderDomainType importPlan aggregate ownerType
      <> ")"
  ScalarCommandRoot fieldName ownerType ->
    "K.inpProj "
      <> projectionQualifier
      <> "."
      <> witness
      <> " inCtor"
      <> tCommand transition
      <> " (#"
      <> commandFieldSelector aggregate (tCommand transition) fieldName
      <> " :: K.Index ("
      <> commandFieldsType transition
      <> ") "
      <> renderDomainType importPlan aggregate ownerType
      <> ")"
  where
    projectionQualifier = case resolvedNominalOwnership nominal of
      GeneratedNominal -> "GeneratedNominals"
      ConsumerNominal {} -> "NominalProjections"
    witness = case resolvedNominalRepresentation nominal of
      ScalarRepresentation {} -> lowerFirst (resolvedNominalName nominal) <> "Witness"
      IdRepresentation {} -> nominalEqualityWitnessName nominal
      EnumRepresentation {} -> nominalEqualityWitnessName nominal

renderKeikiTerm :: HaskellImportPlan -> [ProjectionAlias] -> Agg -> Transition -> TypedScalarExpr -> RenderedKeikiExpr
renderKeikiTerm importPlan aliases aggregate transition expression = case typedScalarNode expression of
  TypedLiteral value -> renderedAtom (renderKeikiLiteral importPlan aggregate (typedScalarType expression) value)
  TypedRoot (ScalarRegisterRoot registerName _) -> renderedAtom ("B.reg @" <> tshow registerName)
  TypedRoot (ScalarCommandRoot fieldName _) ->
    renderedAtom ("d." <> commandFieldSelector aggregate (tCommand transition) fieldName)
  TypedProject provenance projection ->
    renderedAtom (projectionAliasFor aliases (StructuralProjectionAlias provenance projection))
  TypedAdd _ left right -> arithmetic 6 ".+" left right
  TypedSubtract _ left right -> arithmetic 6 ".-" left right
  TypedMultiply _ left right -> arithmetic 7 ".*" left right
  TypedEqual {} -> impossiblePredicate
  TypedNotEqual {} -> impossiblePredicate
  TypedCompare {} -> impossiblePredicate
  TypedAnd {} -> impossiblePredicate
  TypedOr {} -> impossiblePredicate
  where
    arithmetic precedence operator left right =
      renderedInfix
        precedence
        RenderLeft
        operator
        (renderKeikiTerm importPlan aliases aggregate transition left)
        (renderKeikiTerm importPlan aliases aggregate transition right)
    impossiblePredicate = error "predicate-valued Boolean expressions cannot be lowered as register terms"

renderOutcomeReasonEvaluation :: HaskellImportPlan -> Agg -> Transition -> TypedScalarExpr -> Text
renderOutcomeReasonEvaluation importPlan aggregate transition expression =
  evaluator
    <> " ("
    <> renderedKeikiText rendered
    <> ") registers command"
  where
    (evaluator, rendered) = case typedScalarNode expression of
      TypedEqual {} -> ("K.evalPred", renderOutcomePredicate importPlan aggregate transition expression)
      TypedNotEqual {} -> ("K.evalPred", renderOutcomePredicate importPlan aggregate transition expression)
      TypedCompare {} -> ("K.evalPred", renderOutcomePredicate importPlan aggregate transition expression)
      TypedAnd {} -> ("K.evalPred", renderOutcomePredicate importPlan aggregate transition expression)
      TypedOr {} -> ("K.evalPred", renderOutcomePredicate importPlan aggregate transition expression)
      _ -> ("K.evalTerm", renderOutcomeKeikiTerm importPlan aggregate transition expression)

renderOutcomePredicate :: HaskellImportPlan -> Agg -> Transition -> TypedScalarExpr -> RenderedKeikiExpr
renderOutcomePredicate importPlan aggregate transition = renderPredicate
  where
    renderPredicate expression = case typedScalarNode expression of
      TypedEqual left right -> comparison ".==" left right
      TypedNotEqual left right -> comparison "./=" left right
      TypedCompare operator left right -> comparison (renderComparisonOperator operator) left right
      TypedAnd left right -> boolean 3 RenderRight ".&&" left right
      TypedOr left right -> boolean 2 RenderRight ".||" left right
      _ ->
        renderedInfix
          4
          RenderNonAssociative
          ".=="
          (renderOutcomeKeikiTerm importPlan aggregate transition expression)
          (renderedAtom "K.lit True")
    comparison operator left right =
      renderedInfix
        4
        RenderNonAssociative
        operator
        (renderOutcomeComparisonTerm importPlan aggregate transition left)
        (renderOutcomeComparisonTerm importPlan aggregate transition right)
    boolean precedence associativity operator left right =
      renderedInfix precedence associativity operator (renderPredicate left) (renderPredicate right)

renderOutcomeComparisonTerm :: HaskellImportPlan -> Agg -> Transition -> TypedScalarExpr -> RenderedKeikiExpr
renderOutcomeComparisonTerm importPlan aggregate transition expression = case (typedScalarType expression, typedScalarNode expression) of
  (AggregateNominal nominal, TypedRoot provenance)
    | nominalComparisonProjection nominal ->
        renderedAtom (renderNominalProjectionTerm importPlan aggregate transition nominal provenance)
  (AggregateNominal nominal, TypedLiteral (ScalarEnumValue _ constructor)) ->
    renderedAtom ("K.lit (" <> tshow (enumWireFor nominal constructor) <> " :: Text)")
  (AggregateNominal _, TypedLiteral (ScalarIdValue _ value)) ->
    renderedAtom ("K.lit (" <> tshow value <> " :: Text)")
  _ -> renderOutcomeKeikiTerm importPlan aggregate transition expression

renderOutcomeKeikiTerm :: HaskellImportPlan -> Agg -> Transition -> TypedScalarExpr -> RenderedKeikiExpr
renderOutcomeKeikiTerm importPlan aggregate transition expression = case typedScalarNode expression of
  TypedLiteral value -> renderedAtom (renderKeikiLiteral importPlan aggregate (typedScalarType expression) value)
  TypedRoot (ScalarRegisterRoot registerName _) -> renderedAtom ("B.reg @" <> tshow registerName)
  TypedRoot (ScalarCommandRoot fieldName ownerType) ->
    renderedAtom
      ( "K.inpCtor inCtor"
          <> tCommand transition
          <> " (#"
          <> commandFieldSelector aggregate (tCommand transition) fieldName
          <> " :: K.Index ("
          <> commandFieldsType transition
          <> ") "
          <> renderDomainType importPlan aggregate ownerType
          <> ")"
      )
  TypedProject provenance projection ->
    renderedAtom (renderStructuralProjectionTerm importPlan aggregate transition provenance projection)
  TypedAdd _ left right -> arithmetic 6 ".+" left right
  TypedSubtract _ left right -> arithmetic 6 ".-" left right
  TypedMultiply _ left right -> arithmetic 7 ".*" left right
  TypedEqual {} -> impossiblePredicate
  TypedNotEqual {} -> impossiblePredicate
  TypedCompare {} -> impossiblePredicate
  TypedAnd {} -> impossiblePredicate
  TypedOr {} -> impossiblePredicate
  where
    arithmetic precedence operator left right =
      renderedInfix
        precedence
        RenderLeft
        operator
        (renderOutcomeKeikiTerm importPlan aggregate transition left)
        (renderOutcomeKeikiTerm importPlan aggregate transition right)
    impossiblePredicate = error "predicate-valued Boolean outcome cannot be lowered as a Keiki term"

renderStructuralProjectionTerm :: HaskellImportPlan -> Agg -> Transition -> ScalarRootProvenance -> ResolvedScalarProjection -> Text
renderStructuralProjectionTerm importPlan aggregate transition provenance projection = case provenance of
  ScalarRegisterRoot registerName ownerType ->
    "K.regProj StructuralProjections."
      <> witness
      <> " (#"
      <> registerName
      <> " :: K.Index "
      <> aName aggregate
      <> "Regs "
      <> renderDomainType importPlan aggregate ownerType
      <> ")"
  ScalarCommandRoot fieldName ownerType ->
    "K.inpProj StructuralProjections."
      <> witness
      <> " inCtor"
      <> tCommand transition
      <> " (#"
      <> commandFieldSelector aggregate (tCommand transition) fieldName
      <> " :: K.Index ("
      <> commandFieldsType transition
      <> ") "
      <> renderDomainType importPlan aggregate ownerType
      <> ")"
  where
    witness =
      fromMaybe
        (error ("resolved structural projection witness disappeared: " <> show projection))
        (aTypeGraph aggregate >>= \graph -> projectionWitnessName graph (scalarProjectionOwner projection) (scalarProjectionPointer projection))

renderKeikiLiteral :: HaskellImportPlan -> Agg -> ResolvedAggregateType -> ScalarValue -> Text
renderKeikiLiteral importPlan aggregate scalarType = \case
  ScalarTextValue value -> "K.lit (" <> tshow value <> " :: Text)"
  ScalarIntValue value -> "K.lit (" <> tshow' value <> " :: Int)"
  ScalarIntegerValue value -> "K.lit (" <> T.pack (show value) <> " :: Integer)"
  ScalarNaturalValue value -> "K.lit (" <> T.pack (show value) <> " :: Natural)"
  ScalarBoolValue value -> "K.lit " <> if value then "True" else "False"
  ScalarTimeValue value -> "K.lit " <> renderRegisterInitial (InitialTime value)
  ScalarEnumValue _typeName constructor -> case scalarType of
    AggregateNominal nominal -> case resolvedNominalOwnership nominal of
      GeneratedNominal -> "K.lit " <> constructor
      ConsumerNominal binding ->
        "K.lit (nominalFromRepresentation "
          <> renderReferenceOrDie importPlan (qualifiedValueReference (consumerNominalBinding binding))
          <> " "
          <> renderReferenceOrDie importPlan (nominalRepresentationConstructorReference (aContext aggregate) nominal constructor)
          <> ")"
    _ -> error "validated enum literal lost its nominal type"
  ScalarIdValue typeName value -> case scalarType of
    AggregateNominal nominal -> case resolvedNominalOwnership nominal of
      GeneratedNominal -> case idDomainContractFor (aLanguageContract aggregate) =<< idPrefixOf nominal of
        Nothing -> "K.lit (" <> typeName <> " " <> tshow value <> ")"
        Just _ ->
          "K.lit (case parse"
            <> typeName
            <> " "
            <> tshow value
            <> " of Right parsed -> parsed; Left _ -> error \"validated ID literal failed to parse\")"
      ConsumerNominal binding -> case resolvedNominalRepresentation nominal of
        IdRepresentation prefix ->
          "K.lit (nominalFromRepresentation "
            <> renderReferenceOrDie importPlan (qualifiedValueReference (consumerNominalBinding binding))
            <> " (case KindID.parseText @"
            <> tshow prefix
            <> " "
            <> tshow value
            <> " of Right parsed -> parsed; Left _ -> error \"validated ID literal failed to parse\"))"
        _ -> error "validated ID literal lost its ID representation"
    _ -> error "validated ID literal lost its nominal type"
  where
    idPrefixOf nominal = case resolvedNominalRepresentation nominal of
      IdRepresentation prefix -> Just prefix
      _ -> Nothing

generatedIdSampleHaskell :: Agg -> ResolvedNominalType -> Maybe Text
generatedIdSampleHaskell aggregate nominal = do
  prefix <- case resolvedNominalRepresentation nominal of
    IdRepresentation value -> Just value
    _ -> Nothing
  contract <- idDomainContractFor (aLanguageContract aggregate) prefix
  let name = resolvedNominalName nominal
      sample = idDomainSampleText contract
  pure
    ( "(case parse"
        <> name
        <> " "
        <> tshow sample
        <> " of Right parsed -> parsed; Left _ -> error \"generated valid ID sample failed to parse\")"
    )

emitGeneratedTransducer :: Agg -> Text
emitGeneratedTransducer aggregate =
  nl $
    renderGeneratedLanguagePragmas
      ( [ExtBlockArguments, ExtQualifiedDo]
          <> [ExtOverloadedLabels | not (null projectionAliases)]
          <> [ExtOverloadedRecordDot | transducerUsesRecordDot aggregate]
      )
      ++ [ generatedBanner,
           "module " <> aGenPrefix aggregate <> ".Transducer",
           "  ( " <> lowerFirst (aName aggregate) <> "Transducer",
           "  , " <> lowerFirst (aName aggregate) <> "FoldFingerprint",
           "  , BehaviorOwnership (..)",
           "  , " <> lowerFirst (aName aggregate) <> "PredicateVerifications",
           "  ) where",
           "",
           "import " <> aGenPrefix aggregate <> ".Domain",
           "import Data.Text (Text)"
         ]
      ++ ["import Data.Time.Calendar (fromGregorian)" | expressionUsesTimeLiteral]
      ++ ["import Data.Time.Clock (UTCTime (..), picosecondsToDiffTime)" | expressionUsesTimeLiteral]
      ++ ["import Numeric.Natural (Natural)" | expressionUsesNaturalLiteral]
      ++ generatedNominalTypeImportsWithParsers
        (aggregateCheckedService aggregate)
        (aContext aggregate)
        generatedExpressionNominals
        generatedLiteralNominals
      ++ structuralProjectionImport
      ++ generatedNominalProjectionImport
      ++ consumerNominalProjectionImport
      ++ consumerImports
      ++ ["import Data.KindID qualified as KindID" | expressionUsesConsumerIdLiteral]
      ++ ["import Keiro.Codec.Nominal (nominalFromRepresentation)" | expressionUsesConsumerNominalLiteral]
      ++ [ "import Keiki.Builder qualified as B",
           "import Keiki.Core (" <> T.intercalate ", " keikiCoreImports <> ")",
           "import Keiki.Core qualified as K",
           "import Keiki.Symbolic qualified as S"
         ]
      ++ ["import " <> aHolePrefix aggregate <> ".Holes qualified as Holes" | transducerUsesHoles aggregate]
      ++ ["import Data.Text qualified as T" | anyHoleOwned aggregate]
      ++ ["import Keiki.Builder ((=:))" | any (not . null . tWrites . snd) (transitionEntries aggregate)]
      ++ ["import Keiki.Generics (RegFieldsOf)" | not (null projectionAliases)]
      ++ ["import Keiro.Snapshot.Codec (FoldVersion (..))" | anyHoleOwned aggregate]
      ++ [ "",
           lowerFirst (aName aggregate) <> "Transducer",
           "  :: SymTransducer",
           "       (HsPred " <> aName aggregate <> "Regs " <> aName aggregate <> "Command)",
           "       " <> aName aggregate <> "Regs",
           "       " <> aVertexType aggregate,
           "       " <> aName aggregate <> "Command",
           "       " <> aName aggregate <> "Event",
           lowerFirst (aName aggregate) <> "Transducer =",
           "  B.buildTransducer " <> initialVertex aggregate <> " initial" <> aName aggregate <> "Regs isTerminal do",
           nl (concatMap (generatedFromBlock importPlan aggregate resolvedTransitions) (groupTransitionEntriesBySource aggregate)),
           " where",
           "  isTerminal = \\case",
           nl ["    " <> vertexCtor aggregate (stName state) <> " -> True" | state <- aStates aggregate, stTerminal state],
           "    _ -> False",
           "",
           lowerFirst (aName aggregate) <> "FoldFingerprint :: Text",
           lowerFirst (aName aggregate) <> "FoldFingerprint = " <> foldFingerprintExpression aggregate,
           "",
           "data BehaviorOwnership = GeneratedOwned | HoleOwned",
           "  deriving stock (Eq, Show)",
           "",
           "-- Every checked transition predicate is audited through Keiki's conservative",
           "-- symbolic verifier. Opaque Hole terms remain explicitly unverified.",
           lowerFirst (aName aggregate) <> "PredicateVerifications :: IO [(Text, BehaviorOwnership, S.PredicateVerification)]",
           lowerFirst (aName aggregate) <> "PredicateVerifications = sequence",
           nl (renderVerificationList aggregate),
           " where",
           "  verifyTransition label owner source edgeIndex =",
           "    case drop edgeIndex (K.edgesOut " <> lowerFirst (aName aggregate) <> "Transducer source) of",
           "      K.Edge predicate _ _ _ _ : _ -> (\\result -> (label, owner, result)) <$> S.verifyPredicate predicate",
           "      [] -> pure (label, owner, S.UnverifiedSolverFailure \"generated transition edge missing\")"
         ]
  where
    resolvedTransitions = resolvedGeneratedTransitions aggregate
    resolvedExpressions = generatedTransitionExpressions resolvedTransitions
    projectionAliases = concatMap projectionAliasesForTransition resolvedTransitions
    projectionTargets = map projectionAliasTarget projectionAliases
    structuralProjectionImport =
      [ "import " <> structuralProjectionModule (aContext aggregate) <> " qualified as StructuralProjections"
      | any isStructuralProjection projectionTargets
      ]
    generatedNominalProjectionImport =
      [ "import " <> generatedNominalModule (aContext aggregate) <> " qualified as GeneratedNominals"
      | any isGeneratedNominalProjection projectionTargets
      ]
    consumerNominalProjectionImport =
      [ "import " <> nominalProjectionModule (aContext aggregate) <> " qualified as NominalProjections"
      | any isConsumerNominalProjection projectionTargets
      ]
    consumerImports =
      T.lines (renderPlannedImports importPlan)
    expressionImportTypes =
      nub
        ( concatMap typedExpressionImportTypes (generatedTransitionGuards resolvedTransitions)
            <> concatMap typedExpressionLiteralTypes resolvedExpressions
        )
    consumerLiteralNominals = nub [nominal | expression <- resolvedExpressions, nominal <- typedConsumerLiteralNominals expression]
    importPlan = transducerImportPlan aggregate expressionImportTypes consumerLiteralNominals
    generatedExpressionNominals =
      stableNominals
        [ nominal
        | expression <- resolvedExpressions,
          nominal <- typedGeneratedNominals expression
        ]
    -- Only a literal names `parse<Id>`; see 'generatedNominalTypeImportsWithParsers'.
    generatedLiteralNominals =
      stableNominals
        [ nominal
        | expression <- resolvedExpressions,
          literal <- typedExpressionLiterals expression,
          nominal <- typedGeneratedNominals literal
        ]
    expressionUsesTimeLiteral = any (anyTypedExpression isTimeLiteral) resolvedExpressions
    expressionUsesNaturalLiteral = any (anyTypedExpression isNaturalLiteral) resolvedExpressions
    expressionUsesConsumerNominalLiteral = not (null consumerLiteralNominals)
    expressionUsesConsumerIdLiteral = any (isIdRepresentation . resolvedNominalRepresentation) consumerLiteralNominals
    usedOperators = nub (concatMap generatedTransitionOperators resolvedTransitions)
    keikiCoreImports = ["HsPred", "SymTransducer"] <> ["(" <> operator <> ")" | operator <- expressionOperatorOrder, operator `elem` usedOperators]
    isTimeLiteral expression = case typedScalarNode expression of
      TypedLiteral ScalarTimeValue {} -> True
      _ -> False
    isNaturalLiteral expression = case typedScalarNode expression of
      TypedLiteral ScalarNaturalValue {} -> True
      _ -> False
    isIdRepresentation IdRepresentation {} = True
    isIdRepresentation _ = False

transducerUsesRecordDot :: Agg -> Bool
transducerUsesRecordDot aggregate =
  any expressionUsesCommandRoot (resolvedGeneratedExpressions aggregate)
    || any generatedOutputUsesCommandField generatedOutputs
  where
    generatedOutputs =
      [ outputMappingFor aggregate transitionIndex emitIndex
      | (transitionIndex, transition) <- transitionEntries aggregate,
        tImplementation transition == GeneratedImplementation,
        emitIndex <- [1 .. length (tEmits transition)]
      ]
    generatedOutputUsesCommandField (GeneratedCommandIdentity _ fields) = not (null fields)
    generatedOutputUsesCommandField HandOwnedEventOutput {} = False
    expressionUsesCommandRoot = anyTypedExpression isCommandRoot
    isCommandRoot expression = case typedScalarNode expression of
      TypedRoot ScalarCommandRoot {} -> True
      _ -> False

transducerImportPlan :: Agg -> [ResolvedAggregateType] -> [ResolvedNominalType] -> HaskellImportPlan
transducerImportPlan aggregate importedTypes literalNominals =
  planImportsOrDie
    (aGenPrefix aggregate <> ".Transducer")
    (Set.fromList [aName aggregate <> "Regs", aName aggregate <> "Command", aName aggregate <> "Event"])
    ( Set.unions
        [ aggregateSourceReferences (aggregateConsumerHaskellSource (aSymbols aggregate) resolvedType)
        | resolvedType <- importedTypes
        ]
        <> Set.fromList
          [ reference
          | nominal <- literalNominals,
            ConsumerNominal binding <- [resolvedNominalOwnership nominal],
            reference <-
              qualifiedValueReference (consumerNominalBinding binding)
                : case resolvedNominalRepresentation nominal of
                  EnumRepresentation constructors ->
                    [ nominalRepresentationConstructorReference (aContext aggregate) nominal constructor
                    | (constructor, _) <- NE.toList constructors
                    ]
                  _ -> []
          ]
    )

typedExpressionImportTypes :: TypedScalarExpr -> [ResolvedAggregateType]
typedExpressionImportTypes expression = own <> concatMap typedExpressionImportTypes (typedExpressionChildren expression)
  where
    own = case typedScalarNode expression of
      TypedLiteral {} -> [typedScalarType expression]
      TypedRoot provenance -> [scalarRootType provenance]
      TypedProject provenance _ -> [scalarRootType provenance]
      _ -> []

scalarRootType :: ScalarRootProvenance -> ResolvedAggregateType
scalarRootType = \case
  ScalarRegisterRoot _ resolvedType -> resolvedType
  ScalarCommandRoot _ resolvedType -> resolvedType

isStructuralProjection :: ProjectionAliasTarget -> Bool
isStructuralProjection StructuralProjectionAlias {} = True
isStructuralProjection NominalProjectionAlias {} = False

isGeneratedNominalProjection :: ProjectionAliasTarget -> Bool
isGeneratedNominalProjection (NominalProjectionAlias nominal _) = resolvedNominalOwnership nominal == GeneratedNominal
isGeneratedNominalProjection StructuralProjectionAlias {} = False

isConsumerNominalProjection :: ProjectionAliasTarget -> Bool
isConsumerNominalProjection (NominalProjectionAlias nominal _) = case resolvedNominalOwnership nominal of
  ConsumerNominal {} -> True
  GeneratedNominal -> False
isConsumerNominalProjection StructuralProjectionAlias {} = False

expressionOperatorOrder :: [Text]
expressionOperatorOrder = [".*", ".+", ".-", ".==", "./=", ".<", ".<=", ".>", ".>=", ".&&", ".||"]

generatedTransitionOperators :: ResolvedGeneratedTransition -> [Text]
generatedTransitionOperators resolved =
  maybe [] expressionPredicateOperators (resolvedTransitionGuard resolved)
    <> concatMap (expressionTermOperators . snd) (resolvedTransitionWrites resolved)

outcomeExpressionOperators :: TypedScalarExpr -> [Text]
outcomeExpressionOperators expression = case typedScalarNode expression of
  TypedEqual {} -> expressionPredicateOperators expression
  TypedNotEqual {} -> expressionPredicateOperators expression
  TypedCompare {} -> expressionPredicateOperators expression
  TypedAnd {} -> expressionPredicateOperators expression
  TypedOr {} -> expressionPredicateOperators expression
  _ -> expressionTermOperators expression

expressionPredicateOperators :: TypedScalarExpr -> [Text]
expressionPredicateOperators expression = case typedScalarNode expression of
  TypedEqual left right -> ".==" : expressionTermOperators left <> expressionTermOperators right
  TypedNotEqual left right -> "./=" : expressionTermOperators left <> expressionTermOperators right
  TypedCompare operator left right -> renderComparisonOperator operator : expressionTermOperators left <> expressionTermOperators right
  TypedAnd left right -> ".&&" : expressionPredicateOperators left <> expressionPredicateOperators right
  TypedOr left right -> ".||" : expressionPredicateOperators left <> expressionPredicateOperators right
  _ -> ".==" : expressionTermOperators expression

expressionTermOperators :: TypedScalarExpr -> [Text]
expressionTermOperators expression = case typedScalarNode expression of
  TypedAdd _ left right -> ".+" : expressionTermOperators left <> expressionTermOperators right
  TypedSubtract _ left right -> ".-" : expressionTermOperators left <> expressionTermOperators right
  TypedMultiply _ left right -> ".*" : expressionTermOperators left <> expressionTermOperators right
  _ -> concatMap expressionTermOperators (typedExpressionChildren expression)

anyHoleOwned :: Agg -> Bool
anyHoleOwned = any ((== HoleImplementation) . tImplementation) . aTransitions

transducerUsesHoles :: Agg -> Bool
transducerUsesHoles aggregate =
  anyHoleOwned aggregate
    || any isHandOwned (Map.elems (aOutputMappings aggregate))
  where
    isHandOwned HandOwnedEventOutput {} = True
    isHandOwned GeneratedCommandIdentity {} = False

renderVerificationList :: Agg -> [Text]
renderVerificationList aggregate =
  [ (if listIndex == (0 :: Int) then "  [ " else "  , ")
      <> "verifyTransition "
      <> tshow (transitionStem transitionIndex transition)
      <> " "
      <> ownership
      <> " "
      <> vertexCtor aggregate source
      <> " "
      <> tshow' edgeIndex
  | (listIndex, (source, edgeIndex, transitionIndex, transition)) <- zip [0 ..] entries,
    let ownership = case tImplementation transition of
          GeneratedImplementation -> "GeneratedOwned"
          HoleImplementation -> "HoleOwned"
          LegacyHoleImplementation -> error "legacy transition reached version-2 verification generation"
  ]
    <> ["  ]"]
  where
    entries =
      [ (source, edgeIndex, transitionIndex, transition)
      | (source, transitions) <- groupTransitionLayoutBySource (transitionLayout (aTransitions aggregate)),
        entry <- transitions,
        let edgeIndex = layoutOutgoingIndex entry
            transitionIndex = layoutDeclarationIndex entry
            transition = layoutTransition entry
      ]

foldFingerprintExpression :: Agg -> Text
foldFingerprintExpression aggregate = case holeVersions of
  [] -> tshow (aFoldFingerprint aggregate)
  _ ->
    "T.intercalate \"|\" ("
      <> tshow (aFoldFingerprint aggregate)
      <> " : [foldToken "
      <> T.intercalate ", foldToken " holeVersions
      <> "] ) where foldToken (FoldVersion token) = T.pack (show (T.length token)) <> \":\" <> token"
  where
    holeVersions =
      [ "Holes." <> holeFoldVersionName index transition
      | (index, transition) <- transitionEntries aggregate,
        tImplementation transition == HoleImplementation
      ]

groupTransitionEntriesBySource :: Agg -> [(Text, [(Int, Transition)])]
groupTransitionEntriesBySource aggregate =
  [ ( source,
      [(layoutDeclarationIndex entry, layoutTransition entry) | entry <- entries]
    )
  | (source, entries) <- groupTransitionLayoutBySource (transitionLayout (aTransitions aggregate))
  ]

generatedFromBlock :: HaskellImportPlan -> Agg -> [ResolvedGeneratedTransition] -> (Text, [(Int, Transition)]) -> [Text]
generatedFromBlock importPlan aggregate resolvedTransitions (source, transitions) =
  ["    B.from " <> vertexCtor aggregate source <> " do"]
    ++ concatMap (uncurry (generatedOnCmdBlock importPlan aggregate resolvedTransitions)) transitions

generatedOnCmdBlock :: HaskellImportPlan -> Agg -> [ResolvedGeneratedTransition] -> Int -> Transition -> [Text]
generatedOnCmdBlock importPlan aggregate resolvedTransitions index transition =
  ["      B.onCmd inCtor" <> tCommand transition <> " $ \\" <> payloadBinder <> " -> B.do"]
    ++ projectionBindingLines
    ++ ["        B.replayOnly" | tMode transition == TmReplayOnly]
    ++ generatedBehavior
    ++ outputLines
    ++ ["        B.noEmit" | null (tEmits transition)]
    ++ ["        B.goto " <> vertexCtor aggregate (tGoto transition)]
  where
    generatedBehavior = case tImplementation transition of
      GeneratedImplementation ->
        maybe [] (renderGuardLines importPlan aliases aggregate transition) (resolvedTransitionGuard resolved)
          ++ [ "        B.slot @" <> tshow registerName <> " =: " <> renderAssignmentOperand (renderKeikiTerm importPlan aliases aggregate transition expression)
             | (registerName, expression) <- resolvedTransitionWrites resolved
             ]
      HoleImplementation -> ["        Holes." <> holeFunctionName index transition <> " d"]
      LegacyHoleImplementation -> error "legacy transition reached version-2 transducer generation"
    resolved =
      fromMaybe
        (error ("resolved generated transition disappeared: " <> show index))
        (find ((== index) . resolvedTransitionIndex) resolvedTransitions)
    aliases
      | tImplementation transition == GeneratedImplementation = projectionAliasesForTransition resolved
      | otherwise = []
    projectionBindingLines = case aliases of
      [] -> []
      firstAlias : remainingAliases ->
        ["        let " <> renderProjectionAliasBinding importPlan aggregate transition firstAlias]
          <> ["            " <> renderProjectionAliasBinding importPlan aggregate transition alias | alias <- remainingAliases]
    outputLines =
      concat
        [ generatedOutputLines aggregate index transition emitIndex eventName
        | (emitIndex, eventName) <- zip [1 ..] (tEmits transition)
        ]
    payloadBinder
      | payloadIsUsed = "d"
      | otherwise = "_d"
    payloadIsUsed = case tImplementation transition of
      GeneratedImplementation ->
        isJust (resolvedTransitionGuard resolved)
          || not (null (resolvedTransitionWrites resolved))
          || any outputUsesPayload (zip [1 ..] (tEmits transition))
      HoleImplementation -> True
      LegacyHoleImplementation -> True
    outputUsesPayload (emitIndex, _) = case outputMappingFor aggregate index emitIndex of
      GeneratedCommandIdentity _ fields -> not (null fields)
      HandOwnedEventOutput {} -> True

renderProjectionAliasBinding :: HaskellImportPlan -> Agg -> Transition -> ProjectionAlias -> Text
renderProjectionAliasBinding importPlan aggregate transition alias =
  projectionAliasName alias <> " = " <> case projectionAliasTarget alias of
    StructuralProjectionAlias provenance projection -> renderStructuralProjectionTerm importPlan aggregate transition provenance projection
    NominalProjectionAlias nominal provenance -> renderNominalProjectionTerm importPlan aggregate transition nominal provenance

renderGuardLines :: HaskellImportPlan -> [ProjectionAlias] -> Agg -> Transition -> TypedScalarExpr -> [Text]
renderGuardLines importPlan aliases aggregate transition expression =
  ["        B.requireGuard $"]
    <> ["          " <> line | line <- T.lines readable]
  where
    readable =
      T.replace " .|| " "\n.|| "
        . T.replace " .&& " "\n.&& "
        $ renderKeikiPredicate importPlan aliases aggregate transition expression

renderAssignmentOperand :: RenderedKeikiExpr -> Text
renderAssignmentOperand expression
  | renderedKeikiPrecedence expression <= 6 = "(" <> renderedKeikiText expression <> ")"
  | otherwise = renderedKeikiText expression

generatedOutputLines :: Agg -> Int -> Transition -> Int -> Name -> [Text]
generatedOutputLines aggregate transitionIndex transition emitIndex eventName =
  case outputMappingFor aggregate transitionIndex emitIndex of
    GeneratedCommandIdentity sourceCommand fields -> case fields of
      [] -> ["        B.emit wire" <> eventName <> " B.oNil"]
      _ ->
        [ "        B.emit wire" <> eventName <> " (" <> eventName <> "TermFields"
        ]
          <> [ lead fieldIndex
                 <> resolvedSelector sourceCommand field
                 <> " = d."
                 <> resolvedSelector sourceCommand field
             | (fieldIndex, field) <- zip [0 :: Int ..] fields
             ]
          <> ["          })"]
    HandOwnedEventOutput {} ->
      [ "        B.emit wire"
          <> eventName
          <> " (Holes."
          <> outputFunctionName transitionIndex transition emitIndex eventName
          <> " d)"
      ]
  where
    lead 0 = "          { "
    lead _ = "          , "
    resolvedSelector sourceCommand copiedField =
      commandFieldSelector aggregate sourceCommand (outputSelector copiedField)

commandFieldSelector :: Agg -> Name -> Name -> Text
commandFieldSelector aggregate commandName dslFieldName =
  case [ fieldSelector identity
       | command <- aCommands aggregate,
         rcName command == commandName,
         (identity, _) <- rcFields command,
         fieldDslName identity == dslFieldName
       ] of
    selector : _ -> selector
    [] -> error "validated generated command-field selector was not found"

outputMappingFor :: Agg -> Int -> Int -> EventOutputMapping
outputMappingFor aggregate transitionIndex emitIndex =
  fromMaybe
    (error ("missing checked event-output mapping for transition " <> show transitionIndex <> ", emit " <> show emitIndex))
    (Map.lookup (transitionIndex, emitIndex) (aOutputMappings aggregate))

--------------------------------------------------------------------------------
-- EventStream module
--------------------------------------------------------------------------------

emitEventStream :: Agg -> Text
emitEventStream a =
  nl $
    renderGeneratedLanguagePragmas [ExtOverloadedLabels | outcomeUsesLabels]
      ++ [ generatedBanner,
           "module " <> aGenPrefix a <> ".EventStream",
           "  ( " <> lowerFirst (aName a) <> "Category",
           "  , " <> lowerFirst (aName a) <> "CommandCategory",
           "  , " <> lowerFirst (aName a) <> "EventStream",
           "  , " <> lowerFirst (aName a) <> "EventStreamDef",
           "  , " <> aName a <> "EventStream",
           "  , " <> aName a <> "EventStreamDef"
         ]
      ++ ["  , " <> lowerFirst (aName a) <> "SnapshotFixture" | hasSnapshot a]
      ++ ["  , " <> lowerFirst (aName a) <> "DomainCommandHandler" | outcomeEnabled]
      ++ [ "  ) where",
           "",
           "import " <> aGenPrefix a <> ".Domain",
           "import " <> aGenPrefix a <> ".Codec (" <> lowerFirst (aName a) <> "Codec)",
           transducerImport a
         ]
      ++ generatedOutcomeNominalImports
      ++ structuralProjectionImports
      ++ generatedNominalProjectionImports
      ++ consumerNominalProjectionImports
      ++ consumerImports
      ++ ["import Data.KindID qualified as KindID" | outcomeUsesConsumerIdLiteral]
      ++ ["import Keiro.Codec.Nominal (nominalFromRepresentation)" | outcomeUsesConsumerNominalLiteral]
      ++ ["import Keiki.Builder qualified as B" | outcomeUsesRegisterRoot]
      ++ [keikiCoreImport]
      ++ ["import Keiki.Core qualified as K" | outcomeEnabled]
      ++ ["import Keiki.Generics (RegFieldsOf)" | outcomeUsesCommandRoot]
      ++ ["import Keiro.Command (DomainCommandHandler (..), SilentCommandContext (..), SilentDomainDecision (..))" | outcomeEnabled]
      ++ [ "import Keiro.EventStream (EventStream (..), SnapshotPolicy (..))",
           "import Keiro.EventStream.Validate (ValidatedEventStream, mkEventStreamOrThrow)"
         ]
      ++ ["import Data.Text (Text)" | hasSnapshot a || outcomeUsesText]
      ++ ["import Data.Time.Calendar (fromGregorian)" | outcomeUsesTimeLiteral]
      ++ ["import Data.Time.Clock (UTCTime (..), picosecondsToDiffTime)" | outcomeUsesTimeLiteral]
      ++ ["import Data.Time.Clock (UTCTime)" | outcomeUsesTimeType && not outcomeUsesTimeLiteral]
      ++ ["import Numeric.Natural (Natural)" | outcomeUsesNaturalType]
      ++ ["import Keiro.Snapshot.Codec (defaultStateCodec, withFoldFingerprint)" | hasSnapshot a]
      ++ [ "import Keiro.Stream qualified as Stream",
           "",
           "-- The validated aggregate stream category (hole-kind 5: referenced, never retyped).",
           "-- Entity streams are '<category>-<id>' via Keiro.Stream.entityStream.",
           "-- categoryUnsafe is safe here because this generated literal passed the DSL category proof.",
           lowerFirst (aName a) <> "Category :: Stream.StreamCategory " <> aName a <> "EventStreamDef",
           lowerFirst (aName a) <> "Category = Stream.categoryUnsafe " <> tshow categoryName,
           "",
           "-- The same category text, typed for command envelopes such as PMCommand.",
           lowerFirst (aName a) <> "CommandCategory :: Stream.StreamCategory " <> aName a <> "Command",
           lowerFirst (aName a) <> "CommandCategory = Stream.categoryUnsafe " <> tshow categoryName,
           "",
           "type " <> aName a <> "EventStreamDef =",
           "  EventStream (HsPred " <> aName a <> "Regs " <> aName a <> "Command) " <> aName a <> "Regs " <> aVertexType a <> " " <> aName a <> "Command " <> aName a <> "Event",
           "",
           "type " <> aName a <> "EventStream =",
           "  ValidatedEventStream (HsPred " <> aName a <> "Regs " <> aName a <> "Command) " <> aName a <> "Regs " <> aVertexType a <> " " <> aName a <> "Command " <> aName a <> "Event",
           "",
           lowerFirst (aName a) <> "EventStreamDef :: " <> aName a <> "EventStreamDef",
           lowerFirst (aName a) <> "EventStreamDef =",
           "  EventStream",
           "    { transducer = " <> lowerFirst (aName a) <> "Transducer,",
           "      initialState = " <> initialVertex a <> ",",
           "      initialRegisters = initial" <> aName a <> "Regs,",
           "      eventCodec = " <> lowerFirst (aName a) <> "Codec,",
           "      resolveStreamName = Stream.streamName,",
           "      snapshotPolicy = " <> snapshotPolicyExpr a <> ","
         ]
      ++ stateCodecFieldLines a
      ++ [ "    }",
           ""
         ]
      ++ snapshotFixtureLines a
      ++ [ lowerFirst (aName a) <> "EventStream :: " <> aName a <> "EventStream",
           lowerFirst (aName a) <> "EventStream =",
           "  mkEventStreamOrThrow " <> tshow (aName a) <> " " <> lowerFirst (aName a) <> "EventStreamDef"
         ]
      ++ outcomeHandlerLines importPlan a silentOutcomes
  where
    categoryName = staticCategory ("aggregate " <> aName a) (lowerFirst (aName a))
    outcomeEnabled = isJust (aDomainOutcomeTypes a)
    silentOutcomes = resolvedSilentOutcomes a
    outcomeExpressions = map resolvedSilentReason silentOutcomes
    outcomeResultTypes = case aDomainOutcomeTypes a of
      Nothing -> []
      Just outcomeTypes -> [resolvedRejectionType outcomeTypes, resolvedNoOpType outcomeTypes]
    outcomeImportTypes =
      nub
        ( outcomeResultTypes
            <> concatMap typedExpressionImportTypes outcomeExpressions
            <> concatMap typedExpressionLiteralTypes outcomeExpressions
        )
    consumerLiteralNominals = nub [nominal | expression <- outcomeExpressions, nominal <- typedConsumerLiteralNominals expression]
    importPlan = eventStreamImportPlan a outcomeImportTypes consumerLiteralNominals
    consumerImports = T.lines (renderPlannedImports importPlan)
    generatedOutcomeNominals =
      stableNominals
        ( generatedNominalsInTypes outcomeResultTypes
            <> [nominal | expression <- outcomeExpressions, nominal <- typedGeneratedNominals expression]
        )
    generatedLiteralNominals =
      stableNominals
        [ nominal
        | expression <- outcomeExpressions,
          literal <- typedExpressionLiterals expression,
          nominal <- typedGeneratedNominals literal
        ]
    generatedOutcomeNominalImports =
      generatedNominalTypeImportsWithParsers
        (aggregateCheckedService a)
        (aContext a)
        generatedOutcomeNominals
        generatedLiteralNominals
    projectionTargets = nub (concatMap projectionAliasTargets outcomeExpressions)
    structuralProjectionImports =
      [ "import " <> structuralProjectionModule (aContext a) <> " qualified as StructuralProjections"
      | any isStructuralProjection projectionTargets
      ]
    generatedNominalProjectionImports =
      [ "import " <> generatedNominalModule (aContext a) <> " qualified as GeneratedNominals"
      | any isGeneratedNominalProjection projectionTargets
      ]
    consumerNominalProjectionImports =
      [ "import " <> nominalProjectionModule (aContext a) <> " qualified as NominalProjections"
      | any isConsumerNominalProjection projectionTargets
      ]
    outcomeUsesRegisterRoot = any (anyTypedExpression usesRegisterRoot) outcomeExpressions
    outcomeUsesCommandRoot = any (anyTypedExpression usesCommandRoot) outcomeExpressions
    outcomeUsesLabels = outcomeUsesCommandRoot || not (null projectionTargets)
    outcomeUsesText =
      AggregateText `elem` outcomeImportTypes
        || any (anyTypedExpression isTextLiteral) outcomeExpressions
        || any isNominalProjection projectionTargets
    outcomeUsesTimeLiteral = any (anyTypedExpression isTimeLiteral) outcomeExpressions
    outcomeUsesTimeType = AggregateTime `elem` outcomeImportTypes
    outcomeUsesNaturalType = AggregateNatural `elem` outcomeImportTypes
    outcomeUsesConsumerNominalLiteral = not (null consumerLiteralNominals)
    outcomeUsesConsumerIdLiteral = any (isIdRepresentation . resolvedNominalRepresentation) consumerLiteralNominals
    usedOperators = nub (concatMap outcomeExpressionOperators outcomeExpressions)
    keikiCoreImport
      | not outcomeEnabled = "import Keiki.Core (HsPred)"
      | otherwise =
          "import Keiki.Core (EdgeRef (..), HsPred"
            <> T.concat [", (" <> operator <> ")" | operator <- expressionOperatorOrder, operator `elem` usedOperators]
            <> ")"
    usesRegisterRoot expression = case typedScalarNode expression of
      TypedRoot ScalarRegisterRoot {} -> True
      TypedProject provenance _ -> case provenance of
        ScalarRegisterRoot {} -> True
        ScalarCommandRoot {} -> False
      _ -> False
    usesCommandRoot expression = case typedScalarNode expression of
      TypedRoot ScalarCommandRoot {} -> True
      TypedProject provenance _ -> case provenance of
        ScalarCommandRoot {} -> True
        ScalarRegisterRoot {} -> False
      _ -> False
    isTextLiteral expression = case typedScalarNode expression of
      TypedLiteral ScalarTextValue {} -> True
      _ -> False
    isTimeLiteral expression = case typedScalarNode expression of
      TypedLiteral ScalarTimeValue {} -> True
      _ -> False
    isNominalProjection NominalProjectionAlias {} = True
    isNominalProjection StructuralProjectionAlias {} = False
    isIdRepresentation IdRepresentation {} = True
    isIdRepresentation _ = False

outcomeHandlerLines :: HaskellImportPlan -> Agg -> [ResolvedSilentOutcome] -> [Text]
outcomeHandlerLines importPlan aggregate silentOutcomes = case aDomainOutcomeTypes aggregate of
  Nothing -> []
  Just outcomeTypes ->
    [ "",
      handlerName,
      "  :: DomainCommandHandler",
      "       (HsPred " <> aName aggregate <> "Regs " <> aName aggregate <> "Command)",
      "       " <> aName aggregate <> "Regs",
      "       " <> aVertexType aggregate,
      "       " <> aName aggregate <> "Command",
      "       " <> aName aggregate <> "Event",
      "       " <> renderDomainType importPlan aggregate (resolvedRejectionType outcomeTypes),
      "       " <> renderDomainType importPlan aggregate (resolvedNoOpType outcomeTypes),
      handlerName <> " =",
      "  DomainCommandHandler " <> lowerFirst (aName aggregate) <> "EventStream " <> classifierName,
      "",
      classifierName,
      "  :: SilentCommandContext " <> aName aggregate <> "Regs " <> aVertexType aggregate <> " " <> aName aggregate <> "Command",
      "  -> SilentDomainDecision",
      "       " <> renderDomainType importPlan aggregate (resolvedRejectionType outcomeTypes),
      "       " <> renderDomainType importPlan aggregate (resolvedNoOpType outcomeTypes),
      classifierName <> " (SilentCommandContext _ registers command (EdgeRef edgeSource edgeIndex)) =",
      "  case edgeSource of"
    ]
      ++ concatMap renderSourceGroup sourceGroups
      ++ [ "    _ -> outcomeInvariant edgeSource edgeIndex",
           " where",
           "  outcomeInvariant source index =",
           "    error ("
             <> tshow ("generated domain outcome invariant failed for aggregate " <> aName aggregate <> " edge ")
             <> " <> show source <> \"#\" <> show index)"
         ]
  where
    handlerName = lowerFirst (aName aggregate) <> "DomainCommandHandler"
    classifierName = lowerFirst (aName aggregate) <> "SilentDecision"
    sourceGroups =
      [ (source, filter ((== source) . tSource . layoutTransition . resolvedSilentLayout) silentOutcomes)
      | source <- nub (map (tSource . layoutTransition . resolvedSilentLayout) silentOutcomes)
      ]
    renderSourceGroup (source, outcomes) =
      [ "    " <> vertexCtor aggregate source <> " ->",
        "      case edgeIndex of"
      ]
        ++ map renderArm outcomes
        ++ ["        _ -> outcomeInvariant edgeSource edgeIndex"]
    renderArm outcome =
      let entry = resolvedSilentLayout outcome
          transition = layoutTransition entry
          constructor = case resolvedSilentKind outcome of
            RejectedOutcome -> "SilentRejected"
            NoOpOutcome -> "SilentNoOp"
       in "        "
            <> tshow' (layoutOutgoingIndex entry)
            <> " -> "
            <> constructor
            <> " ("
            <> renderOutcomeReasonEvaluation importPlan aggregate transition (resolvedSilentReason outcome)
            <> ")"

eventStreamImportPlan :: Agg -> [ResolvedAggregateType] -> [ResolvedNominalType] -> HaskellImportPlan
eventStreamImportPlan aggregate importedTypes literalNominals =
  planImportsOrDie
    (aGenPrefix aggregate <> ".EventStream")
    localDeclarations
    ( Set.unions
        [ aggregateSourceReferences (aggregateConsumerHaskellSource (aSymbols aggregate) resolvedType)
        | resolvedType <- importedTypes
        ]
        <> Set.fromList
          [ reference
          | nominal <- literalNominals,
            ConsumerNominal binding <- [resolvedNominalOwnership nominal],
            reference <-
              qualifiedValueReference (consumerNominalBinding binding)
                : case resolvedNominalRepresentation nominal of
                  EnumRepresentation constructors ->
                    [ nominalRepresentationConstructorReference (aContext aggregate) nominal constructor
                    | (constructor, _) <- NE.toList constructors
                    ]
                  _ -> []
          ]
    )
  where
    localDeclarations =
      Set.fromList
        ( [ aVertexType aggregate,
            aName aggregate <> "Command",
            aName aggregate <> "Event",
            aName aggregate <> "Regs",
            aName aggregate <> "EventStream",
            aName aggregate <> "EventStreamDef"
          ]
            <> map resolvedNominalName (aGeneratedNominals aggregate)
            <> [ resolvedNominalName nominal
               | resolvedType <- importedTypes,
                 AggregateNominal nominal <- [resolvedType],
                 GeneratedNominal <- [resolvedNominalOwnership nominal]
               ]
        )

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
      <> foldFingerprintValue aggregate
      <> " (defaultStateCodec "
      <> tshow' (snapCodecVersion snapshot)
      <> "))"

transducerImport :: Agg -> Text
transducerImport aggregate
  | hasVersion2Ownership aggregate =
      "import "
        <> aGenPrefix aggregate
        <> ".Transducer ("
        <> (if hasSnapshot aggregate then lowerFirst (aName aggregate) <> "FoldFingerprint, " else "")
        <> lowerFirst (aName aggregate)
        <> "Transducer)"
  | otherwise =
      "import "
        <> aHolePrefix aggregate
        <> ".Holes ("
        <> lowerFirst (aName aggregate)
        <> "Transducer)"

foldFingerprintValue :: Agg -> Text
foldFingerprintValue aggregate
  | hasVersion2Ownership aggregate = lowerFirst (aName aggregate) <> "FoldFingerprint"
  | otherwise = tshow (aFoldFingerprint aggregate)

stateCodecFieldLines :: Agg -> [Text]
stateCodecFieldLines aggregate = case aSnapshot aggregate of
  Nothing -> ["      stateCodec = Nothing"]
  Just _
    | hasVersion2Ownership aggregate ->
        [ "      -- The snapshot discriminator composes: the spec's state-codec version (bump it",
          "      -- in the spec's `state-codec version=` clause), keiki's register and",
          "      -- control-state shape hashes, and this fold fingerprint derived from the",
          "      -- spec's transition surface (guards, writes, emits, states, register",
          "      -- initials, referenced rules). Spec-visible fold changes invalidate old",
          "      -- snapshots automatically. Version-2 Hole-owned transitions additionally",
          "      -- compose their explicit hand-owned FoldVersion tokens here; bump the",
          "      -- corresponding token whenever that Hole behavior changes.",
          "      stateCodec = " <> stateCodecExpr aggregate
        ]
    | otherwise ->
        [ "      -- The snapshot discriminator composes: the spec's state-codec version (bump it",
          "      -- in the spec's `state-codec version=` clause), keiki's register and",
          "      -- control-state shape hashes, and this fold fingerprint derived from the",
          "      -- spec's transition surface (guards, writes, emits, states, register",
          "      -- initials, referenced rules). Spec-visible fold changes invalidate old",
          "      -- snapshots automatically. Fold changes made ONLY in the hand-owned Holes",
          "      -- module are invisible here: bump `state-codec version=` manually or old",
          "      -- snapshots will be served stale.",
          "      stateCodec = " <> stateCodecExpr aggregate
        ]

snapshotFixtureLines :: Agg -> [Text]
snapshotFixtureLines aggregate = case aSnapshot aggregate of
  Nothing -> []
  Just snapshot ->
    [ lowerFirst (aName aggregate) <> "SnapshotFixture :: (Int, Text)",
      lowerFirst (aName aggregate) <> "SnapshotFixture = (" <> tshow' (snapCodecVersion snapshot) <> ", " <> tshow (snapShapeHash snapshot) <> ")",
      ""
    ]

--------------------------------------------------------------------------------
-- Projection module
--------------------------------------------------------------------------------

emitProjection :: Agg -> Text
emitProjection a = case aProjection a of
  Nothing ->
    nl
      ( renderGeneratedLanguagePragmas []
          <> [ generatedBanner,
               "module " <> aGenPrefix a <> ".Projection () where",
               "",
               "-- No projection declarations are present; this module keeps the generated manifest inventory total."
             ]
      )
  Just p ->
    nl
      [ generatedBanner,
        "module " <> aGenPrefix a <> ".Projection",
        "  ( " <> lowerFirst (projTable p) <> "Projection",
        "  , " <> lowerFirst (projTable p) <> "StatusFor",
        "  ) where",
        "",
        "import " <> aGenPrefix a <> ".Domain",
        "import " <> aHolePrefix a <> ".Holes (apply" <> pascal (projTable p) <> ")",
        "import Data.Text (Text)",
        "import Keiro.Projection (InlineProjection (..))",
        "",
        "-- The deterministic event->status mapping (hole-kind 3, /mapping/), derived",
        "-- from the spec's status-map. The read-model SQL that consumes it lives in",
        "-- the hand-owned Holes module (a DB-coupled hole, delegated to codd).",
        projectionTableComment a p,
        lowerFirst (projTable p) <> "StatusFor :: " <> aName a <> "Event -> Maybe Text",
        lowerFirst (projTable p) <> "StatusFor = \\case",
        nl (statusArms a p),
        "",
        lowerFirst (projTable p) <> "Projection :: InlineProjection " <> aName a <> "Event",
        lowerFirst (projTable p) <> "Projection =",
        "  InlineProjection",
        "    { name = " <> tshow (contextNameToProjName a p),
        "    , apply = apply" <> pascal (projTable p),
        "    }"
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
emitHoles aggregate
  | hasVersion2Ownership aggregate = emitVersion2Holes aggregate
  | otherwise = emitLegacyHoles aggregate

emitLegacyHoles :: Agg -> Text
emitLegacyHoles a =
  nl
    [ "{-# LANGUAGE BlockArguments #-}",
      "{-# LANGUAGE DataKinds #-}",
      "{-# LANGUAGE OverloadedRecordDot #-}",
      "{-# LANGUAGE QualifiedDo #-}",
      "{-# LANGUAGE TypeApplications #-}",
      "-- This is a HAND-OWNED hole module. keiro-dsl creates it once and never",
      "-- overwrites it. Fill the transducer body (and any other holes) against the",
      "-- generated signatures, then run the harness to confirm behaviour.",
      "module " <> aHolePrefix a <> ".Holes",
      "  ( " <> lowerFirst (aName a) <> "Transducer",
      holeProjectionExport a,
      holeUpcasterExports a,
      "  ) where",
      "",
      "import " <> aGenPrefix a <> ".Domain",
      "import Keiki.Builder ((=:))",
      "import qualified Keiki.Builder as B",
      "import Keiki.Core (HsPred, RegFile, SymTransducer, lit, (.==), (./=), (.||))",
      holeUpcasterImports a,
      holeProjectionImports a,
      "",
      "-- HOLE: the transducer body. Reproduce the structure below, replacing each",
      "-- `-- HOLE` line with the keiki symbolic operators it describes.",
      lowerFirst (aName a) <> "Transducer",
      "  :: SymTransducer",
      "       (HsPred " <> aName a <> "Regs " <> aName a <> "Command)",
      "       " <> aName a <> "Regs",
      "       " <> aVertexType a,
      "       " <> aName a <> "Command",
      "       " <> aName a <> "Event",
      lowerFirst (aName a) <> "Transducer =",
      "  B.buildTransducer " <> initialVertex a <> " initial" <> aName a <> "Regs isTerminal do",
      nl (concatMap (fromBlock a) (groupBySource a)),
      " where",
      "  isTerminal = \\case",
      nl ["    " <> vertexCtor a (stName s) <> " -> True" | s <- aStates a, stTerminal s],
      "    _ -> False",
      holeProjectionStub a,
      holeUpcasterStubs a
    ]

emitVersion2Holes :: Agg -> Text
emitVersion2Holes aggregate =
  nl $
    [ "{-# LANGUAGE BlockArguments #-}",
      "{-# LANGUAGE DataKinds #-}",
      "{-# LANGUAGE DuplicateRecordFields #-}",
      "{-# LANGUAGE OverloadedRecordDot #-}",
      "{-# LANGUAGE QualifiedDo #-}",
      "{-# LANGUAGE TypeApplications #-}",
      "-- This is a HAND-OWNED version-2 hook module. keiro-dsl creates it once",
      "-- and never overwrites it. Generated code owns every transition envelope",
      "-- and every declared guard/write. This module supplies explicit event-field",
      "-- mappings and explicitly selected Hole behavior only; fields(Command)",
      "-- identity mappings are generated directly and have no hook."
    ]
      ++ version2HoleModuleDeclaration aggregate
      ++ [ "",
           "import " <> aGenPrefix aggregate <> ".Domain",
           "import Keiki.Builder qualified as B",
           "import Keiki.Generics (RegFieldsOf)",
           holeUpcasterImports aggregate,
           holeProjectionImports aggregate
         ]
      ++ ["import Keiki.Core qualified as K" | anyHoleOwned aggregate || anyZeroFieldOutput aggregate]
      ++ ["import Keiro.Snapshot.Codec (FoldVersion (..))" | anyHoleOwned aggregate]
      ++ concatMap (uncurry (emitOutputHooks aggregate)) (transitionEntries aggregate)
      ++ concatMap (uncurry (emitHoleImplementation aggregate)) (transitionEntries aggregate)
      ++ [holeProjectionStub aggregate, holeUpcasterStubs aggregate]

anyZeroFieldOutput :: Agg -> Bool
anyZeroFieldOutput aggregate =
  or
    [ isHandOwned (outputMappingFor aggregate transitionIndex emitIndex)
        && null (rcFields (eventForName aggregate eventName))
    | (transitionIndex, transition) <- transitionEntries aggregate,
      (emitIndex, eventName) <- zip [1 ..] (tEmits transition)
    ]
  where
    isHandOwned HandOwnedEventOutput {} = True
    isHandOwned GeneratedCommandIdentity {} = False

version2HoleModuleDeclaration :: Agg -> [Text]
version2HoleModuleDeclaration aggregate = case version2HoleExports aggregate of
  [] -> ["module " <> aHolePrefix aggregate <> ".Holes () where"]
  firstExport : rest ->
    [ "module " <> aHolePrefix aggregate <> ".Holes",
      "  ( " <> firstExport
    ]
      ++ ["  , " <> value | value <- rest]
      ++ ["  ) where"]

version2HoleExports :: Agg -> [Text]
version2HoleExports aggregate =
  outputExports
    <> holeExports
    <> projectionExports
    <> [functionName | (_, _, functionName) <- upcasterEntries aggregate]
  where
    outputExports =
      [ outputFunctionName transitionIndex transition emitIndex eventName
      | (transitionIndex, transition) <- transitionEntries aggregate,
        (emitIndex, eventName) <- zip [1 ..] (tEmits transition),
        HandOwnedEventOutput {} <- [outputMappingFor aggregate transitionIndex emitIndex]
      ]
    holeExports =
      concat
        [ [holeFunctionName index transition, holeFoldVersionName index transition]
        | (index, transition) <- transitionEntries aggregate,
          tImplementation transition == HoleImplementation
        ]
    projectionExports = case aProjection aggregate of
      Nothing -> []
      Just projection -> ["apply" <> pascal (projTable projection)]

emitOutputHooks :: Agg -> Int -> Transition -> [Text]
emitOutputHooks aggregate transitionIndex transition =
  concat
    [ emitOutputHook aggregate transitionIndex transition emitIndex (eventForName aggregate eventName)
    | (emitIndex, eventName) <- zip [1 ..] (tEmits transition),
      HandOwnedEventOutput {} <- [outputMappingFor aggregate transitionIndex emitIndex]
    ]

emitOutputHook :: Agg -> Int -> Transition -> Int -> ResolvedCtor -> [Text]
emitOutputHook aggregate transitionIndex transition emitIndex event =
  [ "",
    "-- Hand-owned event-field hook inside the generated transition envelope.",
    functionName
      <> " :: "
      <> payloadProjectionType aggregate transition
      <> " -> "
      <> outputType,
    functionName <> " d = " <> outputValue
  ]
  where
    functionName = outputFunctionName transitionIndex transition emitIndex (rcName event)
    inputFields = "(" <> commandFieldsType transition <> ")"
    outputType
      | null (rcFields event) =
          "K.OutFields "
            <> aName aggregate
            <> "Regs "
            <> aName aggregate
            <> "Command "
            <> inputFields
            <> " ()"
      | otherwise =
          rcName event
            <> "TermFields "
            <> aName aggregate
            <> "Regs "
            <> aName aggregate
            <> "Command "
            <> inputFields
    outputValue
      | null (rcFields event) = "B.oNil"
      | otherwise =
          rcName event
            <> "TermFields\n"
            <> nl
              ( valueRecord
                  [ (fieldSelector identity, outputFieldValue identity fieldType)
                  | (identity, fieldType) <- rcFields event
                  ]
              )
    command = commandForTransition aggregate transition
    outputFieldValue identity fieldType
      | Just (commandIdentity, commandType) <- find ((== fieldDslName identity) . fieldDslName . fst) (rcFields command),
        commandType == fieldType =
          "d." <> fieldSelector commandIdentity
      | Just register <- find ((== fieldDslName identity) . rrName) (aRegs aggregate),
        rrType register == fieldType =
          "B.reg @" <> tshow (fieldDslName identity)
      | otherwise = "error " <> tshow ("HOLE: fill output field " <> rcName event <> "." <> fieldDslName identity)
    valueRecord fields =
      [ lead fieldIndex <> fieldName <> " = " <> fieldValue
      | (fieldIndex, (fieldName, fieldValue)) <- zip [0 :: Int ..] fields
      ]
        ++ ["  }"]
    lead 0 = "  { "
    lead _ = "  , "

emitHoleImplementation :: Agg -> Int -> Transition -> [Text]
emitHoleImplementation aggregate index transition
  | tImplementation transition /= HoleImplementation = []
  | otherwise =
      [ "",
        "-- HOLE: add the predicate and ordered register updates for this transition.",
        "-- The generated transducer still owns command matching, mode, emits, and goto.",
        holeFunctionName index transition
          <> " :: "
          <> payloadProjectionType aggregate transition
          <> " -> B.EdgeBuilder "
          <> aName aggregate
          <> "Regs "
          <> aName aggregate
          <> "Command "
          <> aName aggregate
          <> "Event "
          <> aVertexType aggregate
          <> " ('Just ("
          <> commandFieldsType transition
          <> ")) writes writes ()",
        holeFunctionName index transition <> " _d = B.requireGuard K.PTop",
        "",
        "-- Bump this token whenever the Hole predicate or updates change.",
        holeFoldVersionName index transition <> " :: FoldVersion",
        holeFoldVersionName index transition <> " = FoldVersion " <> tshow (transitionStem index transition <> "-fold-v1")
      ]

-- | Export, import, and stub the per-event upcaster holes (EP-2 evolution).
holeUpcasterExports :: Agg -> Text
holeUpcasterExports a = case upcasterEntries a of
  [] -> ""
  es -> nl ["  , " <> fn | (_, _, fn) <- es]

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
        [ [ "",
            "-- HOLE upcaster: this hole receives ONLY " <> eventName <> " payloads stored at",
            "-- aggregate schema version " <> tshow' source <> "; other event kinds pass through the",
            "-- generated rung dispatch automatically. Bring this payload up one version and decide",
            "-- the default/derivation for any field added at the new version here.",
            fn <> " :: Value -> Either Text Value",
            fn <> " _ = Left \"HOLE: upcaster not implemented\""
          ]
        | (source, eventName, fn) <- es
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
      ( [ "",
          "-- HOLE: the read-model SQL for the projection (a DB-coupled hole; the",
          "-- pure event->status mapping is generated as " <> lowerFirst (projTable p) <> "StatusFor)."
        ]
          ++ projectionGuidance
          ++ [ "apply" <> pascal (projTable p) <> " :: " <> aName a <> "Event -> recorded -> txn ()",
               "apply" <> pascal (projTable p) <> " _event _recorded = " <> projectionTableUse <> "error \"HOLE: fill " <> projTable p <> " projection apply\""
             ]
      )
    where
      projectionGuidance = case projectionReadModel a of
        Nothing ->
          ["-- WARNING: no readmodel node declares this table's schema; unqualified SQL depends on search_path."]
        Just readModel ->
          [ "-- Table: " <> qualifiedTableLiteral readModel <> ". Use " <> readModelStem readModel <> "QualifiedTable; never rely on search_path.",
            "-- Declared columns:"
          ]
            ++ map (("--   " <>) . readModelColumnDoc) (rmColumns readModel)
      projectionTableUse = case projectionReadModel a of
        Nothing -> ""
        Just readModel -> readModelStem readModel <> "QualifiedTable `seq` "

-- Group transitions by source state, preserving order, for the B.from blocks.
groupBySource :: Agg -> [(Text, [Transition])]
groupBySource a =
  [ (source, map layoutTransition entries)
  | (source, entries) <- groupTransitionLayoutBySource (transitionLayout (transitionsOf a))
  ]

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

data FieldCat
  = IdCat
  | EnumCat
  | MappedStructuralCat !StructuralDecl !ResolvedMappedShape
  | MappedOpaqueCat !OpaqueDecl
  | OtherCat
  deriving stock (Eq, Show)

fieldCat :: Agg -> ResolvedAggregateType -> FieldCat
fieldCat a ty
  | AggregateNominal nominal <- ty,
    IdRepresentation {} <- resolvedNominalRepresentation nominal =
      IdCat
  | AggregateNominal nominal <- ty,
    EnumRepresentation {} <- resolvedNominalRepresentation nominal =
      EnumCat
  | Just (ResolvedStructural declaration shape) <- mappedDeclFor a ty = MappedStructuralCat declaration shape
  | Just (ResolvedOpaque declaration) <- mappedDeclFor a ty = MappedOpaqueCat declaration
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

-- | The provenance line written by a concrete scaffold plan. The package
-- version comes from Cabal's build metadata, while the language and origin come
-- from the checked semantic input and the emitted module respectively.
generatedBannerFor :: EffectiveLanguageContract -> Text -> Text
generatedBannerFor languageContract sourceOrigin =
  "-- @generated by keiro-dsl "
    <> T.pack (showVersion Package.version)
    <> " (language keiro-dsl "
    <> languageVersionText (effectiveContractLanguageVersion languageContract)
    <> ") from "
    <> stableBannerOrigin sourceOrigin
    <> "; do not edit."

-- Source line numbers are useful refusal metadata but are not stable ownership:
-- moving an unchanged node within or between workspace members must not rewrite
-- every Generated file. The node kind and name remain the banner authority.
stableBannerOrigin :: Text -> Text
stableBannerOrigin sourceOrigin =
  case T.breakOnEnd " (line " withoutMemberPath of
    (prefixWithMarker, lineWithClose)
      | not (T.null prefixWithMarker),
        Just lineNumber <- T.stripSuffix ")" lineWithClose,
        not (T.null lineNumber),
        T.all isDigit lineNumber ->
          T.dropEnd (T.length " (line ") prefixWithMarker
    _ -> withoutMemberPath
  where
    withoutMemberPath = case T.breakOn ": " sourceOrigin of
      (memberPath, attributedOrigin)
        | ".keiro" `T.isSuffixOf` memberPath,
          not (T.null attributedOrigin) ->
            T.drop 2 attributedOrigin
      _ -> sourceOrigin

-- | Recognize the exact historical banner or the frozen stamped format. This
-- intentionally rejects arbitrary comments that merely start with
-- @-- \@generated@.
isGeneratedBannerLine :: Text -> Bool
isGeneratedBannerLine line =
  line == generatedBanner
    || ( stampedPrefix `T.isPrefixOf` line
           && " (language keiro-dsl " `T.isInfixOf` line
           && ") from " `T.isInfixOf` line
           && "; do not edit." `T.isSuffixOf` line
       )
  where
    stampedPrefix = "-- @generated by keiro-dsl "

-- | Replace an emitter's legacy placeholder (or an earlier stamp) with the
-- provenance for this plan. A Generated module with a specialized banner gets
-- the standard stamp prepended, so every planned Generated file is covered.
stampGeneratedModule :: EffectiveLanguageContract -> ScaffoldModule -> ScaffoldModule
stampGeneratedModule languageContract moduleValue
  | kind moduleValue == HoleStub = moduleValue
  | otherwise = moduleValue {moduleText = stampedText}
  where
    banner = generatedBannerFor languageContract (origin moduleValue)
    sourceLines = T.splitOn "\n" (moduleText moduleValue)
    stampedText = case replaceFirstGeneratedBanner banner sourceLines of
      Nothing -> banner <> "\n" <> moduleText moduleValue
      Just linesWithStamp -> T.intercalate "\n" linesWithStamp

stampGeneratedModules :: EffectiveLanguageContract -> [ScaffoldModule] -> [ScaffoldModule]
stampGeneratedModules languageContract = map (stampGeneratedModule languageContract)

replaceFirstGeneratedBanner :: Text -> [Text] -> Maybe [Text]
replaceFirstGeneratedBanner _ [] = Nothing
replaceFirstGeneratedBanner replacement (line : rest)
  | isGeneratedBannerLine line = Just (replacement : rest)
  | otherwise = (line :) <$> replaceFirstGeneratedBanner replacement rest

nodeOrigin :: Text -> Text -> Loc -> Text
nodeOrigin nodeKind nodeName loc =
  nodeKind <> " " <> nodeName <> case unLoc loc of
    0 -> ""
    line -> " (line " <> tshow' line <> ")"

-- | Conditions that the deterministic emitters cannot lower faithfully. The
-- pre-write scaffold pipeline treats each returned message as a refusal. The
-- list is extended alongside the policy and type lowering milestones.
scaffoldRefusals :: Spec -> [Text]
scaffoldRefusals spec =
  concatMap aggregateRefusals aggregates
    <> concatMap contractRefusals contracts
    <> concatMap publisherRefusals publishers
  where
    aggregates = [aggregate | NAggregate aggregate <- specNodes spec]
    contracts = [contract | NContract contract <- specNodes spec]
    publishers = [publisher | NPublisher publisher <- specNodes spec]
    symbols = aggregateSymbols spec
    aggregateRefusals aggregate =
      [ "AggregateEmpty: aggregate '" <> aggName aggregate <> "' must declare at least one command, event, and transition"
      | null (aggCommands aggregate) || null (aggEvents aggregate) || null (aggTransitions aggregate)
      ]
        <> concatMap (registerRefusals aggregate) (aggRegs aggregate)
        <> concatMap (fieldRefusals aggregate CommandFieldUse) (concatMap cmdFields (aggCommands aggregate))
        <> concatMap (fieldRefusals aggregate EventFieldUse) [field | event <- aggEvents aggregate, EventFields fields <- [evBody event], field <- fields]
    fieldRefusals aggregate useSite field = case inferAggregateFieldType symbols aggregate useSite field of
      Right _ -> []
      Left _ ->
        [ "FieldTypeUnrepresentable: aggregate '"
            <> aggName aggregate
            <> "' field '"
            <> aggregateFieldName field
            <> "' has unsupported explicit type '"
            <> maybe "(inferred)" typeExprCanonicalName (aggregateFieldType field)
            <> "'"
        ]
    registerRefusals aggregate register =
      case resolveAggregateType symbols (regLoc register) RegisterUse (regType register) of
        Left _ ->
          [ "RegTypeUnsupported: aggregate '"
              <> aggName aggregate
              <> "' register '"
              <> regName register
              <> "' has unsupported type '"
              <> typeExprCanonicalName (regType register)
              <> "'"
          ]
        Right resolved -> case resolveRegisterInitial symbols (regLoc register) resolved (regInitial register) of
          Right _ -> []
          Left _ -> [initialRefusal aggregate register resolved]
    initialRefusal aggregate register resolved = case resolved of
      AggregateText -> label "RegTextInitialNotQuoted" "must use a quoted Text initial"
      AggregateNominal nominal
        | EnumRepresentation {} <- resolvedNominalRepresentation nominal ->
            label "RegInitialNotEnumCtor" ("must start at the declaration-owned initial for enum '" <> resolvedNominalName nominal <> "'")
      AggregateMapped {} -> label "MappedRegisterInitialMissing" "requires the mapped declaration's initial symbol"
      _ -> label "RegInitialInvalidLiteral" ("has an invalid " <> aggregateCanonicalName resolved <> " initial")
      where
        label codeName detail = codeName <> ": aggregate '" <> aggName aggregate <> "' register '" <> regName register <> "' " <> detail
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
    | not (T.null digits),
      Just amount <- readMaybe (T.unpack digits) -> case unit of
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
renderGuard = renderExpr

--------------------------------------------------------------------------------
-- Text helpers
--------------------------------------------------------------------------------

nl :: [Text] -> Text
nl = T.intercalate "\n"

-- | Join groups of declarations, blank-line-separated, dropping empties.
sectionsOf :: [[Text]] -> Text
sectionsOf = T.intercalate "\n\n" . filter (not . T.null) . map (T.intercalate "\n\n")

lowerFirst :: Text -> Text
lowerFirst = generatedCase HaskellName.LogicalIdentifier False

-- | Assert the shared category proof at emission time as a belt-and-braces
-- guard for callers that bypass the CLI's normal validate-before-scaffold path.
staticCategory :: Text -> Text -> Text
staticCategory owner value = case sagaCategoryError value of
  Nothing -> value
  Just reason -> error (T.unpack ("keiro-dsl scaffold: illegal " <> owner <> " category " <> tshow value <> " " <> reason))

pascal :: Text -> Text
pascal = generatedCase HaskellName.LogicalIdentifier True

pascalFromKebab :: Text -> Text
pascalFromKebab = generatedCase HaskellName.LogicalWireWord True

generatedCase :: HaskellName.NameSourceKind -> Bool -> Text -> Text
generatedCase source upper name =
  case HaskellName.deriveHaskellName source site of
    Right derived
      | upper -> HaskellName.renderUpperCamelName (HaskellName.upperCamel derived)
      | otherwise -> HaskellName.renderLowerCamelName (HaskellName.lowerCamel derived)
    Left _ -> name
  where
    site =
      HaskellName.NameSite
        { HaskellName.siteKind = HaskellName.GeneratedHelperSite,
          HaskellName.siteLogicalName = name,
          HaskellName.siteOwner = "scaffold-renderer",
          HaskellName.siteLine = 0
        }

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
