-- | The scaffold engine. Given an 'Aggregate' (and a 'Context' naming the
-- service and output module-namespace root), it emits the __symbol-free
-- deterministic layer__ as @-- \@generated@ modules plus a single create-if-absent
-- @Holes.hs@ holding the typed holes a human or coding agent must fill.
--
-- The load-bearing invariant of this module is the __firewall__: no @Generated@
-- module ever contains a keiki symbolic operator (@./=@, @.==@, @.||@, @lit@,
-- @B.slot@, @B.requireGuard@). Those live only in the hand-owned @Holes.hs@. A
-- test ('Generated' text scan) enforces it.
--
-- Scope (EP-1, recorded in the plan's Decision Log): the scaffolder does /not/
-- emit the symbolic transducer body — that is the @buildTransducer@ hole in
-- @Holes.hs@, pinned by the harness. It also does not emit the read-model SQL
-- (the projection @apply@), which is a DB-coupled hole delegated to @codd@/the
-- agent; the @Generated@ Projection module emits only the deterministic
-- @InlineProjection@ wiring and the pure event→status mapping. The decode emitted
-- here is /strict/ (every field required); lenient\/optional decode is EP-4's
-- concern.
module Keiro.Dsl.Scaffold
  ( ScaffoldModule (..),
    ModuleKind (..),
    Context (..),
    Placement (..),
    defaultContext,
    genPrefixFor,
    holePrefixFor,
    scaffoldReplayAudit,
    scaffoldStructural,
    scaffoldStructuralOwners,
    codecComparisonModule,
    codecComparisonBanner,
    bindingSkeletonModules,
    bindingSkeletonOwners,
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
    ResolvedRegister (..),
    ResolvedCtor (..),
    StructuralProjection (..),
    resolveAgg,
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
  )
where

import Data.Char (isAlpha, isAlphaNum, isUpper, ord, toLower, toUpper)
import Data.List (find, groupBy, isSuffixOf, nub, sort, sortOn)
import Data.List.NonEmpty (NonEmpty)
import Data.List.NonEmpty qualified as NE
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe, mapMaybe)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Keiro.Dsl.AggregateType
import Keiro.Dsl.CodecCompare (BranchArm (..), BranchField (..), BranchSchema (..))
import Keiro.Dsl.ExplainBindings (BindingObligation (..), BindingObligationKind (..), bindingObligations)
import Keiro.Dsl.Expression
import Keiro.Dsl.FoldFingerprint (aggregateFoldFingerprint)
import Keiro.Dsl.Grammar
import Keiro.Dsl.NominalType
import Keiro.Dsl.PrettyPrint (renderExpr)
import Keiro.Dsl.ReadModelShape (registryNameFor, subscriptionNameFor)
import Keiro.Dsl.TypeGraph
import Keiro.Dsl.Validate (sagaCategoryError)
import Numeric (showHex)
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

-- | The hand-owned (hole) namespace for a node: @\<root\>.\<Ctx\>.\<Node\>@ —
-- the same for both placement styles (holes always sit beside the domain).
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
              "FieldWitness",
              "fieldWitness",
              "fieldWitnessAgrees",
              "applyEventsEither",
              "defaultValidationOptions",
              "step",
              "validateTransducer",
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
    not (authoritativeScalarModule (modulePath m)),
    (n, line) <- zip [1 ..] (T.lines (moduleText m)),
    breach <- lineBreaches line
  ]

-- Version-2 aggregate expression and transducer modules are the narrow,
-- intentional exception to the generated symbolic-operator firewall: they
-- are precisely the generated authority that constructs Keiki terms. Every
-- other generated module remains subject to the original firewall.
authoritativeScalarModule :: FilePath -> Bool
authoritativeScalarModule path =
  any (`isSuffixOf` path) ["/Expressions.hs", "/Transducer.hs"]

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
    aTransitions :: ![Transition],
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

data ResolvedRegister = ResolvedRegister
  { rrName :: !Name,
    rrType :: !ResolvedAggregateType,
    rrInitial :: !ResolvedRegisterInitial,
    rrLoc :: !Loc
  }
  deriving stock (Eq, Show)

-- | A command or event constructor with its fully-resolved field types.
data ResolvedCtor = ResolvedCtor
  { rcName :: !Text,
    -- | (field name, canonical aggregate type)
    rcFields :: ![(Text, ResolvedAggregateType)],
    -- | EP-2: schema version (1 for commands and unversioned events).
    rcVersion :: !Int,
    -- | EP-2: the source version this event migrates from (the upcaster step).
    rcUpcastFrom :: !(Maybe Int)
  }

defaultWire :: WireSpec
defaultWire = WireSpec {wireKind = "ctorName", wireFields = "camelCase", wireSchemaVersion = 1}

resolveAgg :: Context -> Spec -> Aggregate -> Agg
resolveAgg ctx spec agg =
  Agg
    { aContext = ctx,
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
      aTransitions = aggTransitions agg,
      aWire = fromMaybe defaultWire (aggWire agg),
      aProjection = aggProjection agg,
      aSnapshot = aggSnapshot agg,
      aFoldFingerprint = aggregateFoldFingerprint spec agg,
      aReadModels = [readModel | NReadModel readModel <- specNodes spec],
      aTypeGraph = either (const Nothing) Just (resolveTypeGraph spec),
      aSymbols = symbols,
      aGenPrefix = genPrefixFor ctx nm,
      aHolePrefix = holePrefixFor ctx nm
    }
  where
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
          rcFields = map (\field -> (aggregateFieldName field, orDie (inferAggregateFieldType symbols agg useSite field))) fs,
          rcVersion = 1,
          rcUpcastFrom = Nothing
        }
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

--------------------------------------------------------------------------------
-- Entry point
--------------------------------------------------------------------------------

-- | Emit the context-level private structural stratum. Shape modules contain
-- only generated wire representations. The projection facade contains only
-- schema-derived Keiki field witnesses; neither layer owns consumer behavior.
scaffoldStructural :: Context -> Spec -> [ScaffoldModule]
scaffoldStructural ctx spec = map fst (scaffoldStructuralOwners ctx spec)

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
scaffoldStructuralOwners ctx spec = case resolveTypeGraph spec of
  Left _ -> []
  Right graph ->
    [(shapeModule ctx graph entry, [sdName (fst entry)]) | entry <- structural]
      <> projectionModules
      <> nominalRepresentationOwners ctx spec
      <> nominalProjectionOwners ctx spec
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
      "",
      "import " <> fixtureModule <> " qualified as ConsumerFixtures",
      "import " <> hsModule (sdHaskell declaration) <> " qualified as ConsumerDomain",
      "",
      "compareWithHistorical :: HistoricalCodec " <> domainType <> " -> FilePath -> IO CompareReport",
      "compareWithHistorical historicalCodec goldenDirectory = do",
      "  names <- sort . filter ((== \".json\") . takeExtension) <$> listDirectory goldenDirectory",
      "  files <- filterM doesFileExist [goldenDirectory </> name | name <- names]",
      "  loaded <- traverse (loadGolden historicalCodec) files",
      "  let inputIssues = [issue | Left issue <- loaded]",
      "      entries = [entry | Right entry <- loaded]",
      "      typedCases = NonEmpty.toList (fixtureCases ConsumerFixtures." <> fixtureSymbol <> ")",
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
    domainType = "ConsumerDomain." <> hsType (sdHaskell declaration)
    codecModule = genPrefixFor ctx (aggName owner) <> ".Codec"
    fixtureModule = qualifiedModule (sdFixtures declaration)
    fixtureSymbol = lastSegment (unQualifiedValueName (sdFixtures declaration))

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
            <> map ("import " <>) imports
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
    imports =
      sort . nub $
        [ hsModule (sdHaskell declaration) <> " qualified"
        | obligation <- obligations,
          Just (declaration, _) <- [structuralFor obligation]
        ]
          <> [ structuralShapeModule ctx (sdName declaration) <> " qualified"
             | obligation <- obligations,
               obligationKind obligation == BindingValue,
               Just (declaration, _) <- [structuralFor obligation]
             ]
          <> [ "Keiro.Codec.Structural (FixtureCases, StructuralBinding (..))"
             | any (\obligation -> obligationCategory obligation == "structural" && obligationKind obligation `elem` [BindingValue, FixtureValue]) obligations
             ]
          <> [ hsModule (consumerNominalHaskell binding) <> " qualified"
             | obligation <- obligations,
               Just (_, binding) <- [nominalFor obligation]
             ]
          <> [ nominalRepresentationModule ctx (resolvedNominalName nominal) <> " qualified"
             | obligation <- obligations,
               obligationKind obligation == BindingValue,
               Just (nominal, _) <- [nominalFor obligation],
               EnumRepresentation {} <- [resolvedNominalRepresentation nominal]
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
        Just (nominal, _) -> renderNominalObligation nominal obligation
        Nothing -> ["-- HOLE: declaration disappeared before skeleton rendering"]
      Just (declaration, shape) -> case obligationKind obligation of
        BindingValue -> renderBinding ctx declaration shape obligation
        FixtureValue ->
          [ "-- HOLE: provide deterministic labelled conformance fixtures for " <> sdName declaration,
            obligationSignature obligation,
            obligationSymbol obligation <> " = error " <> tshow ("HOLE: fill " <> sdName declaration <> " fixtures")
          ]
        InitialValue ->
          [ "-- HOLE: provide the initial register value for " <> sdName declaration,
            obligationSignature obligation,
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
    renderNominalObligation nominal obligation = case obligationKind obligation of
      BindingValue ->
        [ "-- HOLE: complete both total directions; the generated codec remains wire authority.",
          obligationSignature obligation,
          obligationSymbol obligation <> " =",
          "  NominalBinding",
          "    { nominalToRepresentation = \\_domainValue -> error " <> tshow ("HOLE: fill " <> resolvedNominalName nominal <> " nominalToRepresentation"),
          "    , nominalFromRepresentation = \\_representationValue -> error " <> tshow ("HOLE: fill " <> resolvedNominalName nominal <> " nominalFromRepresentation"),
          "    }"
        ]
      FixtureValue ->
        [ "-- HOLE: provide deterministic labelled expected-wire fixtures for " <> resolvedNominalName nominal,
          obligationSignature obligation,
          obligationSymbol obligation <> " = error " <> tshow ("HOLE: fill " <> resolvedNominalName nominal <> " fixtures")
        ]
      InitialValue ->
        [ "-- HOLE: provide the initial register value for " <> resolvedNominalName nominal,
          obligationSignature obligation,
          obligationSymbol obligation <> " = error " <> tshow ("HOLE: fill " <> resolvedNominalName nominal <> " initial value")
        ]
    intercalateBlank [] = []
    intercalateBlank (section : rest) = section <> concatMap ("" :) rest

renderBinding :: Context -> StructuralDecl -> ResolvedMappedShape -> BindingObligation -> [Text]
renderBinding ctx declaration shape obligation =
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
    domainModule = hsModule (sdHaskell declaration)
    domainType = domainModule <> "." <> hsType (sdHaskell declaration)
    shapeModuleName = structuralShapeModule ctx (sdName declaration)
    shapeType = shapeModuleName <> "." <> sdName declaration <> "Shape"
    domainCtor constructor = domainModule <> "." <> constructor
    shapeCtor constructor = shapeModuleName <> "." <> constructor
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
          [ "{-# LANGUAGE DeriveGeneric #-}",
            "{-# LANGUAGE LambdaCase #-}",
            generatedBanner,
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

nominalProjectionOwners :: Context -> Spec -> [(ScaffoldModule, [Name])]
nominalProjectionOwners ctx spec = case nominalProjectionTypes spec of
  [] -> []
  nominals ->
    [ ( ScaffoldModule
          { modulePath = T.unpack (T.replace "." "/" (nominalProjectionModule ctx) <> ".hs"),
            moduleText = emitNominalProjections ctx nominals,
            kind = Generated,
            origin = "context " <> specContext spec <> " nominal scalar projection facade"
          },
        []
      )
    ]

nominalProjectionTypes :: Spec -> [ResolvedNominalType]
nominalProjectionTypes spec =
  Map.elems . Map.fromList $
    [ (resolvedNominalName nominal, nominal)
    | aggregate <- [value | NAggregate value <- specNodes spec],
      resolved <- registerTypes aggregate <> commandTypes aggregate,
      AggregateNominal nominal <- [resolved],
      ConsumerNominal {} <- [resolvedNominalOwnership nominal],
      ScalarRepresentation {} <- [resolvedNominalRepresentation nominal]
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

emitNominalProjections :: Context -> [ResolvedNominalType] -> Text
emitNominalProjections ctx nominals =
  nl $
    [ "{-# LANGUAGE DataKinds #-}",
      "{-# LANGUAGE TypeApplications #-}",
      "{-# LANGUAGE TypeFamilies #-}",
      generatedBanner,
      "module " <> moduleName <> " where",
      ""
    ]
      <> map ("import " <>) imports
      <> [""]
      <> [T.intercalate "\n\n" (map emitNominalProjection nominals)]
  where
    moduleName = nominalProjectionModule ctx
    imports =
      sort . nub $
        [ "Keiki.Core (FieldProjection (..), FieldWitness, fieldWitness)",
          "Keiro.Codec.Nominal (nominalToRepresentation)"
        ]
          <> [hsModule (consumerNominalHaskell binding) <> " qualified" | nominal <- nominals, ConsumerNominal binding <- [resolvedNominalOwnership nominal]]
          <> [qualifiedModule (consumerNominalBinding binding) <> " qualified" | nominal <- nominals, ConsumerNominal binding <- [resolvedNominalOwnership nominal]]
          <> ["Data.Text (Text)" | any (hasScalar NominalText) nominals]
          <> ["Data.Time (UTCTime)" | any (hasScalar NominalTime) nominals]
          <> ["Numeric.Natural (Natural)" | any (hasScalar NominalNatural) nominals]
    hasScalar wanted nominal = resolvedNominalRepresentation nominal == ScalarRepresentation wanted
    emitNominalProjection nominal = case resolvedNominalOwnership nominal of
      GeneratedNominal -> ""
      ConsumerNominal binding ->
        nl
          [ "data " <> tagName,
            "",
            "instance FieldProjection " <> tagName <> " where",
            "  type FieldName " <> tagName <> " = " <> tshow name,
            "  type FieldOwner " <> tagName <> " = " <> renderHaskellSource (consumerNominalHaskell binding),
            "  type FieldResult " <> tagName <> " = " <> scalarHaskellType (resolvedNominalRepresentation nominal),
            "  fieldShapeId _ = " <> tshow (unCanonicalTypeId (consumerNominalCanonical binding)),
            "  projectFieldValue _ = nominalToRepresentation " <> unQualifiedValueName (consumerNominalBinding binding),
            "",
            witnessName <> " :: FieldWitness " <> tagName,
            witnessName <> " = fieldWitness @" <> tagName
          ]
        where
          name = resolvedNominalName nominal
          tagName = name <> "NominalProjection"
          witnessName = lowerFirst name <> "Witness"
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
      <> ["" | not (null imports)]
      <> [shapeDeclaration]
  where
    moduleName = structuralShapeModule ctx (sdName declaration)
    shapeType = sdName declaration <> "Shape"
    requirements = shapeRequirements ctx graph shape
    languagePragmas =
      ["{-# LANGUAGE DeriveGeneric #-}"]
        <> ["{-# LANGUAGE DuplicateRecordFields #-}" | shapeHasRecord shape]
    imports =
      sort . nub $
        ["Data.Aeson (Value)" | ReqJson `elem` requirements]
          <> ["Data.Map.Strict (Map)" | ReqMap `elem` requirements]
          <> ["Data.Text (Text)" | ReqText `elem` requirements]
          <> ["Data.Time (UTCTime)" | ReqTime `elem` requirements]
          <> ["GHC.Generics (Generic)"]
          <> ["Numeric.Natural (Natural)" | ReqNatural `elem` requirements]
          <> [m <> " qualified" | ReqModule m <- requirements]
    shapeDeclaration =
      foldMappedShape
        MappedShapeAlgebra
          { onRecord = \constructor _ fields ->
              nl $
                ["data " <> shapeType <> " = " <> constructor]
                  <> recordFields
                    [ (rwfHaskell field, renderShapeType ctx graph (rwfType field))
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
    renderArm arm = rwaCtor arm <> maybe "" ((" !" <>) . renderShapeType ctx graph) (rwaPayload arm)

data ShapeRequirement
  = ReqJson
  | ReqMap
  | ReqText
  | ReqTime
  | ReqNatural
  | ReqModule !Text
  deriving stock (Eq, Ord, Show)

shapeHasRecord :: ResolvedMappedShape -> Bool
shapeHasRecord =
  foldMappedShape
    MappedShapeAlgebra
      { onRecord = \_ _ _ -> True,
        onEnum = const False,
        onUnion = \_ _ -> False
      }

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
          Just (ResolvedStructural declaration _) -> [ReqModule (structuralShapeModule ctx (sdName declaration))]
          Just (ResolvedOpaque declaration) -> [ReqModule (hsModule (odHaskell declaration))]
          Nothing -> []
      }

renderShapeType :: Context -> TypeGraph -> ResolvedTypeExpr -> Text
renderShapeType ctx graph =
  foldTypeExpr
    TypeExprAlgebra
      { onText = "Text",
        onInt = "Int",
        onInteger = "Integer",
        onBool = "Bool",
        onNatural = "Natural",
        onTime = "UTCTime",
        onJson = "Value",
        onOptional = \value -> "(Maybe (" <> value <> "))",
        onList = \value -> "([" <> value <> "])",
        onMap = \value -> "(Map Text (" <> value <> "))",
        onRef = \key -> case Map.lookup key (tgDeclarations graph) of
          Just (ResolvedStructural nested _) ->
            structuralShapeModule ctx (sdName nested) <> "." <> sdName nested <> "Shape"
          Just (ResolvedOpaque opaque) ->
            hsModule (odHaskell opaque) <> "." <> hsType (odHaskell opaque)
          Nothing -> "()"
      }

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
  sortOn spTag . concat $
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
        { spTag = projectionTag (sdName root) pointer,
          spWitness = lowerFirst (projectionTag (sdName root) pointer) <> "Witness",
          spPointer = pointer,
          spOwner = sdHaskell root,
          spResult = result,
          spCanonical = sdCanonical root,
          spBinding = sdBinding root,
          spSelectors = selectors
        }
      where
        pointer = T.concat ["/" <> escapePointer key | key <- keys]

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

projectionTag :: Name -> Text -> Text
projectionTag owner pointer = "StructuralProjection" <> encodeIdentifier (owner <> pointer)

encodeIdentifier :: Text -> Text
encodeIdentifier = T.concatMap (\character -> "C" <> T.pack (showHex (ord character) "") <> "Z")

emitStructuralProjections :: Context -> TypeGraph -> Text
emitStructuralProjections ctx graph =
  nl $
    [ "{-# LANGUAGE DataKinds #-}",
      "{-# LANGUAGE TypeApplications #-}",
      "{-# LANGUAGE TypeFamilies #-}",
      generatedBanner,
      "-- Equality witnesses are emitted for Text, Int, Bool, Natural, and UTCTime.",
      "-- Int, Natural, and UTCTime belong to Keiki's ordered subset.",
      "module " <> moduleName,
      "  ( " <> T.intercalate "\n  , " (map spWitness specs),
      "  ) where",
      "",
      "import Data.Text (Text)",
      "import Data.Time (UTCTime)",
      "import Numeric.Natural (Natural)",
      "import Keiro.Codec.Structural (bindingToShape)",
      "import Keiki.Core (FieldProjection (..), FieldWitness, fieldWitness)"
    ]
      <> map ("import " <>) imports
      <> concatMap renderProjection specs
  where
    moduleName = structuralProjectionModule ctx
    specs = map (resolveProjectionModules ctx) (projectionSpecs graph)
    imports =
      sort . nub $
        [hsModule (spOwner spec) <> " qualified" | spec <- specs]
          <> [qualifiedModule (spBinding spec) <> " qualified" | spec <- specs]
          <> [shapeModuleName <> " qualified" | spec <- specs, (shapeModuleName, _) <- spSelectors spec]
    renderProjection spec =
      [ "",
        "data " <> spTag spec,
        "",
        "instance FieldProjection " <> spTag spec <> " where",
        "  type FieldName " <> spTag spec <> " = " <> tshow (spPointer spec),
        "  type FieldOwner " <> spTag spec <> " = " <> renderHaskellSource (spOwner spec),
        "  type FieldResult " <> spTag spec <> " = " <> spResult spec,
        "  fieldShapeId _ = " <> tshow (unCanonicalTypeId (spCanonical spec)),
        "  projectFieldValue _ owner = " <> renderGetter spec,
        "",
        spWitness spec <> " :: FieldWitness " <> spTag spec,
        spWitness spec <> " = fieldWitness @" <> spTag spec
      ]
    renderGetter spec =
      foldl
        (\value (shapeModuleName, selector) -> shapeModuleName <> "." <> selector <> " (" <> value <> ")")
        ("bindingToShape " <> unQualifiedValueName (spBinding spec) <> " owner")
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

qualifiedModule :: QualifiedValueName -> Text
qualifiedModule = fst . splitQualified . unQualifiedValueName

renderHaskellSource :: HaskellSource -> Text
renderHaskellSource source = hsModule source <> "." <> hsType source

splitQualified :: Text -> (Text, Text)
splitQualified value =
  let (prefix, name) = T.breakOnEnd "." value
   in (T.dropEnd 1 prefix, name)

lastSegment :: Text -> Text
lastSegment = snd . T.breakOnEnd "."

-- | Emit all modules for one aggregate. The 'Spec' is needed for the shared
-- id\/enum declarations.
scaffoldAggregate :: Context -> Spec -> Aggregate -> [ScaffoldModule]
scaffoldAggregate ctx spec agg =
  [ genModule a "Domain" (emitDomain a),
    genModule a "Codec" (emitCodec a)
  ]
    ++ ( if hasVersion2Ownership a
           then
             [ genModule a "Expressions" (emitExpressions a),
               genModule a "Transducer" (emitGeneratedTransducer a)
             ]
           else []
       )
    ++ [ genModule a "EventStream" (emitEventStream a),
         genModule a "Projection" (emitProjection a),
         holeModule a (emitHoles a)
       ]
  where
    a = resolveAgg ctx spec agg

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
    contextGeneratedPrefix context = case placement context of
      GeneratedPrefix -> rootPrefix context <> "Generated." <> ctxPascalOf context
      CollocatedLeaf -> rootPrefix context <> ctxPascalOf context <> ".Generated"
    emitReplayAudit =
      nl $
        [ "{-# LANGUAGE GADTs #-}",
          generatedBanner,
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
scaffoldContract ctx c =
  [ ScaffoldModule
      { modulePath = T.unpack (T.replace "." "/" genPrefix <> "/Contract.hs"),
        moduleText = emitContractGen genPrefix c,
        kind = Generated,
        origin = nodeOrigin "contract" (ctrName c) (ctrLoc c)
      }
  ]
  where
    genPrefix = genPrefixFor ctx (pascal (ctrName c))

emitContractGen :: Text -> ContractNode -> Text
emitContractGen genPrefix c =
  nl $
    [ "{-# LANGUAGE DuplicateRecordFields #-}",
      "{-# LANGUAGE OverloadedRecordDot #-}",
      "{-# OPTIONS_GHC -Wno-unused-top-binds #-}",
      generatedBanner,
      "module " <> genPrefix <> ".Contract",
      "  ( " <> payloadTy <> " (..)",
      nl ["  , " <> ceName e <> "Data (..)" | e <- ctrEvents c],
      "  , messageTypeOf",
      "  , encode" <> payloadTy,
      "  , parse" <> payloadTy,
      "  ) where",
      "",
      "import Data.Aeson (Value, object, withObject, (.:), (.=))",
      "import Data.Aeson.Types (Parser, parseEither)",
      "import Data.Text (Text)",
      "import qualified Data.Text as T",
      "",
      "-- topic constants"
    ]
      ++ [lowerFirst alias <> "Topic :: Text\n" <> lowerFirst alias <> "Topic = " <> tshow t | (alias, t) <- ctrTopics c]
      ++ [ "",
           "-- the closed payload set (discriminated by " <> tshow (ctrDiscriminator c) <> ")"
         ]
      ++ [emitPayloadAdt payloadTy (ctrEvents c)]
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
           "      kind <- o .: " <> tshow (ctrDiscriminator c) <> " :: Parser Text",
           "      case kind of"
         ]
      ++ concatMap decodeArm (ctrEvents c)
      ++ [ "        _ -> fail \"unknown message type\"",
           "",
           "mapLeftText :: Either String b -> Either Text b",
           "mapLeftText = either (Left . T.pack) Right"
         ]
  where
    payloadTy = pascal (ctrName c) <> "Payload"
    encodeArm e =
      [ "  " <> ceName e <> " payload ->",
        "    object"
      ]
        ++ [lead i kv | (i, kv) <- zip [(0 :: Int) ..] ((tshow (ctrDiscriminator c) <> " .= (" <> tshow (ceName e) <> " :: Text)") : [tshow (cfName f) <> " .= payload." <> cfName f | f <- ceFields e])]
        ++ ["      ]"]
    lead 0 kv = "      [ " <> kv
    lead _ kv = "      , " <> kv
    decodeArm e =
      [ "        " <> tshow (ceName e) <> " ->",
        "          " <> ceName e <> " <$> (" <> ceName e <> "Data" <> fieldApps (ceFields e) <> ")"
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

-- | Emit the inbox node's deterministic disposition wiring compiled against the
-- LIVE @Keiro.Inbox.Types@: the dedupe policy (a real 'InboxDedupePolicy') and a
-- disposition function over the real @InboxResult@ (Processed\/Duplicate\/
-- InProgress\/PreviouslyFailed). This pins the dangerous inversions
-- (duplicate ⇒ ackOk, previouslyFailed ⇒ deadLetter) as compiled code over the
-- runtime types. The handler-level decode\/dedupe\/store failures are noted but not
-- part of @InboxResult@. Firewall holds (no keiki symbolic operator).
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
  nl
    [ "{-# OPTIONS_GHC -Wno-unused-top-binds #-}",
      generatedBanner,
      "module " <> genPrefix <> ".Inbox",
      "  ( InboxAck (..)",
      "  , inboxDedupePolicy",
      "  , inboxPersistence",
      "  , inboxDisposition",
      "  ) where",
      "",
      "import Keiro.Inbox.Types (InboxDedupePolicy (..), InboxPersistence (..), InboxResult (..))",
      "",
      "-- The dedupe policy (hole-kind 4), lowered to the live InboxDedupePolicy.",
      "inboxDedupePolicy :: InboxDedupePolicy",
      "inboxDedupePolicy = " <> inkDedupePolicy i,
      "",
      "{- | Success-path envelope retention passed to runInboxTransactionWith.",
      "Failures always retain their full operator-facing dead-letter envelope.",
      "Dedupe-only success rows decode with an empty payload.",
      "-}",
      "inboxPersistence :: InboxPersistence",
      "inboxPersistence = " <> persistenceCtor (inkPersist i),
      "",
      "-- The service's ack decision for each inbox classification.",
      "data InboxAck = InboxAckOk | InboxRetry | InboxDeadLetter",
      "  deriving stock (Eq, Show)",
      "",
      "-- The disposition table (hole-kind 2) over the LIVE Keiro.Inbox.Types.InboxResult.",
      "-- duplicate => ackOk and previouslyFailed => deadLetter are the dangerous",
      "-- inversions the spec states explicitly.",
      "inboxDisposition :: InboxResult a -> InboxAck",
      "inboxDisposition r = case r of",
      "  InboxProcessed _ -> " <> ackFor "processed",
      "  InboxDuplicate -> " <> ackFor "duplicate",
      "  InboxInProgress -> " <> ackFor "inProgress",
      "  InboxPreviouslyFailed _ -> " <> ackFor "previouslyFailed",
      "",
      "-- handler-level failures (not InboxResult): decodeFailed => "
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
    [ "{-# OPTIONS_GHC -Wno-unused-top-binds #-}",
      generatedBanner,
      "module " <> genPrefix <> ".Publisher",
      "  ( publisherOrdering",
      "  , publisherBackoff",
      "  , publisherMaxAttempts",
      "  ) where",
      "",
      "import Keiro.Outbox.Types (BackoffSchedule (..), ExponentialBackoffOptions (..), OrderingPolicy (..))",
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
  [ ScaffoldModule
      { modulePath = T.unpack (T.replace "." "/" genPrefix <> "/Queue.hs"),
        moduleText = emitWorkqueueGen genPrefix w,
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

emitWorkqueueGen :: Text -> WorkqueueNode -> Text
emitWorkqueueGen genPrefix w =
  nl $
    [ "{-# LANGUAGE OverloadedRecordDot #-}",
      "{-# OPTIONS_GHC -Wno-unused-top-binds #-}",
      generatedBanner,
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
           "  { " <> T.intercalate "\n  , " [wqfName f <> " :: !" <> hsType (wqfType f) | f <- wqPayload w],
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

-- | Emit the versioned PGMQ envelope adapter.  The payload record remains
-- symbol-free and dependency-light in Queue.hs; this runtime-facing module is
-- the opt-in assembly point applications import into their Job values.
emitQueueCodec :: Text -> WorkqueueNode -> Text
emitQueueCodec genPrefix w =
  nl
    [ generatedBanner,
      "{- | Versioned job payload envelope: @{\\\"v\\\",\\\"t\\\",\\\"data\\\"}@.",
      "",
      "Deploy workers before producers when raising its schema version. Do not",
      "adopt this codec on a non-empty bare-payload queue without draining it",
      "(or supplying a transitional codec), or in-flight messages will",
      "dead-letter. This is telemetry-neutral:",
      "docs/adr/0001-keiro-pgmq-job-processing-telemetry-contract.md owns",
      "spans and acknowledgement vocabulary.",
      "-}",
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
      "  ( retryPolicy, jobOutcomeFor",
      "  , jobOrdering, jobTuningFor, queueProvision",
      "  ) where",
      "",
      "import Data.Text (Text)",
      "import Keiro.PGMQ.Job (JobOrdering (..), JobOutcome (..), JobTuning, PartitionSpec (..), QueueProvision, RetryDelay (..), RetryPolicy (..), partitionedProvision, standardProvision, unloggedProvision, withFifoIndexProvision, withOrdering)",
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
      "jobOutcomeFor :: Text -> JobOutcome",
      "jobOutcomeFor o = case o of"
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

emitReadModelGen :: Context -> Text -> Text -> Text -> Text -> ReadModelNode -> Text
emitReadModelGen ctx readModelModule tableModule readModelHolePrefix stem readModel =
  nl $
    [ "{-# LANGUAGE OverloadedRecordDot #-}",
      generatedBanner,
      "module " <> readModelModule <> ".ReadModel",
      "  ( " <> T.intercalate "\n  , " exports,
      "  ) where",
      "",
      "import Data.Functor (void)",
      "import Effectful (Eff, (:>))",
      "import " <> tableModule <> " (" <> qualifiedName <> ")",
      "import " <> readModelHolePrefix <> ".ReadModelHoles (" <> T.intercalate ", " holeImports <> ")"
    ]
      ++ asyncImports
      ++ [ "import Keiro.ReadModel (ConsistencyMode (..), ReadModel (..), ReadModelMetadata, StrongScope (..), registerReadModel)",
           "import Keiro.ReadModel.Rebuild qualified as Rebuild",
           "import Kiroku.Store.Effect (Store)",
           "import Kiroku.Store.Types (" <> kirokuTypes <> ")",
           "",
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
           "    }",
           "",
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
      [ readModelName,
        qualifiedName,
        registerName,
        startName,
        finishName,
        abandonName
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
      ++ ["import Kiroku.Store.Types (RecordedEvent(..))" | rmFeed readModel == RmSubscription]
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
    exports = [queryInputType, queryResultType, queryName] ++ [applyName | rmFeed readModel == RmSubscription]
    applyStub = case rmFeed readModel of
      RmInline -> []
      RmSubscription ->
        [ "",
          "-- HOLE: apply one recorded event; runtime deduplication makes redelivery safe.",
          applyName <> " :: RecordedEvent -> Tx.Transaction ()",
          applyName <> " _recorded = error " <> tshow ("HOLE: fill " <> rmName readModel <> " async apply")
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
    "    { poisonPolicy = " <> poisonExpr,
    "    , rejectedCommandPolicy = " <> rejectedExpr rejected,
    "    , transientRetryDelay = RetryDelay 5 -- matches defaultWorkerOptions; runtime tuning",
    "    , metrics = Nothing                  -- runtime configuration; install at call site",
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
        moduleText = emitProcessGen ctxPascal genPrefix holePrefix p,
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
    ctxPascal = pascalFromKebab (contextName ctx)
    genPrefix = genPrefixFor ctx (procId p)
    holePrefix = holePrefixFor ctx (procId p)

emitProcessGen :: Text -> Text -> Text -> ProcessNode -> Text
emitProcessGen _ctxPascal genPrefix _holePrefix p =
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
           lo <> "Category :: Stream.StreamCategory a",
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
      "--   build target streams with entityStream " <> lowerFirst (procTarget p) <> "Category. Never concatenate raw stream names.",
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
    [ "{-# LANGUAGE DataKinds #-}"
    ]
      ++ ["{-# LANGUAGE DeriveAnyClass #-}" | hasSnapshot a]
      ++ [ "{-# LANGUAGE DuplicateRecordFields #-}",
           "{-# LANGUAGE TemplateHaskell #-}",
           "{-# LANGUAGE TypeApplications #-}",
           "{-# OPTIONS_GHC -Wno-unused-top-binds #-}",
           generatedBanner,
           "module " <> aGenPrefix a <> ".Domain where",
           ""
         ]
      ++ ["import Data.Aeson (FromJSON, ToJSON)" | hasSnapshot a]
      ++ [ "import Data.Proxy (Proxy (..))",
           "import Data.Text (Text)",
           "import GHC.Generics (Generic)",
           "import Keiki.Core (RegFile (..))"
         ]
      ++ ["import Keiki.Shape (CanonicalStateShape, CanonicalTypeName)" | hasSnapshot a]
      ++ map ("import " <>) (domainConsumerImports a)
      ++ [ "import Keiki.Generics.TH (deriveAggregateCtorsAll, deriveWireCtorsAll)",
           "",
           sectionsOf
             [ map (emitId a) [declaration | declaration <- aIds a, idBinding declaration == Nothing],
               map (emitEnum a) [declaration | declaration <- aEnums a, enumBinding declaration == Nothing],
               [emitVertex a],
               map (emitRecord a) (aCommands a),
               [emitSum (aName a <> "Command") (aCommands a)],
               map (emitRecord a) (aEvents a),
               [emitSum (aName a <> "Event") (aEvents a)],
               [emitRegsType a, emitInitialRegs a],
               [ "$(deriveAggregateCtorsAll ''" <> aName a <> "Command ''" <> aName a <> "Regs)",
                 "",
                 "$(deriveWireCtorsAll ''" <> aName a <> "Event)"
               ]
             ]
         ]

hasSnapshot :: Agg -> Bool
hasSnapshot = maybe False (const True) . aSnapshot

emitId :: Agg -> IdDecl -> Text
emitId a d =
  nl $
    [ "newtype " <> idName d <> " = " <> idName d <> " Text",
      "  deriving stock (Generic, Eq, Ord, Show)"
    ]
      ++ ["  deriving anyclass (ToJSON, FromJSON)" | hasSnapshot a]
      ++ ["instance CanonicalTypeName " <> idName d | hasSnapshot a]
      ++ [ "",
           lowerFirst (idName d) <> "Text :: " <> idName d <> " -> Text",
           lowerFirst (idName d) <> "Text (" <> idName d <> " t) = t"
         ]

emitEnum :: Agg -> EnumDecl -> Text
emitEnum a d =
  nl $
    [ "data " <> enumName d <> " = " <> T.intercalate " | " (map fst (enumCtors d)),
      "  deriving stock (Generic, Eq, Ord, Show, Enum, Bounded)"
    ]
      ++ ["  deriving anyclass (ToJSON, FromJSON)" | hasSnapshot a]
      ++ ["instance CanonicalTypeName " <> enumName d | hasSnapshot a]
      ++ [ "",
           lowerFirst (enumName d) <> "Text :: " <> enumName d <> " -> Text",
           lowerFirst (enumName d) <> "Text = \\case",
           nl ["  " <> c <> " -> " <> tshow w | (c, w) <- enumCtors d]
         ]

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

emitRecord :: Agg -> ResolvedCtor -> Text
emitRecord a rc =
  nl $
    [ "data " <> rcName rc <> "Data = " <> rcName rc <> "Data"
    ]
      ++ recordFields [(name, renderDomainType a fieldType) | (name, fieldType) <- rcFields rc]
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
        ( "data " <> tyName <> " = " <> arm c,
          ["  | " <> arm c2 | c2 <- cs]
        )

emitRegsType :: Agg -> Text
emitRegsType a =
  nl $
    ["type " <> aName a <> "Regs ="]
      ++ regListLines a (aRegs a)

regListLines :: Agg -> [ResolvedRegister] -> [Text]
regListLines _ [] = ["  '[]"]
regListLines a rs =
  [ lead i <> "'(" <> tshow (rrName r) <> ", " <> renderDomainType a (rrType r) <> ")"
  | (i, r) <- zip [(0 :: Int) ..] rs
  ]
    ++ ["   ]"]
  where
    lead 0 = "  '[ "
    lead _ = "   , "

emitInitialRegs :: Agg -> Text
emitInitialRegs a =
  nl $
    [ "initial" <> aName a <> "Regs :: RegFile " <> aName a <> "Regs",
      "initial" <> aName a <> "Regs ="
    ]
      ++ chain (aRegs a)
  where
    chain [] = ["  RNil"]
    chain rs =
      [ "  RCons (Proxy @" <> tshow (rrName r) <> ") " <> regInitialValue r <> " $"
      | r <- init rs
      ]
        ++ ["  RCons (Proxy @" <> tshow (rrName lastR) <> ") " <> regInitialValue lastR <> " RNil"]
      where
        lastR = last rs

-- | The Haskell initial value for a register, by the category of its type.
regInitialValue :: ResolvedRegister -> Text
regInitialValue = renderRegisterInitial . rrInitial

domainConsumerImports :: Agg -> [Text]
domainConsumerImports a =
  sort . nub $
    Set.toList (Set.unions [aggregateImports (aSymbols a) resolved | resolved <- aggregateTypes])
      <> [ qualifiedModule initialValue <> " qualified"
         | declaration <- mappedUses a,
           initialValue <- maybeToListText (mappedInitial declaration)
         ]
      <> [ qualifiedModule initialValue <> " qualified"
         | resolvedType <- aggregateTypes,
           AggregateNominal nominal <- [resolvedType],
           ConsumerNominal binding <- [resolvedNominalOwnership nominal],
           initialValue <- maybeToListText (consumerNominalInitial binding)
         ]
  where
    aggregateTypes = map snd (concatMap rcFields (aCommands a <> aEvents a)) <> map rrType (aRegs a)

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

renderDomainType :: Agg -> ResolvedAggregateType -> Text
renderDomainType a = aggregateHaskellType (aSymbols a)

maybeToListText :: Maybe value -> [value]
maybeToListText = maybe [] pure

--------------------------------------------------------------------------------
-- Codec module
--------------------------------------------------------------------------------

emitCodec :: Agg -> Text
emitCodec a =
  nl $
    ["{-# LANGUAGE DataKinds #-}" | hasConsumerNominalIdCodec a]
      ++ ["{-# LANGUAGE TypeApplications #-}" | hasConsumerNominalIdCodec a]
      ++ ["{-# LANGUAGE LambdaCase #-}" | hasConsumerNominalCodec a]
      ++ [ "{-# LANGUAGE OverloadedRecordDot #-}",
           generatedBanner,
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
      ++ ( if hasMappedCodec a
             then
               [ "import Control.Monad (unless)",
                 "import Data.Aeson (Value (..), object, parseJSON, toJSON, withObject, withText, (.:), (.=))",
                 "import Data.Aeson.Key qualified as Key",
                 "import Data.Aeson.KeyMap qualified as KeyMap"
               ]
             else ["import Data.Aeson (Value, object, withObject, (.:), (.=))"]
         )
      ++ [ "import Data.Aeson.Types (Parser, parseEither)",
           "import Data.List.NonEmpty (NonEmpty (..))"
         ]
      ++ ( if hasMappedCodec a
             then ["import Data.Map.Strict (Map)", "import Data.Map.Strict qualified as Map"]
             else []
         )
      ++ [ "import Data.Text (Text)",
           "import qualified Data.Text as T"
         ]
      ++ ["import Data.KindID qualified as KindID" | hasConsumerNominalIdCodec a]
      ++ ["import Keiro.Codec.Nominal (nominalFromRepresentation, nominalToRepresentation)" | hasConsumerNominalCodec a]
      ++ ["import Keiro.Codec.Structural (bindingFromShape, bindingToShape)" | hasMappedCodec a]
      ++ [ "import Keiro.Codec (Codec (..), EventType (..))",
           upcasterImport a
         ]
      ++ [nl (map ("import " <>) (codecMappedImports a)) | hasMappedCodec a]
      ++ [nl (map ("import " <>) (codecNominalImports a)) | hasConsumerNominalCodec a]
      ++ [ "",
           emitEnumParsers a,
           emitConsumerNominalParsers a
         ]
      ++ [emitMappedCodecs a | hasMappedCodec a]
      ++ [ "",
           emitCodecValue a,
           "",
           emitEncode a,
           "",
           emitDecode a,
           "",
           "mapLeftText :: Either String b -> Either Text b",
           "mapLeftText = either (Left . T.pack) Right"
         ]
      ++ ( if hasMappedCodec a
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
    mappedExports (ResolvedStructural declaration _) =
      [ "    encode" <> sdName declaration <> "Mapped,",
        "    decode" <> sdName declaration <> "Mapped,"
      ]
    mappedExports ResolvedOpaque {} = []

hasMappedCodec :: Agg -> Bool
hasMappedCodec = not . null . codecMappedDeclarations

hasConsumerNominalCodec :: Agg -> Bool
hasConsumerNominalCodec = not . null . codecConsumerNominals

hasConsumerNominalIdCodec :: Agg -> Bool
hasConsumerNominalIdCodec aggregate =
  any
    (\nominal -> case resolvedNominalRepresentation nominal of IdRepresentation {} -> True; _ -> False)
    (codecConsumerNominals aggregate)

emitEnumParsers :: Agg -> Text
emitEnumParsers a = sectionsOf [[emitEnumParser declaration | declaration <- aEnums a, enumBinding declaration == Nothing]]

emitEnumParser :: EnumDecl -> Text
emitEnumParser d =
  nl $
    [ "parse" <> enumName d <> " :: Text -> Parser " <> enumName d,
      "parse" <> enumName d <> " = \\case"
    ]
      ++ ["  " <> tshow w <> " -> pure " <> c | (c, w) <- enumCtors d]
      ++ ["  _ -> fail " <> tshow ("unknown " <> enumName d)]

emitConsumerNominalParsers :: Agg -> Text
emitConsumerNominalParsers aggregate = sectionsOf [map emitParser (codecConsumerNominals aggregate)]
  where
    emitParser nominal = case (resolvedNominalRepresentation nominal, resolvedNominalOwnership nominal) of
      (IdRepresentation prefix, ConsumerNominal binding) ->
        nl
          [ parserName nominal <> " :: Text -> Parser " <> renderHaskellSource (consumerNominalHaskell binding),
            parserName nominal <> " input = case KindID.parseText @" <> tshow prefix <> " input of",
            "  Left reason -> fail (show reason)",
            "  Right representation -> pure (nominalFromRepresentation " <> unQualifiedValueName (consumerNominalBinding binding) <> " representation)"
          ]
      (EnumRepresentation constructors, ConsumerNominal binding) ->
        nl $
          [ parserName nominal <> " :: Text -> Parser " <> renderHaskellSource (consumerNominalHaskell binding),
            parserName nominal <> " = \\case"
          ]
            <> [ "  "
                   <> tshow wire
                   <> " -> pure (nominalFromRepresentation "
                   <> unQualifiedValueName (consumerNominalBinding binding)
                   <> " "
                   <> nominalRepresentationModule (aContext aggregate) (resolvedNominalName nominal)
                   <> "."
                   <> constructor
                   <> ")"
               | (constructor, wire) <- NE.toList constructors
               ]
            <> ["  _ -> fail " <> tshow ("unknown " <> resolvedNominalName nominal <> " wire value")]
      _ -> ""
    parserName nominal = "parse" <> resolvedNominalName nominal <> "Nominal"

emitCodecValue :: Agg -> Text
emitCodecValue a =
  nl $
    [ lowerFirst (aName a) <> "Codec :: Codec " <> aName a <> "Event",
      lowerFirst (aName a) <> "Codec =",
      "  Codec",
      "    { eventTypes = " <> eventTypesExpr,
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
  where
    eventTypesExpr = case map rcName (aEvents a) of
      [] -> "error \"no events\""
      (e : es) -> "EventType " <> tshow e <> " :| [" <> T.intercalate ", " (map (("EventType " <>) . tshow) es) <> "]"

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

emitEncode :: Agg -> Text
emitEncode a =
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
    encodeField (n, ty) =
      tshow n
        <> " .= "
        <> encodeFieldValue n ty
    encodeFieldValue name ty = case ty of
      AggregateNominal nominal -> encodeNominalValue nominal ("payload." <> name)
      _ -> case fieldCat a ty of
        MappedStructuralCat declaration _ -> "encode" <> sdName declaration <> "Mapped payload." <> name
        MappedOpaqueCat {} -> "toJSON payload." <> name
        _ -> "payload." <> name
    encodeNominalValue nominal value = case resolvedNominalOwnership nominal of
      GeneratedNominal -> case resolvedNominalRepresentation nominal of
        IdRepresentation {} -> lowerFirst (resolvedNominalName nominal) <> "Text " <> value
        EnumRepresentation {} -> lowerFirst (resolvedNominalName nominal) <> "Text " <> value
        ScalarRepresentation {} -> value
      ConsumerNominal binding -> case resolvedNominalRepresentation nominal of
        IdRepresentation {} -> "KindID.toText (nominalToRepresentation " <> bindingName binding <> " " <> value <> ")"
        EnumRepresentation {} ->
          nominalRepresentationModule (aContext a) (resolvedNominalName nominal)
            <> "."
            <> lowerFirst (resolvedNominalName nominal)
            <> "RepresentationText (nominalToRepresentation "
            <> bindingName binding
            <> " "
            <> value
            <> ")"
        ScalarRepresentation {} -> "nominalToRepresentation " <> bindingName binding <> " " <> value
    bindingName = unQualifiedValueName . consumerNominalBinding

emitDecode :: Agg -> Text
emitDecode a =
  nl $
    [ "parse" <> aName a <> "Event :: EventType -> Value -> Either Text " <> aName a <> "Event",
      "parse" <> aName a <> "Event (EventType tag) = mapLeftText . parseEither (withObject " <> tshow (aName a <> "Event") <> " go)",
      "  where",
      "    go o = do",
      "      case tag of"
    ]
      ++ concatMap decodeArm (aEvents a)
      ++ ["        _ -> fail \"unknown event type\""]
  where
    decodeArm e =
      [ "        " <> tshow (rcName e) <> " ->",
        "          " <> rcName e <> " <$> (" <> rcName e <> "Data" <> fieldApps (rcFields e) <> ")"
      ]
    fieldApps [] = ""
    fieldApps fs = " <$> " <> T.intercalate " <*> " (map decodeField fs)
    -- The first field uses <$> (handled above), the rest <*>. We instead build
    -- a uniform list and join; for an empty record there are no fields.
    decodeField (n, ty) = case ty of
      AggregateNominal nominal -> decodeNominalField n nominal
      _ -> case fieldCat a ty of
        MappedStructuralCat declaration _ -> "(o .: " <> tshow n <> " >>= parse" <> sdName declaration <> "Mapped)"
        MappedOpaqueCat {} -> "o .: " <> tshow n
        _ -> "o .: " <> tshow n
    decodeNominalField name nominal = case resolvedNominalOwnership nominal of
      GeneratedNominal -> case resolvedNominalRepresentation nominal of
        IdRepresentation {} -> "(" <> resolvedNominalName nominal <> " <$> o .: " <> tshow name <> ")"
        EnumRepresentation {} -> "(o .: " <> tshow name <> " >>= parse" <> resolvedNominalName nominal <> ")"
        ScalarRepresentation {} -> "o .: " <> tshow name
      ConsumerNominal binding -> case resolvedNominalRepresentation nominal of
        IdRepresentation {} -> "(o .: " <> tshow name <> " >>= parse" <> resolvedNominalName nominal <> "Nominal)"
        EnumRepresentation {} -> "(o .: " <> tshow name <> " >>= parse" <> resolvedNominalName nominal <> "Nominal)"
        ScalarRepresentation {} -> "(nominalFromRepresentation " <> unQualifiedValueName (consumerNominalBinding binding) <> " <$> o .: " <> tshow name <> ")"

codecConsumerNominals :: Agg -> [ResolvedNominalType]
codecConsumerNominals aggregate =
  Map.elems . Map.fromList $
    [ (resolvedNominalName nominal, nominal)
    | event <- aEvents aggregate,
      (_, AggregateNominal nominal) <- rcFields event,
      ConsumerNominal {} <- [resolvedNominalOwnership nominal]
    ]

codecNominalImports :: Agg -> [Text]
codecNominalImports aggregate =
  sort . nub $
    concat
      [ [ hsModule (consumerNominalHaskell binding) <> " qualified",
          qualifiedModule (consumerNominalBinding binding) <> " qualified"
        ]
          <> [ nominalRepresentationModule (aContext aggregate) (resolvedNominalName nominal) <> " qualified"
             | EnumRepresentation {} <- [resolvedNominalRepresentation nominal]
             ]
      | nominal <- codecConsumerNominals aggregate,
        ConsumerNominal binding <- [resolvedNominalOwnership nominal]
      ]

codecMappedImports :: Agg -> [Text]
codecMappedImports a = case aTypeGraph a of
  Nothing -> []
  Just graph ->
    sort . nub $
      [ structuralShapeModule (aContext a) (sdName declaration) <> " qualified"
      | ResolvedStructural declaration _ <- codecMappedDeclarations a
      ]
        <> [ hsModule (sdHaskell declaration) <> " qualified"
           | ResolvedStructural declaration _ <- codecMappedDeclarations a
           ]
        <> [ qualifiedModule (sdBinding declaration) <> " qualified"
           | ResolvedStructural declaration _ <- codecMappedDeclarations a
           ]
        <> [ hsModule (odHaskell declaration) <> " qualified"
           | ResolvedOpaque declaration <- codecMappedDeclarations a
           ]
        <> [ hsModule (odHaskell declaration) <> " qualified"
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

emitMappedCodecs :: Agg -> Text
emitMappedCodecs a = case aTypeGraph a of
  Nothing -> ""
  Just graph ->
    T.intercalate
      "\n\n"
      [ emitStructuralCodec a graph declaration shape
      | ResolvedStructural declaration shape <- codecMappedDeclarations a
      ]

emitStructuralCodec :: Agg -> TypeGraph -> StructuralDecl -> ResolvedMappedShape -> Text
emitStructuralCodec a graph declaration shape =
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
      emitShapeEncoder a graph declaration shape,
      "",
      "parse" <> name <> "Shape :: Value -> Parser " <> shapeType,
      emitShapeDecoder a graph declaration shape
    ]
  where
    name = sdName declaration
    consumerType = renderHaskellSource (sdHaskell declaration)
    shapeType = structuralShapeModule (aContext a) name <> "." <> name <> "Shape"
    binding = unQualifiedValueName (sdBinding declaration)

emitShapeEncoder :: Agg -> TypeGraph -> StructuralDecl -> ResolvedMappedShape -> Text
emitShapeEncoder a graph declaration =
  foldMappedShape
    MappedShapeAlgebra
      { onRecord = \_ _ fields ->
          nl $
            ["encode" <> name <> "Shape shape =", "  object"]
              <> objectEntries
                [ tshow (rwfKey field)
                    <> " .= "
                    <> encodeShapeExpr a graph (rwfType field) (shapeModuleName <> "." <> rwfHaskell field <> " shape")
                | field <- fields
                ],
        onEnum = \entries ->
          nl $
            ["encode" <> name <> "Shape = \\case"]
              <> ["  " <> shapeModuleName <> "." <> weCtor entry <> " -> String " <> tshow (weTag entry) | entry <- entries],
        onUnion = \encoding arms ->
          nl $
            ["encode" <> name <> "Shape = \\case"]
              <> concatMap (unionEncodeArm encoding) arms
      }
  where
    name = sdName declaration
    shapeModuleName = structuralShapeModule (aContext a) name
    unionEncodeArm encoding arm =
      [ "  " <> shapeModuleName <> "." <> rwaCtor arm <> payloadPattern <> " ->",
        "    object"
      ]
        <> objectEntries
          ( [tshow (ueTagField encoding) <> " .= (" <> tshow (rwaTag arm) <> " :: Text)"]
              <> [ tshow (ueContentsField encoding) <> " .= " <> encodeShapeExpr a graph payload "payload"
                 | payload <- maybeToListText (rwaPayload arm)
                 ]
          )
      where
        payloadPattern = maybe "" (const " payload") (rwaPayload arm)

emitShapeDecoder :: Agg -> TypeGraph -> StructuralDecl -> ResolvedMappedShape -> Text
emitShapeDecoder a graph declaration =
  foldMappedShape
    MappedShapeAlgebra
      { onRecord = \constructor unknownFields fields ->
          nl $
            [ "parse" <> name <> "Shape = withObject " <> tshow (name <> "Shape") <> " $ \\objectValue -> do"
            ]
              <> rejectLine "  " unknownFields (map rwfKey fields) "objectValue"
              <> [ "  " <> shapeModuleName <> "." <> constructor,
                   "    <$> " <> T.intercalate "\n    <*> " (map (decodeRecordField a graph) fields)
                 ],
        onEnum = \entries ->
          nl $
            [ "parse" <> name <> "Shape = withText " <> tshow (name <> "Shape") <> " $ \\tag -> case tag of"
            ]
              <> ["  " <> tshow (weTag entry) <> " -> pure " <> shapeModuleName <> "." <> weCtor entry | entry <- entries]
              <> ["  _ -> fail " <> tshow ("unknown " <> name <> " wire value")],
        onUnion = \encoding arms ->
          nl $
            [ "parse" <> name <> "Shape = withObject " <> tshow (name <> "Shape") <> " $ \\objectValue -> do",
              "  tag <- objectValue .: " <> tshow (ueTagField encoding) <> " :: Parser Text",
              "  case tag of"
            ]
              <> concatMap (unionDecodeArm encoding) arms
              <> ["    _ -> fail " <> tshow ("unknown " <> name <> " union tag")]
      }
  where
    name = sdName declaration
    shapeModuleName = structuralShapeModule (aContext a) name
    rejectLine _ IgnoreUnknown _ _ = []
    rejectLine indent RejectUnknown allowed objectName =
      [indent <> "rejectUnknownFields " <> tshow name <> " " <> renderTextList allowed <> " " <> objectName]
    unionDecodeArm encoding arm =
      ["    " <> tshow (rwaTag arm) <> " -> do"]
        <> rejectLine "      " (ueUnknownFields encoding) allowed "objectValue"
        <> [ case rwaPayload arm of
               Nothing -> "      pure " <> shapeModuleName <> "." <> rwaCtor arm
               Just payload ->
                 "      "
                   <> shapeModuleName
                   <> "."
                   <> rwaCtor arm
                   <> " <$> (objectValue .: "
                   <> tshow (ueContentsField encoding)
                   <> " >>= ("
                   <> decodeShapeExpr a graph payload
                   <> "))"
           ]
      where
        allowed = ueTagField encoding : [ueContentsField encoding | rwaPayload arm /= Nothing]

decodeRecordField :: Agg -> TypeGraph -> ResolvedWireField -> Text
decodeRecordField a graph field = case rwfPresence field of
  PRequired ->
    "((objectValue .: " <> key <> " :: Parser Value) >>= (" <> decoder <> "))"
  POptional ->
    "(case KeyMap.lookup (Key.fromText "
      <> key
      <> ") objectValue of Nothing -> "
      <> missing
      <> "; Just presentValue -> "
      <> "("
      <> decoder
      <> ") presentValue)"
  where
    key = tshow (rwfKey field)
    decoder = decodeShapeExpr a graph (rwfType field)
    missing = case rwfOnMissing field of
      Nothing -> "fail " <> tshow ("missing optional field without default: " <> rwfKey field)
      Just onMissing -> "pure " <> renderMissingDefault a graph (rwfType field) onMissing

encodeShapeExpr :: Agg -> TypeGraph -> ResolvedTypeExpr -> Text -> Text
encodeShapeExpr _a graph expression value =
  foldTypeExpr
    TypeExprAlgebra
      { onText = \v -> "toJSON (" <> v <> ")",
        onInt = \v -> "toJSON (" <> v <> ")",
        onInteger = \v -> "toJSON (" <> v <> ")",
        onBool = \v -> "toJSON (" <> v <> ")",
        onNatural = \v -> "toJSON (" <> v <> ")",
        onTime = \v -> "toJSON (" <> v <> ")",
        onJson = id,
        onOptional = \encode v -> "maybe Null (\\item -> " <> encode "item" <> ") (" <> v <> ")",
        onList = \encode v -> "toJSON (map (\\item -> " <> encode "item" <> ") (" <> v <> "))",
        onMap = \encode v -> "toJSON (Map.map (\\item -> " <> encode "item" <> ") (" <> v <> "))",
        onRef = \key v -> case Map.lookup key (tgDeclarations graph) of
          Just (ResolvedStructural nested _) -> "encode" <> sdName nested <> "Shape (" <> v <> ")"
          Just (ResolvedOpaque _) -> "toJSON (" <> v <> ")"
          Nothing -> "toJSON (" <> v <> ")"
      }
    expression
    value

decodeShapeExpr :: Agg -> TypeGraph -> ResolvedTypeExpr -> Text
decodeShapeExpr _a graph =
  foldTypeExpr
    TypeExprAlgebra
      { onText = "parseJSON",
        onInt = "parseJSON",
        onInteger = "parseJSON",
        onBool = "parseJSON",
        onNatural = "parseJSON",
        onTime = "parseJSON",
        onJson = "pure",
        onOptional = \decode -> "\\value -> case value of Null -> pure Nothing; other -> Just <$> " <> decode <> " other",
        onList = \decode -> "\\value -> (parseJSON value :: Parser [Value]) >>= traverse (" <> decode <> ")",
        onMap = \decode -> "\\value -> (parseJSON value :: Parser (Map Text Value)) >>= traverse (" <> decode <> ")",
        onRef = \key -> case Map.lookup key (tgDeclarations graph) of
          Just (ResolvedStructural nested _) -> "parse" <> sdName nested <> "Shape"
          Just (ResolvedOpaque _) -> "parseJSON"
          Nothing -> "parseJSON"
      }

renderMissingDefault :: Agg -> TypeGraph -> ResolvedTypeExpr -> OnMissing -> Text
renderMissingDefault a graph expression = \case
  OmNull -> "Nothing"
  OmText value -> tshow value
  OmInt value -> T.pack (show value)
  OmBool value -> if value then "True" else "False"
  OmEmptyList -> "[]"
  OmEmptyMap -> "Map.empty"
  OmCtor constructor -> case expression of
    RRef key -> case Map.lookup key (tgDeclarations graph) of
      Just (ResolvedStructural declaration _) -> structuralShapeModule (aContext a) (sdName declaration) <> "." <> constructor
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

--------------------------------------------------------------------------------
-- Authoritative version-2 expressions and transducer
--------------------------------------------------------------------------------

hasVersion2Ownership :: Agg -> Bool
hasVersion2Ownership = any ((/= LegacyHoleImplementation) . tImplementation) . aTransitions

transitionEntries :: Agg -> [(Int, Transition)]
transitionEntries aggregate = zip [1 ..] (aTransitions aggregate)

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

expressionFunctionNames :: Agg -> [Text]
expressionFunctionNames aggregate =
  concat
    [ maybe [] (const [guardFunctionName index transition]) (tGuard transition)
        <> [writeFunctionName index transition registerName | (registerName, _) <- tWrites transition]
    | (index, transition) <- transitionEntries aggregate,
      tImplementation transition == GeneratedImplementation
    ]

emitExpressions :: Agg -> Text
emitExpressions aggregate
  | null exports = nl [generatedBanner, "module " <> aGenPrefix aggregate <> ".Expressions () where"]
  | otherwise =
      nl $
        [ "{-# LANGUAGE DataKinds #-}",
          "{-# LANGUAGE OverloadedLabels #-}",
          "{-# LANGUAGE OverloadedRecordDot #-}",
          "{-# LANGUAGE TypeApplications #-}",
          generatedBanner
        ]
          ++ moduleDeclaration
          ++ [ "",
               "import " <> aGenPrefix aggregate <> ".Domain",
               "import Keiki.Builder qualified as B",
               "import Keiki.Core qualified as K",
               "import Keiki.Generics (RegFieldsOf)"
             ]
          ++ ["import Data.Text (Text)" | expressionUsesType AggregateText]
          ++ ["import Data.Time.Clock (UTCTime)" | expressionUsesType AggregateTime && not expressionUsesTimeLiteral]
          ++ ["import Data.Time.Calendar (fromGregorian)" | expressionUsesTimeLiteral]
          ++ ["import Data.Time.Clock (UTCTime (..), picosecondsToDiffTime)" | expressionUsesTimeLiteral]
          ++ ["import Numeric.Natural (Natural)" | expressionUsesType AggregateNatural]
          ++ structuralProjectionImport
          ++ nominalProjectionImport
          ++ consumerImports
          ++ ["import Data.KindID qualified as KindID" | expressionUsesConsumerIdLiteral]
          ++ ["import Keiro.Codec.Nominal (nominalFromRepresentation)" | expressionUsesConsumerNominalLiteral]
          ++ consumerLiteralImports
          ++ concatMap (uncurry (emitTransitionExpressions aggregate)) (transitionEntries aggregate)
  where
    exports = expressionFunctionNames aggregate
    moduleDeclaration = case exports of
      firstExport : rest ->
        [ "module " <> aGenPrefix aggregate <> ".Expressions",
          "  ( " <> firstExport
        ]
          ++ ["  , " <> value | value <- rest]
          ++ ["  ) where"]
      [] -> error "non-empty expression export invariant"
    structuralProjectionImport =
      [ "import " <> structuralProjectionModule (aContext aggregate) <> " qualified as StructuralProjections"
      | maybe False (not . null . projectionSpecs) (aTypeGraph aggregate)
      ]
    nominalProjectionImport =
      [ "import " <> nominalProjectionModule (aContext aggregate) <> " qualified as NominalProjections"
      | any expressionUsesNominalProjection resolvedExpressions
      ]
    consumerImports =
      map ("import " <>)
        . filter (not . builtinExpressionImport)
        . sort
        . nub
        . Set.toList
        . Set.unions
        $ [ aggregateImports (aSymbols aggregate) resolvedType
          | resolvedType <- map rrType (aRegs aggregate) <> map snd (concatMap rcFields (aCommands aggregate))
          ]
    consumerLiteralImports =
      [ "import " <> nominalRepresentationModule (aContext aggregate) (resolvedNominalName nominal) <> " qualified"
      | nominal <- consumerLiteralNominals,
        EnumRepresentation {} <- [resolvedNominalRepresentation nominal]
      ]
        <> [ "import " <> qualifiedModule (consumerNominalBinding binding) <> " qualified"
           | nominal <- consumerLiteralNominals,
             ConsumerNominal binding <- [resolvedNominalOwnership nominal]
           ]
    resolvedExpressions = resolvedGeneratedExpressions aggregate
    expressionUsesType wanted = any (anyTypedExpression ((== wanted) . typedScalarType)) resolvedExpressions
    expressionUsesTimeLiteral = any (anyTypedExpression isTimeLiteral) resolvedExpressions
    expressionUsesConsumerNominalLiteral = not (null consumerLiteralNominals)
    expressionUsesConsumerIdLiteral = any (isIdRepresentation . resolvedNominalRepresentation) consumerLiteralNominals
    consumerLiteralNominals = nub [nominal | expression <- resolvedExpressions, nominal <- typedConsumerLiteralNominals expression]
    isTimeLiteral expression = case typedScalarNode expression of
      TypedLiteral ScalarTimeValue {} -> True
      _ -> False
    isIdRepresentation IdRepresentation {} = True
    isIdRepresentation _ = False

builtinExpressionImport :: Text -> Bool
builtinExpressionImport imported =
  any (`T.isPrefixOf` imported) ["Data.Text", "Data.Time", "Numeric.Natural"]

resolvedGeneratedExpressions :: Agg -> [TypedScalarExpr]
resolvedGeneratedExpressions aggregate =
  concat
    [ maybe [] (pure . resolvedGuard index transition) (tGuard transition)
        <> [ resolvedWrite index transition registerName expression
           | (registerName, expression) <- tWrites transition
           ]
    | (index, transition) <- transitionEntries aggregate,
      tImplementation transition == GeneratedImplementation
    ]
  where
    environment transition = expressionEnvironment (aSpec aggregate) (aAggregate aggregate) transition
    resolvedGuard index transition expression =
      expressionOrDie (guardFunctionName index transition) (resolveGuardExpr (environment transition) expression)
    resolvedWrite index transition registerName expression =
      expressionOrDie (writeFunctionName index transition registerName) (resolveWriteExpr (environment transition) registerName expression)

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

expressionUsesNominalProjection :: TypedScalarExpr -> Bool
expressionUsesNominalProjection = anyTypedExpression $ \expression -> case (typedScalarType expression, typedScalarNode expression) of
  (AggregateNominal nominal, TypedRoot {}) -> case (resolvedNominalOwnership nominal, resolvedNominalRepresentation nominal) of
    (ConsumerNominal {}, ScalarRepresentation {}) -> True
    _ -> False
  _ -> False

typedConsumerLiteralNominals :: TypedScalarExpr -> [ResolvedNominalType]
typedConsumerLiteralNominals expression = own <> concatMap typedConsumerLiteralNominals (typedExpressionChildren expression)
  where
    own = case (typedScalarType expression, typedScalarNode expression) of
      (AggregateNominal nominal, TypedLiteral ScalarEnumValue {})
        | ConsumerNominal {} <- resolvedNominalOwnership nominal -> [nominal]
      (AggregateNominal nominal, TypedLiteral ScalarIdValue {})
        | ConsumerNominal {} <- resolvedNominalOwnership nominal -> [nominal]
      _ -> []

emitTransitionExpressions :: Agg -> Int -> Transition -> [Text]
emitTransitionExpressions aggregate index transition
  | tImplementation transition /= GeneratedImplementation = []
  | otherwise =
      concat
        [ maybe [] (emitGuardDefinition aggregate index transition) (tGuard transition),
          concatMap (uncurry (emitWriteDefinition aggregate index transition)) (tWrites transition)
        ]

emitGuardDefinition :: Agg -> Int -> Transition -> Expr -> [Text]
emitGuardDefinition aggregate index transition expression =
  [ "",
    functionName <> " :: " <> payloadProjectionType aggregate transition <> " -> K.HsPred " <> aName aggregate <> "Regs " <> aName aggregate <> "Command",
    functionName <> " d = " <> renderKeikiPredicate aggregate transition resolved
  ]
  where
    functionName = guardFunctionName index transition
    resolved = expressionOrDie functionName (resolveGuardExpr (expressionEnvironment (aSpec aggregate) (aAggregate aggregate) transition) expression)

emitWriteDefinition :: Agg -> Int -> Transition -> Name -> Expr -> [Text]
emitWriteDefinition aggregate index transition registerName expression =
  [ "",
    functionName
      <> " :: "
      <> payloadProjectionType aggregate transition
      <> " -> K.Term "
      <> aName aggregate
      <> "Regs "
      <> aName aggregate
      <> "Command ("
      <> commandFieldsType transition
      <> ") "
      <> renderDomainType aggregate (typedScalarType resolved),
    functionName <> " d = " <> renderKeikiTerm aggregate transition resolved
  ]
  where
    functionName = writeFunctionName index transition registerName
    resolved = expressionOrDie functionName (resolveWriteExpr (expressionEnvironment (aSpec aggregate) (aAggregate aggregate) transition) registerName expression)

expressionOrDie :: Text -> Either (NonEmpty ExpressionDiagnostic) TypedScalarExpr -> TypedScalarExpr
expressionOrDie owner = either (error . (("validated expression disappeared for " <> T.unpack owner <> ": ") <>) . show) id

renderKeikiPredicate :: Agg -> Transition -> TypedScalarExpr -> Text
renderKeikiPredicate aggregate transition expression = case typedScalarNode expression of
  TypedEqual left right -> "K.PEq " <> atom (renderComparisonTerm aggregate transition left) <> " " <> atom (renderComparisonTerm aggregate transition right)
  TypedNotEqual left right -> "K.pnot (K.PEq " <> atom (renderComparisonTerm aggregate transition left) <> " " <> atom (renderComparisonTerm aggregate transition right) <> ")"
  TypedCompare operator left right ->
    "K.PCmp "
      <> renderKeikiCmp operator
      <> " "
      <> atom (renderComparisonTerm aggregate transition left)
      <> " "
      <> atom (renderComparisonTerm aggregate transition right)
  TypedAnd left right -> "K.PAnd " <> atom (renderKeikiPredicate aggregate transition left) <> " " <> atom (renderKeikiPredicate aggregate transition right)
  TypedOr left right -> "K.POr " <> atom (renderKeikiPredicate aggregate transition left) <> " " <> atom (renderKeikiPredicate aggregate transition right)
  _ -> "K.PEq " <> atom (renderKeikiTerm aggregate transition expression) <> " (K.lit True)"
  where
    atom value = "(" <> value <> ")"

renderKeikiCmp :: CmpOp -> Text
renderKeikiCmp = \case
  OpEq -> error "equality is rendered as PEq"
  OpNeq -> error "inequality is rendered as pnot PEq"
  OpLt -> "K.CmpLt"
  OpLe -> "K.CmpLe"
  OpGt -> "K.CmpGt"
  OpGe -> "K.CmpGe"

renderComparisonTerm :: Agg -> Transition -> TypedScalarExpr -> Text
renderComparisonTerm aggregate transition expression = case (typedScalarType expression, typedScalarNode expression) of
  (AggregateNominal nominal, TypedRoot provenance)
    | ConsumerNominal {} <- resolvedNominalOwnership nominal,
      ScalarRepresentation {} <- resolvedNominalRepresentation nominal ->
        renderNominalProjectionTerm aggregate transition nominal provenance
  _ -> renderKeikiTerm aggregate transition expression

renderNominalProjectionTerm :: Agg -> Transition -> ResolvedNominalType -> ScalarRootProvenance -> Text
renderNominalProjectionTerm aggregate transition nominal provenance = case provenance of
  ScalarRegisterRoot registerName ownerType ->
    "K.regProj NominalProjections."
      <> witness
      <> " (#"
      <> registerName
      <> " :: K.Index "
      <> aName aggregate
      <> "Regs "
      <> renderDomainType aggregate ownerType
      <> ")"
  ScalarCommandRoot fieldName ownerType ->
    "K.inpProj NominalProjections."
      <> witness
      <> " inCtor"
      <> tCommand transition
      <> " (#"
      <> fieldName
      <> " :: K.Index ("
      <> commandFieldsType transition
      <> ") "
      <> renderDomainType aggregate ownerType
      <> ")"
  where
    witness = lowerFirst (resolvedNominalName nominal) <> "Witness"

renderKeikiTerm :: Agg -> Transition -> TypedScalarExpr -> Text
renderKeikiTerm aggregate transition expression = case typedScalarNode expression of
  TypedLiteral value -> renderKeikiLiteral aggregate (typedScalarType expression) value
  TypedRoot (ScalarRegisterRoot registerName _) -> "B.reg @" <> tshow registerName
  TypedRoot (ScalarCommandRoot fieldName _) -> "d." <> fieldName
  TypedProject provenance projection -> renderStructuralProjectionTerm aggregate transition provenance projection
  TypedAdd _ left right -> binary "K.tadd" left right
  TypedSubtract _ left right -> binary "K.tsub" left right
  TypedMultiply _ left right -> binary "K.tmul" left right
  TypedEqual {} -> impossiblePredicate
  TypedNotEqual {} -> impossiblePredicate
  TypedCompare {} -> impossiblePredicate
  TypedAnd {} -> impossiblePredicate
  TypedOr {} -> impossiblePredicate
  where
    binary operator left right = operator <> " " <> parenthesized left <> " " <> parenthesized right
    parenthesized = (\value -> "(" <> value <> ")") . renderKeikiTerm aggregate transition
    impossiblePredicate = error "predicate-valued Boolean expressions cannot be lowered as register terms"

renderStructuralProjectionTerm :: Agg -> Transition -> ScalarRootProvenance -> ResolvedScalarProjection -> Text
renderStructuralProjectionTerm aggregate transition provenance projection = case provenance of
  ScalarRegisterRoot registerName ownerType ->
    "K.regProj StructuralProjections."
      <> witness
      <> " (#"
      <> registerName
      <> " :: K.Index "
      <> aName aggregate
      <> "Regs "
      <> renderDomainType aggregate ownerType
      <> ")"
  ScalarCommandRoot fieldName ownerType ->
    "K.inpProj StructuralProjections."
      <> witness
      <> " inCtor"
      <> tCommand transition
      <> " (#"
      <> fieldName
      <> " :: K.Index ("
      <> commandFieldsType transition
      <> ") "
      <> renderDomainType aggregate ownerType
      <> ")"
  where
    witness = lowerFirst (projectionTag (unMappedKey (scalarProjectionOwner projection)) (scalarProjectionPointer projection)) <> "Witness"

renderKeikiLiteral :: Agg -> ResolvedAggregateType -> ScalarValue -> Text
renderKeikiLiteral aggregate scalarType = \case
  ScalarTextValue value -> "K.lit (" <> tshow value <> " :: Text)"
  ScalarIntValue value -> "K.lit (" <> tshow' value <> " :: Int)"
  ScalarIntegerValue value -> "K.lit (" <> T.pack (show value) <> " :: Integer)"
  ScalarNaturalValue value -> "K.lit (" <> T.pack (show value) <> " :: Natural)"
  ScalarBoolValue value -> "K.lit " <> if value then "True" else "False"
  ScalarTimeValue value -> "K.lit " <> renderRegisterInitial (InitialTime value)
  ScalarEnumValue typeName constructor -> case scalarType of
    AggregateNominal nominal -> case resolvedNominalOwnership nominal of
      GeneratedNominal -> "K.lit " <> constructor
      ConsumerNominal binding ->
        "K.lit (nominalFromRepresentation "
          <> unQualifiedValueName (consumerNominalBinding binding)
          <> " "
          <> nominalRepresentationModule (aContext aggregate) typeName
          <> "."
          <> constructor
          <> ")"
    _ -> error "validated enum literal lost its nominal type"
  ScalarIdValue typeName value -> case scalarType of
    AggregateNominal nominal -> case resolvedNominalOwnership nominal of
      GeneratedNominal -> "K.lit (" <> typeName <> " " <> tshow value <> ")"
      ConsumerNominal binding -> case resolvedNominalRepresentation nominal of
        IdRepresentation prefix ->
          "K.lit (nominalFromRepresentation "
            <> unQualifiedValueName (consumerNominalBinding binding)
            <> " (case KindID.parseText @"
            <> tshow prefix
            <> " "
            <> tshow value
            <> " of Right parsed -> parsed; Left _ -> error \"validated ID literal failed to parse\"))"
        _ -> error "validated ID literal lost its ID representation"
    _ -> error "validated ID literal lost its nominal type"

emitGeneratedTransducer :: Agg -> Text
emitGeneratedTransducer aggregate =
  nl $
    [ "{-# LANGUAGE BlockArguments #-}",
      "{-# LANGUAGE DataKinds #-}",
      "{-# LANGUAGE GADTs #-}",
      "{-# LANGUAGE OverloadedRecordDot #-}",
      "{-# LANGUAGE QualifiedDo #-}",
      "{-# LANGUAGE TypeApplications #-}",
      generatedBanner,
      "module " <> aGenPrefix aggregate <> ".Transducer",
      "  ( " <> lowerFirst (aName aggregate) <> "Transducer",
      "  , " <> lowerFirst (aName aggregate) <> "FoldFingerprint",
      "  , BehaviorOwnership (..)",
      "  , " <> lowerFirst (aName aggregate) <> "PredicateVerifications",
      "  ) where",
      "",
      "import " <> aGenPrefix aggregate <> ".Domain",
      "import " <> aHolePrefix aggregate <> ".Holes qualified as Holes",
      "import Data.Text (Text)",
      "import Keiki.Builder qualified as B",
      "import Keiki.Core (HsPred, SymTransducer)",
      "import Keiki.Core qualified as K",
      "import Keiki.Symbolic qualified as S"
    ]
      ++ ["import " <> aGenPrefix aggregate <> ".Expressions qualified as Expressions" | not (null (expressionFunctionNames aggregate))]
      ++ ["import Data.Text qualified as T" | anyHoleOwned aggregate]
      ++ ["import Keiki.Builder ((=:))" | any (not . null . tWrites . snd) (transitionEntries aggregate)]
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
           nl (concatMap (generatedFromBlock aggregate) (groupTransitionEntriesBySource aggregate)),
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

anyHoleOwned :: Agg -> Bool
anyHoleOwned = any ((== HoleImplementation) . tImplementation) . aTransitions

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
      | (source, transitions) <- groupTransitionEntriesBySource aggregate,
        (edgeIndex, (transitionIndex, transition)) <- zip [0 ..] transitions
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
groupTransitionEntriesBySource aggregate = go [] (transitionEntries aggregate)
  where
    go accumulated [] = reverse accumulated
    go accumulated (entry@(_, transition) : remaining) =
      let source = tSource transition
          (same, rest) = span ((== source) . tSource . snd) remaining
       in go ((source, entry : same) : accumulated) rest

generatedFromBlock :: Agg -> (Text, [(Int, Transition)]) -> [Text]
generatedFromBlock aggregate (source, transitions) =
  ["    B.from " <> vertexCtor aggregate source <> " do"]
    ++ concatMap (uncurry (generatedOnCmdBlock aggregate)) transitions

generatedOnCmdBlock :: Agg -> Int -> Transition -> [Text]
generatedOnCmdBlock aggregate index transition =
  ["      B.onCmd inCtor" <> tCommand transition <> " $ \\d -> B.do"]
    ++ ["        B.replayOnly" | tMode transition == TmReplayOnly]
    ++ generatedBehavior
    ++ outputLines
    ++ ["        B.noEmit" | null (tEmits transition)]
    ++ ["        B.goto " <> vertexCtor aggregate (tGoto transition)]
  where
    generatedBehavior = case tImplementation transition of
      GeneratedImplementation ->
        maybe [] (const ["        B.requireGuard (Expressions." <> guardFunctionName index transition <> " d)"]) (tGuard transition)
          ++ [ "        B.slot @" <> tshow registerName <> " =: Expressions." <> writeFunctionName index transition registerName <> " d"
             | (registerName, _) <- tWrites transition
             ]
      HoleImplementation -> ["        Holes." <> holeFunctionName index transition <> " d"]
      LegacyHoleImplementation -> error "legacy transition reached version-2 transducer generation"
    outputLines =
      [ "        B.emit wire"
          <> eventName
          <> " (Holes."
          <> outputFunctionName index transition emitIndex eventName
          <> " d)"
      | (emitIndex, eventName) <- zip [1 ..] (tEmits transition)
      ]

--------------------------------------------------------------------------------
-- EventStream module
--------------------------------------------------------------------------------

emitEventStream :: Agg -> Text
emitEventStream a =
  nl $
    [ generatedBanner,
      "module " <> aGenPrefix a <> ".EventStream",
      "  ( " <> lowerFirst (aName a) <> "Category",
      "  , " <> lowerFirst (aName a) <> "EventStream",
      "  , " <> lowerFirst (aName a) <> "EventStreamDef",
      "  , " <> aName a <> "EventStream",
      "  , " <> aName a <> "EventStreamDef"
    ]
      ++ ["  , " <> lowerFirst (aName a) <> "SnapshotFixture" | hasSnapshot a]
      ++ [ "  ) where",
           "",
           "import " <> aGenPrefix a <> ".Domain",
           "import " <> aGenPrefix a <> ".Codec (" <> lowerFirst (aName a) <> "Codec)",
           transducerImport a,
           "import Keiki.Core (HsPred)",
           "import Keiro.EventStream (EventStream (..), SnapshotPolicy (..))",
           "import Keiro.EventStream.Validate (ValidatedEventStream, mkEventStreamOrThrow)"
         ]
      ++ ["import Data.Text (Text)" | hasSnapshot a]
      ++ ["import Keiro.Snapshot.Codec (defaultStateCodec, withFoldFingerprint)" | hasSnapshot a]
      ++ [ "import Keiro.Stream qualified as Stream",
           "",
           "-- The validated aggregate stream category (hole-kind 5: referenced, never retyped).",
           "-- Entity streams are '<category>-<id>' via Keiro.Stream.entityStream.",
           "-- categoryUnsafe is safe here because this generated literal passed the DSL category proof.",
           lowerFirst (aName a) <> "Category :: Stream.StreamCategory a",
           lowerFirst (aName a) <> "Category = Stream.categoryUnsafe " <> tshow categoryName,
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
           "    { transducer = " <> lowerFirst (aName a) <> "Transducer",
           "    , initialState = " <> initialVertex a,
           "    , initialRegisters = initial" <> aName a <> "Regs",
           "    , eventCodec = " <> lowerFirst (aName a) <> "Codec",
           "    , resolveStreamName = Stream.streamName",
           "    , snapshotPolicy = " <> snapshotPolicyExpr a
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
        <> lowerFirst (aName aggregate)
        <> "FoldFingerprint, "
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
  Nothing -> ["    , stateCodec = Nothing"]
  Just _
    | hasVersion2Ownership aggregate ->
        [ "    -- The snapshot discriminator composes: the spec's state-codec version (bump it",
          "    -- in the spec's `state-codec version=` clause), keiki's register and",
          "    -- control-state shape hashes, and this fold fingerprint derived from the",
          "    -- spec's transition surface (guards, writes, emits, states, register",
          "    -- initials, referenced rules). Spec-visible fold changes invalidate old",
          "    -- snapshots automatically. Version-2 Hole-owned transitions additionally",
          "    -- compose their explicit hand-owned FoldVersion tokens here; bump the",
          "    -- corresponding token whenever that Hole behavior changes.",
          "    , stateCodec = " <> stateCodecExpr aggregate
        ]
    | otherwise ->
        [ "    -- The snapshot discriminator composes: the spec's state-codec version (bump it",
          "    -- in the spec's `state-codec version=` clause), keiki's register and",
          "    -- control-state shape hashes, and this fold fingerprint derived from the",
          "    -- spec's transition surface (guards, writes, emits, states, register",
          "    -- initials, referenced rules). Spec-visible fold changes invalidate old",
          "    -- snapshots automatically. Fold changes made ONLY in the hand-owned Holes",
          "    -- module are invisible here: bump `state-codec version=` manually or old",
          "    -- snapshots will be served stale.",
          "    , stateCodec = " <> stateCodecExpr aggregate
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
  Nothing -> nl [generatedBanner, "module " <> aGenPrefix a <> ".Projection () where"]
  Just p ->
    nl
      [ "{-# LANGUAGE OverloadedRecordDot #-}",
        generatedBanner,
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
      "-- and every declared guard/write; this module supplies event fields and",
      "-- explicitly selected Hole behavior only."
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
  any (null . rcFields . eventForName aggregate) (concatMap tEmits (aTransitions aggregate))

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
        (emitIndex, eventName) <- zip [1 ..] (tEmits transition)
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
    | (emitIndex, eventName) <- zip [1 ..] (tEmits transition)
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
            <> nl (valueRecord [(fieldName, outputFieldValue fieldName fieldType) | (fieldName, fieldType) <- rcFields event])
    command = commandForTransition aggregate transition
    outputFieldValue fieldName fieldType
      | Just commandType <- lookup fieldName (rcFields command),
        commandType == fieldType =
          "d." <> fieldName
      | Just register <- find ((== fieldName) . rrName) (aRegs aggregate),
        rrType register == fieldType =
          "B.reg @" <> tshow fieldName
      | otherwise = "error " <> tshow ("HOLE: fill output field " <> rcName event <> "." <> fieldName)
    valueRecord fields =
      [ lead fieldIndex <> fieldName <> " = " <> fieldValue
      | (fieldIndex, (fieldName, fieldValue)) <- zip [0 :: Int ..] fields
      ]
        ++ ["  }"]
    lead 0 = "  { "
    lead _ = "  , "

emitHoleImplementation :: Agg -> Int -> Transition -> [Text]
emitHoleImplementation _ index transition
  | tImplementation transition /= HoleImplementation = []
  | otherwise =
      [ "",
        "-- HOLE: add the predicate and ordered register updates for this transition.",
        "-- The generated transducer still owns command matching, mode, emits, and goto.",
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
lowerFirst t = case T.uncons t of
  Just (c, rest) -> T.cons (toLower c) rest
  Nothing -> t

-- | Assert the shared category proof at emission time as a belt-and-braces
-- guard for callers that bypass the CLI's normal validate-before-scaffold path.
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
