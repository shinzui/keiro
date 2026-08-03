-- | One generated facade that normalizes every node-level harness in a checked
-- service into executable checks and review-owned facts.
module Keiro.Dsl.ServiceHarness
  ( DuplicateServiceFactKey (..),
    serviceConformanceModuleName,
    serviceConformanceFactKeys,
    serviceHarnessModule,
  )
where

import Data.List (group, sort, sortOn)
import Data.Text (Text)
import Data.Text qualified as T
import Keiro.Dsl.Grammar
import Keiro.Dsl.Scaffold (Context, ModuleKind (Generated), ScaffoldModule (..), contextGeneratedPrefix, genPrefixFor, generatedBanner, pascal)
import Keiro.Dsl.SemanticContract (CheckedService (..))
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
  concatMap factKeysForNode (serviceHarnessNodes service)

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
      <> renderChecks checkSources
      <> [""]
      <> renderFacts factSources
  where
    indexed = zip [0 :: Int ..] (serviceHarnessNodes service)
    importLines
      | null indexed = []
      | otherwise = "" : map (renderImport ctx) indexed
    checkSources = [(node, aliasFor index) | (index, node) <- indexed, producesChecks node]
    factSources = [(node, aliasFor index) | (index, node) <- indexed, producesFacts node]

renderImport :: Context -> (Int, Node) -> Text
renderImport ctx (index, node) =
  "import " <> harnessModuleName ctx node <> " qualified as " <> aliasFor index

aliasFor :: Int -> Text
aliasFor index = "Harness" <> T.pack (show index)

harnessModuleName :: Context -> Node -> Text
harnessModuleName ctx = \case
  NAggregate aggregate -> genPrefixFor ctx (aggName aggregate) <> ".Harness"
  NProcess process -> genPrefixFor ctx (procId process) <> ".ProcessHarness"
  NRouter router -> genPrefixFor ctx (rtId router) <> ".RouterHarness"
  NReadModel readModel -> genPrefixFor ctx (pascal (rmName readModel)) <> ".ReadModelHarness"
  NWorkflow workflow -> genPrefixFor ctx (wfId workflow) <> ".WorkflowFacts"
  node -> error ("service harness requested a module for unsupported node " <> show (nodeIdentity node))

renderChecks :: [(Node, Text)] -> [Text]
renderChecks [] =
  [ "runServiceConformanceChecks :: IO [(String, Bool)]",
    "runServiceConformanceChecks = pure []"
  ]
renderChecks sources =
  [ "runServiceConformanceChecks :: IO [(String, Bool)]",
    "runServiceConformanceChecks =",
    "  pure ("
  ]
    <> renderConcatenation (map checkExpression sources)
    <> ["  )"]

checkExpression :: (Node, Text) -> Text
checkExpression (node, alias) = case node of
  NAggregate aggregate ->
    "[(\"aggregate/" <> aggName aggregate <> "/\" <> fact, passed) | (fact, passed) <- " <> alias <> ".harnessAssertions]"
  NReadModel readModel ->
    "[(\"readmodel/" <> rmName readModel <> "/\" <> fact, passed) | (fact, passed) <- " <> alias <> ".readModelFactResults]"
  _ -> error "checkExpression called for a fact-only node"

renderFacts :: [(Node, Text)] -> [Text]
renderFacts [] =
  [ "serviceConformanceFacts :: [(String, String)]",
    "serviceConformanceFacts = []"
  ]
renderFacts sources =
  [ "serviceConformanceFacts :: [(String, String)]",
    "serviceConformanceFacts ="
  ]
    <> renderConcatenation (map factExpression sources)

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

factKeysForNode :: Node -> [Text]
factKeysForNode node =
  [kindName <> "/" <> nodeName <> "/" <> factName | factName <- factNames]
  where
    (kindName, nodeName, _) = nodeIdentity node
    factNames = case node of
      NProcess {} -> processFactNames
      NRouter {} -> routerFactNames
      NWorkflow {} -> workflowFactNames
      _ -> []

processFactNames :: [Text]
processFactNames =
  [ "fireAtField",
    "timerIdPrefix",
    "firedEventIdPrefix",
    "dispatchIdUserField",
    "onReject",
    "onAmbiguous",
    "onFailed",
    "rejectedPolicy",
    "poisonPolicy",
    "maxAttempts"
  ]

routerFactNames :: [Text]
routerFactNames =
  [ "routerName",
    "keyField",
    "resolveSource",
    "resolveRow",
    "dispatchCommand",
    "dispatchIdInputs",
    "onDuplicate",
    "onFailed",
    "rejectedPolicy",
    "poisonPolicy"
  ]

workflowFactNames :: [Text]
workflowFactNames = ["name", "idVia", "idField", "body", "awaits", "patches"]
