let Schema = https://raw.githubusercontent.com/shinzui/mori-schema/a3c59033a08c2eaef2cfba4a3c99fc9c192ca6d7/package.dhall
      sha256:18258ef583580a897f4af3e7c86db0342afb42fb40efc535b217ba1089230141

let AgentPlans = https://raw.githubusercontent.com/shinzui/mori-schema/a3c59033a08c2eaef2cfba4a3c99fc9c192ca6d7/extensions/agent-plans/package.dhall
      sha256:0b567808087da1924fb121df044c9432f676bb81305d5373809e3182d054943b

in  AgentPlans.AgentPlansCatalog::{
    , plans =
      [ AgentPlans.ExposedPlan::{
        , kind = AgentPlans.PlanKind.MasterPlan
        , file = "docs/masterplans/1-keiro-research-foundation.md"
        , status = AgentPlans.PlanStatus.Complete
        , owner = None Text
        , summary = None Text
        , dependencies = [] : List AgentPlans.PlanDependency.Type
        }
      , AgentPlans.ExposedPlan::{
        , kind = AgentPlans.PlanKind.ExecPlan
        , file = "docs/plans/179-generate-one-human-readable-authoritative-keiro-transducer.md"
        , status = AgentPlans.PlanStatus.NotStarted
        , owner = None Text
        , summary = None Text
        , dependencies =
          [ AgentPlans.PlanDependency::{
            , kind = AgentPlans.DependencyKind.Hard
            , target = "mori://shinzui/keiki/plans/84-preserve-readable-business-semantics-in-keiki-transducers-and-diagrams"
            }
          , AgentPlans.PlanDependency::{
            , kind = AgentPlans.DependencyKind.Hard
            , target = "mori://shinzui/keiki/packages/keiki"
            }
          ]
        }
      , AgentPlans.ExposedPlan::{
        , kind = AgentPlans.PlanKind.ExecPlan
        , file = "docs/plans/6-upstream-roadmap-for-kiroku-and-keiki.md"
        , status = AgentPlans.PlanStatus.Complete
        , owner = None Text
        , summary = None Text
        , dependencies = [] : List AgentPlans.PlanDependency.Type
        }
      , AgentPlans.ExposedPlan::{
        , kind = AgentPlans.PlanKind.MasterPlan
        , file = "docs/masterplans/32-build-typed-projection-catalogs-and-safe-coordinated-rebuilds.md"
        , status = AgentPlans.PlanStatus.NotStarted
        , owner = None Text
        , summary = Some
            "Build one validated projection catalog and safe grouped rebuild lifecycle"
        , dependencies = [] : List AgentPlans.PlanDependency.Type
        }
      , AgentPlans.ExposedPlan::{
        , kind = AgentPlans.PlanKind.ExecPlan
        , file = "docs/plans/209-define-and-validate-the-typed-projection-catalog-runtime-contract.md"
        , status = AgentPlans.PlanStatus.NotStarted
        , owner = None Text
        , summary = Some
            "Define the pure typed catalog, validation, inventory, and compatibility contract"
        , dependencies = [] : List AgentPlans.PlanDependency.Type
        }
      , AgentPlans.ExposedPlan::{
        , kind = AgentPlans.PlanKind.ExecPlan
        , file = "docs/plans/210-coordinate-projection-target-groups-fencing-and-rebuild-policies.md"
        , status = AgentPlans.PlanStatus.NotStarted
        , owner = None Text
        , summary = Some
            "Make rebuild groups the atomic lifecycle, reset, and writer-fencing unit"
        , dependencies =
          [ AgentPlans.PlanDependency::{
            , kind = AgentPlans.DependencyKind.Hard
            , target = "mori://shinzui/keiro/plans/209-define-and-validate-the-typed-projection-catalog-runtime-contract"
            }
          ]
        }
      , AgentPlans.ExposedPlan::{
        , kind = AgentPlans.PlanKind.ExecPlan
        , file = "docs/plans/211-replay-catalogued-projections-deterministically-and-resumably.md"
        , status = AgentPlans.PlanStatus.NotStarted
        , owner = None Text
        , summary = Some
            "Replay fixed-head catalog sources in global order with durable resumable progress"
        , dependencies =
          [ AgentPlans.PlanDependency::{
            , kind = AgentPlans.DependencyKind.Hard
            , target = "mori://shinzui/keiro/plans/209-define-and-validate-the-typed-projection-catalog-runtime-contract"
            }
          , AgentPlans.PlanDependency::{
            , kind = AgentPlans.DependencyKind.Hard
            , target = "mori://shinzui/keiro/plans/210-coordinate-projection-target-groups-fencing-and-rebuild-policies"
            }
          , AgentPlans.PlanDependency::{
            , kind = AgentPlans.DependencyKind.Soft
            , target = "mori://shinzui/kiroku/okf/improvement-requests/concepts/IR-1"
            }
          ]
        }
      , AgentPlans.ExposedPlan::{
        , kind = AgentPlans.PlanKind.ExecPlan
        , file = "docs/plans/212-generate-projection-catalogs-from-keiro-dsl-and-classify-their-evolution.md"
        , status = AgentPlans.PlanStatus.NotStarted
        , owner = None Text
        , summary = Some
            "Generate catalog declarations in language 5 and classify their evolution"
        , dependencies =
          [ AgentPlans.PlanDependency::{
            , kind = AgentPlans.DependencyKind.Hard
            , target = "mori://shinzui/keiro/plans/209-define-and-validate-the-typed-projection-catalog-runtime-contract"
            }
          , AgentPlans.PlanDependency::{
            , kind = AgentPlans.DependencyKind.Hard
            , target = "mori://shinzui/keiro/plans/211-replay-catalogued-projections-deterministically-and-resumably"
            }
          ]
        }
      , AgentPlans.ExposedPlan::{
        , kind = AgentPlans.PlanKind.ExecPlan
        , file = "docs/plans/213-adopt-projection-catalogs-in-operations-examples-and-migration-guidance.md"
        , status = AgentPlans.PlanStatus.NotStarted
        , owner = None Text
        , summary = Some
            "Adopt catalog operations in examples, keiro-ops, and migration guidance"
        , dependencies =
          [ AgentPlans.PlanDependency::{
            , kind = AgentPlans.DependencyKind.Hard
            , target = "mori://shinzui/keiro/plans/211-replay-catalogued-projections-deterministically-and-resumably"
            }
          , AgentPlans.PlanDependency::{
            , kind = AgentPlans.DependencyKind.Soft
            , target = "mori://shinzui/keiro/plans/212-generate-projection-catalogs-from-keiro-dsl-and-classify-their-evolution"
            }
          , AgentPlans.PlanDependency::{
            , kind = AgentPlans.DependencyKind.Integration
            , target = "mori://shinzui/keiro/plans/208-make-keiro-ops-embeddable-and-document-the-operational-surface"
            }
          ]
        }
      ]
    }
