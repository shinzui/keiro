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
    , version = Some "0.2.0"
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
