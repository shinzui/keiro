let Schema = https://raw.githubusercontent.com/shinzui/mori-schema/b418cde5b0ee1b4b9aff5450638df5b0a265df3b/package.dhall
      sha256:3b79aae9216456678300441ca8616b64a4b4fa520a1286dfcc418f60899d5d4a

let AgentPlans = https://raw.githubusercontent.com/shinzui/mori-schema/b418cde5b0ee1b4b9aff5450638df5b0a265df3b/extensions/agent-plans/package.dhall
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
        , file = "docs/plans/6-upstream-roadmap-for-kiroku-and-keiki.md"
        , status = AgentPlans.PlanStatus.Complete
        , owner = None Text
        , summary = None Text
        , dependencies = [] : List AgentPlans.PlanDependency.Type
        }
      ]
    }
