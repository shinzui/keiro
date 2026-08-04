module Main (main) where

import Data.List (permutations)
import Data.List.NonEmpty qualified as NE
import Data.Text (Text)
import Keiro.Dsl.HaskellName
import Test.Hspec
import Test.Hspec.QuickCheck (prop)
import Test.QuickCheck (elements, forAll)

main :: IO ()
main = hspec $ do
  describe "checked generated Haskell names" $ do
    mapM_ pinnedExample pinnedExamples

    it "rejects empty, leading, trailing, repeated, and all-underscore input" $ do
      mapM_ (shouldReject . logicalSite) ["", "_foo", "foo_", "foo__bar", "_"]

    it "admits hyphens only for wire words" $ do
      derivePair LogicalWireWord (logicalSite "incident-paging")
        `shouldBe` Right ("IncidentPaging", "incidentPaging")
      deriveHaskellName LogicalIdentifier (logicalSite "incident-paging")
        `shouldSatisfy` isLeft

    it "rejects keywords created by normalization" $ do
      deriveHaskellName LogicalIdentifier (logicalSite "Module")
        `shouldBe` Left (ReservedGeneratedOccurrence (logicalSite "Module") "module")

    it "checks explicit consumer names without recasing them" $ do
      fmap renderModuleName (checkedModuleName explicitSite "Consumer.Legacy_name.Types")
        `shouldBe` Right "Consumer.Legacy_name.Types"
      checkedModuleName explicitSite "consumer.Types" `shouldSatisfy` isLeft

    it "compares module paths case-insensitively" $ do
      let first = occurrence ContextModuleSite ModuleSpace "Generated.Foo" "Foo" "foo"
          second = occurrence ContextModuleSite ModuleSpace "generated.foo" "foo" "FOO"
      detectNameCollisions [first, second] `shouldSatisfy` (not . null)

    it "permits the same selector on different generated records" $ do
      let first = scopedField "Generated.Foo" "Command" "value" "command.value"
          second = scopedField "Generated.Foo" "Event" "value" "event.value"
      detectNameCollisions [first, second] `shouldBe` []

    prop "collision evidence is independent of source traversal order" $
      forAll (elements (permutations collisionInventory)) $ \ordered ->
        detectNameCollisions ordered == detectNameCollisions collisionInventory

    mapM_ collisionKindExample [minBound .. maxBound]

pinnedExample :: (Text, Text, Text) -> SpecWith ()
pinnedExample (raw, upper, lower) =
  it (show raw <> " -> " <> show upper <> " / " <> show lower) $
    derivePair LogicalIdentifier (logicalSite raw) `shouldBe` Right (upper, lower)

pinnedExamples :: [(Text, Text, Text)]
pinnedExamples =
  [ ("foo_bar", "FooBar", "fooBar"),
    ("fooBar", "FooBar", "fooBar"),
    ("ThingID", "ThingID", "thingID"),
    ("HTTP_server2", "HTTPServer2", "httpServer2"),
    ("version2_event", "Version2Event", "version2Event")
  ]

derivePair :: NameSourceKind -> NameSite -> Either HaskellNameError (Text, Text)
derivePair source site = do
  derived <- deriveHaskellName source site
  pure (renderUpperCamelName (upperCamel derived), renderLowerCamelName (lowerCamel derived))

shouldReject :: NameSite -> Expectation
shouldReject site = deriveHaskellName LogicalIdentifier site `shouldSatisfy` isLeft

isLeft :: Either a b -> Bool
isLeft = \case
  Left _ -> True
  Right _ -> False

logicalSite :: Text -> NameSite
logicalSite raw = NameSite GeneratedTypeSite raw ("owner:" <> raw) 1

explicitSite :: NameSite
explicitSite = NameSite ImportAliasSite "consumer-reference" "consumer" 1

occurrence :: NameSiteKind -> HaskellOccurrenceSpace -> Text -> Text -> Text -> PlannedOccurrence
occurrence kind space target rendered owner =
  plannedOccurrence target space "" rendered (NameSite kind owner owner 1)

scopedField :: Text -> Text -> Text -> Text -> PlannedOccurrence
scopedField target scope rendered owner =
  plannedOccurrence target FieldSpace scope rendered (NameSite GeneratedFieldSite owner owner 1)

collisionInventory :: [PlannedOccurrence]
collisionInventory =
  [ occurrence GeneratedValueSite ValueSpace "Generated.Foo" "fooBar" "foo_bar",
    occurrence GeneratedValueSite ValueSpace "Generated.Foo" "fooBar" "fooBar"
  ]

collisionKindExample :: NameSiteKind -> SpecWith ()
collisionKindExample kind =
  it ("detects a normalized collision for " <> show kind) $ do
    let first = occurrence kind ValueSpace "Generated.Foo" "sameName" "first"
        second = occurrence kind ValueSpace "Generated.Foo" "sameName" "second"
    case detectNameCollisions [second, first] of
      [NormalizedNameCollision _ sites] -> map siteOwner (NE.toList sites) `shouldBe` ["first", "second"]
      other -> expectationFailure ("expected one collision, got " <> show other)
