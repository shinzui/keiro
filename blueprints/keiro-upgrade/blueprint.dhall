let S =
      https://raw.githubusercontent.com/shinzui/seihou-schema/49ff1e5b353b171b1b52946f478623ee4423ea93/package.dhall
        sha256:cadacb688dd31ec39feb7f2fe599973a1ad58ef8fcc8ed1100bf3da22a1222cb

in  S.Blueprint::{
    , name = "keiro-upgrade"
    , version = Some "0.1.0"
    , description = Some
        "Upgrade guidance for projects consuming Keiro, the event-sourcing framework and durable workflow engine. One edge per released version window that needs judgement work, with upstream cohort edges entailed so a project that has never heard of Kiroku still crosses them exactly once."
    , prompt = ./prompt.md as Text
    , versionProbe = Some
        "jq -r '.\"install-plan\"[] | select(.\"pkg-name\"==\"keiro\") | .\"pkg-version\"' dist-newstyle/cache/plan.json 2>/dev/null | sort -u | tail -1 | grep ."
    , allowedTools = Some [ "Bash(cabal *)", "Bash(just *)", "Bash(rg *)" ]
    , files =
      [ S.Blueprint.BlueprintFile::{
        , src = "keiro-cohort-versions.md"
        , description = Some
            "Which upstream cohort each Keiro release pairs with, how to read what this project actually resolved, deprecated upstream releases, and which PostgreSQL majors each layer covers."
        }
      ]
    , migrations =
      [ S.BlueprintMigration::{
        , from = "0.12.0.0"
        , to = "0.13.0.0"
        , prompt = ./migrations/0-12-to-0-13.md as Text
        , entails =
          [ S.EntailedEdge::{
            , blueprint = "kiroku-upgrade"
            , from = "0.7.0.1"
            , to = "0.8.0.0"
            }
          ]
        }
      ]
    , tags =
      [ "haskell"
      , "postgresql"
      , "event-sourcing"
      , "keiro"
      , "kiroku"
      , "migration"
      ]
    }
