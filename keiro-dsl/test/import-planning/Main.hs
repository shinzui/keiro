{-# LANGUAGE ImportQualifiedPost #-}

module Main (main) where

import Data.Set qualified as Set
import Data.Text qualified as T
import Keiro.Dsl.HaskellImport
import Test.Hspec

main :: IO ()
main = hspec $ describe "haskell import planning" $ do
  it "imports a unique external type explicitly and renders it unqualified" $ do
    let reference = typeReference "Mori.Modules.Project.Domain.Types" "ProjectArtifactId"
        plan = expectImportPlan defaultImportEnvironment (Set.singleton reference)
    renderPlannedImports plan
      `shouldBe` "import Mori.Modules.Project.Domain.Types (ProjectArtifactId)"
    renderPlannedReference plan reference `shouldBe` Right "ProjectArtifactId"

  it "short-qualifies colliding type occurrence names with unique suffixes" $ do
    let orderStatus = typeReference "Consumer.Order.Types" "Status"
        invoiceStatus = typeReference "Consumer.Invoice.Types" "Status"
        plan = expectImportPlan defaultImportEnvironment (Set.fromList [orderStatus, invoiceStatus])
    renderPlannedImports plan
      `shouldBe` T.intercalate
        "\n"
        [ "import Consumer.Invoice.Types qualified as InvoiceTypes",
          "import Consumer.Order.Types qualified as OrderTypes"
        ]
    renderPlannedReference plan orderStatus `shouldBe` Right "OrderTypes.Status"
    renderPlannedReference plan invoiceStatus `shouldBe` Right "InvoiceTypes.Status"

  it "qualifies values and constructors and deduplicates their module import" $ do
    let binding = valueReference "Consumer.Order.Bindings" "orderBinding"
        constructor = constructorReference "Consumer.Order.Bindings" "OrderBinding"
        plan = expectImportPlan defaultImportEnvironment (Set.fromList [binding, constructor, binding])
    renderPlannedImports plan
      `shouldBe` "import Consumer.Order.Bindings qualified as Bindings"
    renderPlannedReference plan binding `shouldBe` Right "Bindings.orderBinding"
    renderPlannedReference plan constructor `shouldBe` Right "Bindings.OrderBinding"

  it "merges and sorts explicit imports from one module" $ do
    let alpha = typeReference "Consumer.Types" "Alpha"
        zeta = typeReference "Consumer.Types" "Zeta"
        plan = expectImportPlan defaultImportEnvironment (Set.fromList [zeta, alpha, zeta])
    renderPlannedImports plan
      `shouldBe` "import Consumer.Types (Alpha, Zeta)"

  it "qualifies type names that conflict with local names or reserved qualifiers" $ do
    let local = typeReference "Consumer.Domain" "Domain"
        reserved = typeReference "Consumer.Map" "Map"
        environment =
          defaultImportEnvironment
            { localNames = Set.singleton "Domain",
              reservedQualifiers = Set.insert "Map" (reservedQualifiers defaultImportEnvironment)
            }
        plan = expectImportPlan environment (Set.fromList [local, reserved])
    renderPlannedImports plan
      `shouldBe` T.intercalate
        "\n"
        [ "import Consumer.Domain qualified as ConsumerDomain",
          "import Consumer.Map qualified as ConsumerMap"
        ]
    renderPlannedReference plan local `shouldBe` Right "ConsumerDomain.Domain"
    renderPlannedReference plan reserved `shouldBe` Right "ConsumerMap.Map"

  it "is independent of reference discovery order" $ do
    let references =
          [ typeReference "Consumer.Order.Types" "Status",
            typeReference "Consumer.Invoice.Types" "Status",
            typeReference "Consumer.Shared.Types" "Label",
            valueReference "Consumer.Bindings" "statusBinding"
          ]
        forward = expectImportPlan defaultImportEnvironment (Set.fromList references)
        backward = expectImportPlan defaultImportEnvironment (Set.fromList (reverse references))
    renderPlannedImports forward `shouldBe` renderPlannedImports backward
    traverse (renderPlannedReference forward) references
      `shouldBe` traverse (renderPlannedReference backward) references

  it "reports missing references with target-module context" $ do
    let planned = typeReference "Consumer.Types" "Planned"
        missing = typeReference "Consumer.Types" "Missing"
        plan = expectImportPlan defaultImportEnvironment (Set.singleton planned)
    renderPlannedReference plan missing
      `shouldBe` Left (MissingHaskellReference "Generated.Example" missing)

defaultImportEnvironment :: ImportEnvironment
defaultImportEnvironment =
  ImportEnvironment
    { targetModule = "Generated.Example",
      localNames = Set.empty,
      reservedQualifiers = Set.fromList ["B", "K", "KindID", "Map", "S", "Set", "T"]
    }

typeReference :: T.Text -> T.Text -> HaskellReference
typeReference moduleName occurrence =
  HaskellReference moduleName occurrence TypeNamespace PreferUnqualified

valueReference :: T.Text -> T.Text -> HaskellReference
valueReference moduleName occurrence =
  HaskellReference moduleName occurrence ValueNamespace RequireQualified

constructorReference :: T.Text -> T.Text -> HaskellReference
constructorReference moduleName occurrence =
  HaskellReference moduleName occurrence ConstructorNamespace RequireQualified

expectImportPlan :: ImportEnvironment -> Set.Set HaskellReference -> HaskellImportPlan
expectImportPlan environment references =
  either
    (error . ("unexpected Haskell import planning failure: " <>) . show)
    id
    (planHaskellImports environment references)
