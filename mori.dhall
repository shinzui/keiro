let Schema =
      https://raw.githubusercontent.com/shinzui/mori-schema/93104153ecf8817547229a867302a70a25c4b3d8/package.dhall
        sha256:5e00bba267f27069df1d3caadfec2ec6a8c4e797ce652d78c09528f981b71b42

in  Schema.Project::{
    , project = Schema.ProjectIdentity::{
      , name = "keiro"
      , namespace = "shinzui"
      , type = Schema.PackageType.Other "Framework"
      , language = Schema.Language.Haskell
      , lifecycle = Schema.Lifecycle.Active
      , description = Some "Event sourcing framework and workflow engine"
      , domains = [ "EventSourcing", "Workflow" ]
      }
    , repos = [ Schema.Repo::{ name = "keiro" } ]
    , packages =
      [ Schema.Package::{
        , name = "keiro-core"
        , type = Schema.PackageType.Library
        , language = Schema.Language.Haskell
        , description = Some "Core contracts for Keiro packages"
        }
      , Schema.Package::{
        , name = "keiro"
        , type = Schema.PackageType.Library
        , language = Schema.Language.Haskell
        , description = Some "Event sourcing framework and workflow engine"
        }
      , Schema.Package::{
        , name = "keiro-test-support"
        , type = Schema.PackageType.Library
        , language = Schema.Language.Haskell
        , description = Some "Shared PostgreSQL test fixtures for Keiro test suites"
        }
      , Schema.Package::{
        , name = "keiro-pgmq"
        , type = Schema.PackageType.Library
        , language = Schema.Language.Haskell
        , description = Some "PostgreSQL job-queue (PGMQ) integration for Keiro"
        }
      , Schema.Package::{
        , name = "keiro-dsl"
        , type = Schema.PackageType.Other "Toolchain"
        , language = Schema.Language.Haskell
        , description = Some
            "Typed-spec (.keiro) toolchain for aggregates, integration, queues, read models, routers, processes, and workflows: parse/check/scaffold/harness/diff. Authoring skill: agents/skills/keiro-dsl-authoring; corpus index: docs/corpus/keiro-dsl-corpus.md"
        }
      ]
    , dependencies =
      [ "shinzui/kiroku"
      , "shinzui/keiki"
      , "shinzui/shibuya"
      , "hasql/hasql"
      , "effectful/effectful"
      ]
    , okfBundles =
      [ Schema.OkfBundle::{
        , name = "adrs"
        , path = "docs/adr"
        , profile = Some "docs/adr/profile.dhall"
        , okfVersion = "0.1"
        , description = Some "Durable architecture decisions"
        }
      ]
    }
