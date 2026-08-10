-- | One generated facade that normalizes every node-level harness in a checked
-- service into executable checks and review-owned facts.
module Keiro.Dsl.ServiceHarness
  ( DuplicateServiceFactKey (..),
    serviceConformanceModuleName,
    serviceConformanceFactKeys,
    serviceConformanceFactValues,
    serviceHarnessModule,
  )
where

import Data.List (group, mapAccumL, sort, sortOn)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Keiro.Dsl.Grammar
import Keiro.Dsl.Harness (processHarnessFactValues, routerHarnessFactValues, workflowHarnessFactValues)
import Keiro.Dsl.LanguageVersion (LanguageFeature (MappedConsumerSurfaceSyntax), languageSupportsFeature)
import Keiro.Dsl.Scaffold (Context, ModuleKind (Generated), ScaffoldModule (..), contextGeneratedPrefix, genPrefixFor, generatedBanner, pascal)
import Keiro.Dsl.SemanticContract (CheckedService (..), effectiveContractLanguageVersion)
import Keiro.Dsl.SemanticImpact (mappedSurfaceFactValues, semanticImpact)
import Keiro.Dsl.StructuralConformance (hasStructuralConformance, structuralConformanceModuleName)
import Keiro.Dsl.TypeGraph (resolveTypeGraph)
import Keiro.Dsl.Validate (nodeIdentity)

-- | A fully qualified process, router, or workflow fact key that would occur
-- more than once in the generated facade.
newtype DuplicateServiceFactKey = DuplicateServiceFactKey
  { duplicateServiceFactKey :: Text
  }
  deriving stock (Eq, Ord, Show)

-- | The stable context-level facade module imported by the generated package.
serviceConformanceModuleName :: Context -> Text
serviceConformanceModuleName ctx = contextGeneratedPrefix ctx <> ".Conformance"

-- | Every normalized expectation key in stable node-identity order.
serviceConformanceFactKeys :: CheckedService -> [Text]
serviceConformanceFactKeys service =
  map fst (serviceConformanceFactValues service)

-- | The create-once expectation baseline for all facts-producing nodes.
serviceConformanceFactValues :: CheckedService -> [(Text, Text)]
serviceConformanceFactValues service =
  surfaceFactValues service <> concatMap valuesForNode (serviceHarnessNodes service)

-- | Emit exactly one facade, including an empty facade for a service with no
-- harness-producing nodes. Duplicate normalized expectation keys are refused
-- before a scaffold write set exists.
serviceHarnessModule :: Context -> CheckedService -> Either [DuplicateServiceFactKey] ScaffoldModule
serviceHarnessModule ctx service = case duplicateKeys of
  [] -> Right facade
  keys -> Left (map DuplicateServiceFactKey keys)
  where
    duplicateKeys =
      [ key
      | key : duplicate : _ <- group (sort (serviceConformanceFactKeys service)),
        key == duplicate
      ]
    moduleName = serviceConformanceModuleName ctx
    facade =
      ScaffoldModule
        { modulePath = T.unpack (T.replace "." "/" moduleName <> ".hs"),
          moduleText = renderServiceHarness ctx service,
          kind = Generated,
          origin = "context " <> specContext (checkedSpec service) <> " service conformance facade"
        }

renderServiceHarness :: Context -> CheckedService -> Text
renderServiceHarness ctx service =
  T.unlines $
    [ generatedBanner,
      "module " <> serviceConformanceModuleName ctx,
      "  ( runServiceConformanceChecks",
      "  , serviceConformanceFacts",
      "  ) where"
    ]
      <> importLines
      <> [""]
      <> renderChecks hasStructural checkSources
      <> [""]
      <> renderFacts (surfaceFactValues service) factSources
  where
    hasStructural = hasStructuralConformance service
    aliased = aliasNodes hasStructural (serviceHarnessNodes service)
    importLines
      | null imports = []
      | otherwise = "" : imports
    imports =
      ["import " <> structuralConformanceModuleName ctx <> " qualified as StructuralConformance" | hasStructural]
        <> map (renderImport ctx) aliased
    checkSources = [(node, alias) | (node, alias) <- aliased, producesChecks node]
    factSources = [(node, alias) | (node, alias) <- aliased, producesFacts node]

renderImport :: Context -> (Node, Text) -> Text
renderImport ctx (node, alias) =
  "import " <> harnessModuleName ctx node <> " qualified as " <> alias

aliasNodes :: Bool -> [Node] -> [(Node, Text)]
aliasNodes reservesStructural nodes = snd (mapAccumL assign initialCounts nodes)
  where
    initialCounts = Map.fromList [("StructuralConformance", 1 :: Int) | reservesStructural]
    assign counts node =
      let base = aliasForNode node
          occurrence = Map.findWithDefault 0 base counts + 1
          alias = base <> if occurrence == (1 :: Int) then "" else T.pack (show occurrence)
       in (Map.insert base occurrence counts, (node, alias))

aliasForNode :: Node -> Text
aliasForNode node =
  let (_, nodeName, _) = nodeIdentity node
   in pascal nodeName

harnessModuleName :: Context -> Node -> Text
harnessModuleName ctx = \case
  NAggregate aggregate -> genPrefixFor ctx (aggName aggregate) <> ".Harness"
  NProcess process -> genPrefixFor ctx (procId process) <> ".ProcessHarness"
  NRouter router -> genPrefixFor ctx (rtId router) <> ".RouterHarness"
  NReadModel readModel -> genPrefixFor ctx (pascal (rmName readModel)) <> ".ReadModelHarness"
  NWorkflow workflow -> genPrefixFor ctx (wfId workflow) <> ".WorkflowFacts"
  node -> error ("service harness requested a module for unsupported node " <> show (nodeIdentity node))

renderChecks :: Bool -> [(Node, Text)] -> [Text]
renderChecks False [] =
  [ "runServiceConformanceChecks :: IO [(String, Bool)]",
    "runServiceConformanceChecks = pure []"
  ]
renderChecks hasStructural sources =
  [ "runServiceConformanceChecks :: IO [(String, Bool)]",
    "runServiceConformanceChecks =",
    "  pure ("
  ]
    <> renderConcatenation (structuralExpressions <> map checkExpression sources)
    <> ["  )"]
  where
    structuralExpressions =
      [ "[(\"structural/\" <> fact, passed) | (fact, passed) <- StructuralConformance.structuralConformanceAssertions]"
      | hasStructural
      ]

checkExpression :: (Node, Text) -> Text
checkExpression (node, alias) = case node of
  NAggregate aggregate ->
    "[(\"aggregate/" <> aggName aggregate <> "/\" <> fact, passed) | (fact, passed) <- " <> alias <> ".harnessAssertions]"
  NReadModel readModel ->
    "[(\"readmodel/" <> rmName readModel <> "/\" <> fact, passed) | (fact, passed) <- " <> alias <> ".readModelFactResults]"
  _ -> error "checkExpression called for a fact-only node"

renderFacts :: [(Text, Text)] -> [(Node, Text)] -> [Text]
renderFacts [] [] =
  [ "serviceConformanceFacts :: [(String, String)]",
    "serviceConformanceFacts = []"
  ]
renderFacts surfaceFacts sources =
  [ "serviceConformanceFacts :: [(String, String)]",
    "serviceConformanceFacts ="
  ]
    <> renderConcatenation (surfaceExpression surfaceFacts <> map factExpression sources)

surfaceExpression :: [(Text, Text)] -> [Text]
surfaceExpression [] = []
surfaceExpression values =
  [ "[ " <> T.intercalate "\n    , " ["(" <> quoted key <> ", " <> quoted value <> ")" | (key, value) <- values] <> "\n    ]"
  ]
  where
    quoted = T.pack . show . T.unpack

factExpression :: (Node, Text) -> Text
factExpression (node, alias) =
  "[(\"" <> kindName <> "/" <> nodeName <> "/\" <> fact, value) | (fact, value) <- " <> alias <> "." <> valueName <> "]"
  where
    (kindName, nodeName, _) = nodeIdentity node
    valueName = case node of
      NProcess {} -> "processHarnessValues"
      NRouter {} -> "routerHarnessValues"
      NWorkflow {} -> "workflowFactValues"
      _ -> error "factExpression called for a check-only node"

renderConcatenation :: [Text] -> [Text]
renderConcatenation expressions = case expressions of
  [] -> []
  first : rest -> ("    " <> first) : ["    <> " <> expression | expression <- rest]

serviceHarnessNodes :: CheckedService -> [Node]
serviceHarnessNodes =
  sortOn sortKey . filter (\node -> producesChecks node || producesFacts node) . specNodes . checkedSpec
  where
    sortKey node = let (kindName, nodeName, _) = nodeIdentity node in (kindName, nodeName)

producesChecks :: Node -> Bool
producesChecks NAggregate {} = True
producesChecks NReadModel {} = True
producesChecks _ = False

producesFacts :: Node -> Bool
producesFacts NProcess {} = True
producesFacts NRouter {} = True
producesFacts NWorkflow {} = True
producesFacts _ = False

valuesForNode :: Node -> [(Text, Text)]
valuesForNode node =
  [(kindName <> "/" <> nodeName <> "/" <> factName, value) | (factName, value) <- factValues]
  where
    (kindName, nodeName, _) = nodeIdentity node
    factValues = case node of
      NProcess process -> processHarnessFactValues process
      NRouter router -> routerHarnessFactValues router
      NWorkflow workflow -> workflowHarnessFactValues workflow
      _ -> []

surfaceFactValues :: CheckedService -> [(Text, Text)]
surfaceFactValues service
  | not
      ( languageSupportsFeature
          (effectiveContractLanguageVersion (checkedLanguageContract service))
          MappedConsumerSurfaceSyntax
      ) =
      []
  | otherwise = case resolveTypeGraph (checkedSpec service) of
      Left _ -> []
      Right graph -> mappedSurfaceFactValues (semanticImpact graph)
