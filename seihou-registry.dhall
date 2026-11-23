{ repoName = "keiro"
, repoDescription = Some
    "Event-sourcing framework and durable workflow engine for Haskell"
, modules =
  [] : List
       { name : Text
       , version : Optional Text
       , path : Text
       , description : Optional Text
       , tags : List Text
       }
, recipes =
  [] : List
       { name : Text
       , version : Optional Text
       , path : Text
       , description : Optional Text
       , tags : List Text
       }
, blueprints =
  [ { name = "keiro-upgrade"
    , version = Some "0.15.0"
    , path = "blueprints/keiro-upgrade"
    , description = Some
        "Upgrade guidance for Keiro consumers: one agent-guided edge per released version window, with upstream cohort edges entailed"
    , tags =
      [ "haskell"
      , "postgresql"
      , "event-sourcing"
      , "keiro"
      , "kiroku"
      , "migration"
      ]
    }
  , { name = "keiro-adoption"
    , version = Some "0.1.0"
    , path = "blueprints/keiro-adoption"
    , description = Some
        "Qualify a Keiro 0.26+ cohort, plan project-specific runtime and DSL adoption, and run the domain audit through staged acceptance."
    , tags = [ "haskell", "keiro", "adoption", "migration", "domain-modeling" ]
    }
  , { name = "domain-scalar-identity-decoder-audit"
    , version = Some "0.2.0"
    , path = "blueprints/domain-scalar-identity-decoder-audit"
    , description = Some
        "Audit and remediate domain scalars, identity authority, and owned decoders with exhaustive source-bound classification and behavioral acceptance."
    , tags = [ "haskell", "domain-modeling", "identity", "decoding", "audit" ]
    }
  , { name = "keiro-ui-ops"
    , version = Some "0.1.0"
    , path = "blueprints/keiro-ui-ops"
    , description = Some
        "Connect keiro-ui to application ops with DSL-generated aggregate inspectors and a checked service topology."
    , tags = [ "haskell", "keiro", "keiro-ui", "operations", "topology" ]
    }
  ]
, prompts =
  [] : List
       { name : Text
       , version : Optional Text
       , path : Text
       , description : Optional Text
       , tags : List Text
       }
}
