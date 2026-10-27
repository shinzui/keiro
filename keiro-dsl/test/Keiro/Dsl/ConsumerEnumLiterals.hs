module Keiro.Dsl.ConsumerEnumLiterals (consumerEnumLiteralsSpec) where

import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import Keiro.Dsl.Grammar hiding (Spec)
import Keiro.Dsl.Parser
import Keiro.Dsl.Scaffold
import Keiro.Dsl.ScaffoldRun (scaffoldServiceModules)
import Keiro.Dsl.SemanticContract
import Keiro.Dsl.Validate
import Test.Hspec

consumerEnumLiteralsSpec :: Spec
consumerEnumLiteralsSpec = describe "consumer nominal enum literals" $ do
  it "plans binding and representation imports only for literals outside comparisons" $ do
    guarded <- modulesFor (replaceGuard "cmd.orderId == reg.orderId && cmd.status == OrderStatus.Draft")
    let transducer = moduleText "NominalLedger/Transducer.hs" guarded
    transducer `shouldSatisfy` T.isInfixOf "commandStatus .== K.lit (\"draft\" :: Text)"
    transducer `shouldSatisfy` (not . T.isInfixOf "nominalFromRepresentation")
    transducer `shouldSatisfy` (not . T.isInfixOf "Shape.OrderStatus")
    transducer `shouldSatisfy` (not . T.isInfixOf "qualified as Bindings")
    written <- modulesFor (T.replace "write status := cmd.status" "write status := OrderStatus.Submitted")
    let writer = moduleText "NominalLedger/Transducer.hs" written
    writer `shouldSatisfy` T.isInfixOf "import Keiro.Codec.Nominal (nominalFromRepresentation)"
    writer `shouldSatisfy` T.isInfixOf "K.lit (nominalFromRepresentation Bindings.orderStatusBinding ShapeOrderStatus.Submitted)"
  it "samples literal-guarded consumer enum commands by canonical key instead of fixture order" $ do
    let sampled filters = "(case [value | fixture <- NonEmpty.toList (nominalFixtureCases Bindings.orderStatusFixtures), let value = nominalFixtureDomain fixture, " <> filters <> "] of value : _ -> value; [] -> error \"enum guard requires a matching supplied fixture\")"
        harnessFor guardText = moduleText "NominalLedger/Harness.hs" <$> modulesFor (replaceGuard guardText)
    equality <- harnessFor "cmd.orderId == reg.orderId && cmd.status == OrderStatus.Draft"
    equality `shouldSatisfy` T.isInfixOf "fieldWitnessGet"
    equality `shouldSatisfy` T.isInfixOf "qualified as NominalProjections"
    equality `shouldSatisfy` T.isInfixOf ("(RecordNominals (RecordNominalsData Bindings.initialOrderId " <> sampled "fieldWitnessGet NominalProjections.orderStatusEqualityWitness value == \"draft\"")
    inequality <- harnessFor "cmd.orderId == reg.orderId && cmd.status != reg.status"
    inequality `shouldSatisfy` T.isInfixOf ("(RecordNominals (RecordNominalsData Bindings.initialOrderId " <> sampled "value /= Bindings.initialOrderStatus")
    combined <- harnessFor "cmd.orderId == reg.orderId && cmd.status != reg.status && cmd.status != OrderStatus.Submitted"
    combined `shouldSatisfy` T.isInfixOf ("(RecordNominals (RecordNominalsData Bindings.initialOrderId " <> sampled "value /= Bindings.initialOrderStatus, fieldWitnessGet NominalProjections.orderStatusEqualityWitness value /= \"submitted\"")
    original <- moduleText "NominalLedger/Harness.hs" <$> modulesFor id
    original `shouldSatisfy` T.isInfixOf "(RecordNominals (RecordNominalsData Bindings.initialOrderId Bindings.initialOrderStatus "
    original `shouldSatisfy` (not . T.isInfixOf "fieldWitnessGet")

fixture :: IO Text
fixture = TIO.readFile "test/fixtures/nominal-scalars.keiro"

modulesFor :: (Text -> Text) -> IO [ScaffoldModule]
modulesFor transform = do
  source <- fixture
  service <- case parseSource "nominal-scalars.keiro" (transform source) of
    Left failure -> expectationFailure (T.unpack (renderParseFailure failure)) >> fail "parse failed"
    Right parsed -> pure (checkedSource parsed)
  filter ((== Error) . (.severity)) (validateService service) `shouldBe` []
  let modules = scaffoldServiceModules (defaultContext "nominal-scalars") service
  firewallBreaches modules `shouldBe` []
  pure modules

replaceGuard :: Text -> Text -> Text
replaceGuard guardText = T.replace "guard cmd.orderId == reg.orderId && cmd.status == reg.status" ("guard " <> guardText)

moduleText :: Text -> [ScaffoldModule] -> Text
moduleText suffix modules = T.unlines [value.text | value <- modules, suffix `T.isSuffixOf` T.pack value.path]
