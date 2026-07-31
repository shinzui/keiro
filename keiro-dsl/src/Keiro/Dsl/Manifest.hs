{- | The build-wiring __manifest__: a Cabal-pasteable summary of what a
@scaffold@ run produced. @scaffold@ writes @.hs@ files but the consumer still
has to wire them into a Cabal stanza by hand — the @other-modules@ list and the
@build-depends@ implied by the node kinds. This module renders both as plain
text a human pastes into a @.cabal@ file (see @keiro-dsl/keiro-dsl.cabal@'s
conformance stanzas for the hand-maintained version this replaces).

The dependency set is a pure function of which 'Node' constructors occur in the
spec. The mapping is grounded in the existing per-suite @build-depends@ in
@keiro-dsl/keiro-dsl.cabal@:

  * aggregate           => aeson, keiki, keiro, text, and time only when a direct
                           aggregate surface uses Time   (keiro-dsl-conformance)
  * process             => aeson, keiki, keiro, shibuya-core, text, time, uuid
                                                         (…-process-runtime)
  * contract            => aeson, text                   (…-contract)
  * intake/emit/publisher (full integration path)
                        => effectful-core, hasql-transaction, keiro, kiroku-store
                                                         (…-intake-full)
  * workqueue           => aeson, keiro-core, keiro-pgmq, text
                                                         (…-queue, …-queue-runtime)
  * dispatch            => aeson, effectful-core, keiro-pgmq, text
                                                         (…-dispatch-full)
  * workflow/operation  => containers, effectful-core, keiro, text
                            (…-workflow-full; facts and runtime wiring only,
                             with the body hand-owned)

@base@ is always present.
-}
module Keiro.Dsl.Manifest (
    renderManifest,
    manifestDependencies,
    moduleNameOf,
) where

import Data.List (nub, sort)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Keiro.Dsl.AggregateType
import Keiro.Dsl.Grammar
import Keiro.Dsl.MappedConsumer (ConsumerPlan (..), consumerPlan)
import Keiro.Dsl.NominalType
import Keiro.Dsl.Scaffold (ScaffoldModule (..))

{- | Render a Cabal-pasteable manifest from the modules a scaffold run produced
plus the node kinds present (which imply the dependency set). The first argument
names the source spec (for the header comment).
-}
renderManifest :: Text -> [ScaffoldModule] -> Spec -> Text
renderManifest specName mods spec =
    T.unlines $
        [ "-- keiro-dsl build manifest for " <> specName
        , "-- Paste the two blocks below into the consuming Cabal stanza."
        , "-- The generated layer is overwritten on every scaffold; hole modules are"
        , "-- create-if-absent (filled by hand)."
        , ""
        , "other-modules:"
        ]
            ++ map ("    " <>) (sort (map (moduleNameOf . modulePath) mods))
            ++ [ ""
               , "build-depends:"
               ]
            ++ map ("    , " <>) (manifestDependencies spec)
            ++ consumerBlocks
  where
    plan = consumerPlan spec
    consumerBlocks
        | null (consumerMappings plan) = []
        | otherwise =
            [ ""
            , "consumer-packages:"
            ]
                ++ map ("    " <>) (consumerPackages plan)
                ++ [ ""
                   , "consumer-modules:"
                   ]
                ++ map ("    " <>) (consumerModules plan)

{- | The dotted module name recovered from a 'ScaffoldModule' path: drop the
trailing @.hs@ and replace @/@ with @.@.
-}
moduleNameOf :: FilePath -> Text
moduleNameOf p = T.replace "/" "." (T.dropEnd 3 (T.pack p))

{- | The sorted, deduplicated dependency set implied by the node kinds present
in the spec. @base@ is always included.
-}
manifestDependencies :: Spec -> [Text]
manifestDependencies spec =
    sort (nub ("base" : consumerPackages (consumerPlan spec) <> concatMap (depsForNode spec) (specNodes spec)))

-- | The dependencies a single node kind implies (see the module header table).
depsForNode :: Spec -> Node -> [Text]
depsForNode spec n = case n of
    NAggregate aggregate -> ["aeson", "keiki", "keiro", "text"] <> aggregateDependencies spec aggregate
    NProcess{} -> ["aeson", "keiki", "keiro", "shibuya-core", "text", "time", "uuid"]
    NRouter{} -> ["effectful-core", "keiro", "shibuya-core", "text"]
    NContract{} -> ["aeson", "text"]
    NIntake{} -> integration
    NEmit{} -> integration
    NPublisher{} -> integration
    NWorkqueue{} -> ["aeson", "keiro-core", "keiro-pgmq", "text"]
    NPgmqDispatch{} -> ["aeson", "effectful-core", "keiro-pgmq", "text"]
    NReadModel{} -> ["effectful-core", "hasql-transaction", "keiro", "kiroku-store", "text"]
    NWorkflow{} -> ["containers", "effectful-core", "keiro", "text"]
    NOperation{} -> ["effectful-core", "keiro", "text"]
  where
    integration = ["effectful-core", "hasql-transaction", "keiro", "kiroku-store"]

aggregateDependencies :: Spec -> Aggregate -> [Text]
aggregateDependencies spec aggregate =
    Set.toAscList
        ( Set.unions
            [ aggregatePackages symbols resolvedType
            | resolvedType <- resolvedTypes
            ]
            <> Set.fromList
                [ "mmzk-typeid"
                | AggregateNominal nominal <- resolvedTypes
                , IdRepresentation{} <- [resolvedNominalRepresentation nominal]
                , ConsumerNominal{} <- [resolvedNominalOwnership nominal]
                ]
        )
  where
    symbols = aggregateSymbols spec
    resolvedTypes =
        [ resolvedType
        | register <- aggRegs aggregate
        , Right resolvedType <- [resolveAggregateType symbols (regLoc register) RegisterUse (regType register)]
        ]
            <> [ resolvedType
               | command <- aggCommands aggregate
               , field <- cmdFields command
               , Right resolvedType <- [inferAggregateFieldType symbols aggregate CommandFieldUse field]
               ]
            <> [ resolvedType
               | event <- aggEvents aggregate
               , EventFields fields <- [evBody event]
               , field <- fields
               , Right resolvedType <- [inferAggregateFieldType symbols aggregate EventFieldUse field]
               ]
