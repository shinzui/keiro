let Schema =
      https://raw.githubusercontent.com/shinzui/mori-schema/e4899c15b6a7c36f5d6f2619c8a36ceabe58fc41/package.dhall
        sha256:f33943bf2a160e4dc2087e482a3e784d39e79ff58d5ec67c1f53bcee3389e323

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
        , dependencies =
          [ Schema.Dependency.WithAugmentation
              { name = "shinzui/keiki:keiki"
              , extraDocs = [] : List Schema.DocRef.Type
              , localPathOverride = None Text
              , kind = Some Schema.DependencyKind.ThirdParty
              , source = Some Schema.DependencySource.Hackage
              , scope = Some Schema.DependencyScope.Regular
              , versionConstraint = Some ">=0.9 && <0.10"
              }
          , Schema.Dependency.WithAugmentation
              { name = "shinzui/kiroku:kiroku-store"
              , extraDocs = [] : List Schema.DocRef.Type
              , localPathOverride = None Text
              , kind = Some Schema.DependencyKind.ThirdParty
              , source = Some Schema.DependencySource.Hackage
              , scope = Some Schema.DependencyScope.Regular
              , versionConstraint = Some ">=0.7 && <0.8"
              }
          ]
        }
      , Schema.Package::{
        , name = "keiro"
        , type = Schema.PackageType.Library
        , language = Schema.Language.Haskell
        , description = Some "Event sourcing framework and workflow engine"
        , dependencies =
          [ Schema.Dependency.WithAugmentation
              { name = "effectful/effectful:effectful"
              , extraDocs = [] : List Schema.DocRef.Type
              , localPathOverride = None Text
              , kind = Some Schema.DependencyKind.ThirdParty
              , source = Some Schema.DependencySource.Hackage
              , scope = Some Schema.DependencyScope.Regular
              , versionConstraint = Some ">=2.6 && <2.7"
              }
          , Schema.Dependency.WithAugmentation
              { name = "effectful/effectful:effectful-core"
              , extraDocs = [] : List Schema.DocRef.Type
              , localPathOverride = None Text
              , kind = Some Schema.DependencyKind.ThirdParty
              , source = Some Schema.DependencySource.Hackage
              , scope = Some Schema.DependencyScope.Regular
              , versionConstraint = Some ">=2.6 && <2.7"
              }
          , Schema.Dependency.WithAugmentation
              { name = "hasql/hasql:hasql"
              , extraDocs = [] : List Schema.DocRef.Type
              , localPathOverride = None Text
              , kind = Some Schema.DependencyKind.ThirdParty
              , source = Some Schema.DependencySource.Hackage
              , scope = Some Schema.DependencyScope.Regular
              , versionConstraint = Some ">=1.10 && <1.11"
              }
          , Schema.Dependency.WithAugmentation
              { name = "hasql/hasql:hasql-pool"
              , extraDocs = [] : List Schema.DocRef.Type
              , localPathOverride = None Text
              , kind = Some Schema.DependencyKind.ThirdParty
              , source = Some Schema.DependencySource.Hackage
              , scope = Some Schema.DependencyScope.Regular
              , versionConstraint = Some ">=1.2 && <1.5"
              }
          , Schema.Dependency.WithAugmentation
              { name = "hasql/hasql:hasql-transaction"
              , extraDocs = [] : List Schema.DocRef.Type
              , localPathOverride = None Text
              , kind = Some Schema.DependencyKind.ThirdParty
              , source = Some Schema.DependencySource.Hackage
              , scope = Some Schema.DependencyScope.Regular
              , versionConstraint = Some ">=1.1 && <1.3"
              }
          , Schema.Dependency.WithAugmentation
              { name = "shinzui/keiki:keiki"
              , extraDocs = [] : List Schema.DocRef.Type
              , localPathOverride = None Text
              , kind = Some Schema.DependencyKind.ThirdParty
              , source = Some Schema.DependencySource.Hackage
              , scope = Some Schema.DependencyScope.Regular
              , versionConstraint = Some ">=0.9 && <0.10"
              }
          , Schema.Dependency.WithAugmentation
              { name = "shinzui/kiroku:kiroku-store"
              , extraDocs = [] : List Schema.DocRef.Type
              , localPathOverride = None Text
              , kind = Some Schema.DependencyKind.ThirdParty
              , source = Some Schema.DependencySource.Hackage
              , scope = Some Schema.DependencyScope.Regular
              , versionConstraint = Some ">=0.7 && <0.8"
              }
          , Schema.Dependency.WithAugmentation
              { name = "shinzui/shibuya:shibuya-core"
              , extraDocs = [] : List Schema.DocRef.Type
              , localPathOverride = None Text
              , kind = Some Schema.DependencyKind.ThirdParty
              , source = Some Schema.DependencySource.Hackage
              , scope = Some Schema.DependencyScope.Regular
              , versionConstraint = Some "^>=0.9.0.0"
              }
          ]
        }
      , Schema.Package::{
        , name = "keiro-test-support"
        , type = Schema.PackageType.Library
        , language = Schema.Language.Haskell
        , description = Some "Shared PostgreSQL test fixtures for Keiro test suites"
        , dependencies =
          [ Schema.Dependency.WithAugmentation
              { name = "effectful/effectful:effectful"
              , extraDocs = [] : List Schema.DocRef.Type
              , localPathOverride = None Text
              , kind = Some Schema.DependencyKind.ThirdParty
              , source = Some Schema.DependencySource.Hackage
              , scope = Some Schema.DependencyScope.Regular
              , versionConstraint = Some ">=2.6"
              }
          , Schema.Dependency.WithAugmentation
              { name = "hasql/hasql:hasql"
              , extraDocs = [] : List Schema.DocRef.Type
              , localPathOverride = None Text
              , kind = Some Schema.DependencyKind.ThirdParty
              , source = Some Schema.DependencySource.Hackage
              , scope = Some Schema.DependencyScope.Regular
              , versionConstraint = Some ">=1.10"
              }
          , Schema.Dependency.WithAugmentation
              { name = "hasql/hasql:hasql-pool"
              , extraDocs = [] : List Schema.DocRef.Type
              , localPathOverride = None Text
              , kind = Some Schema.DependencyKind.ThirdParty
              , source = Some Schema.DependencySource.Hackage
              , scope = Some Schema.DependencyScope.Regular
              , versionConstraint = Some ">=1.2"
              }
          , Schema.Dependency.WithAugmentation
              { name = "shinzui/kiroku:kiroku-store"
              , extraDocs = [] : List Schema.DocRef.Type
              , localPathOverride = None Text
              , kind = Some Schema.DependencyKind.ThirdParty
              , source = Some Schema.DependencySource.Hackage
              , scope = Some Schema.DependencyScope.Regular
              , versionConstraint = Some ">=0.7 && <0.8"
              }
          , Schema.Dependency.WithAugmentation
              { name = "shinzui/kiroku:kiroku-store-migrations"
              , extraDocs = [] : List Schema.DocRef.Type
              , localPathOverride = None Text
              , kind = Some Schema.DependencyKind.ThirdParty
              , source = Some Schema.DependencySource.Hackage
              , scope = Some Schema.DependencyScope.Regular
              , versionConstraint = Some "^>=0.3.2.0"
              }
          ]
        }
      , Schema.Package::{
        , name = "keiro-pgmq"
        , type = Schema.PackageType.Library
        , language = Schema.Language.Haskell
        , description = Some "PostgreSQL job-queue (PGMQ) integration for Keiro"
        , dependencies =
          [ Schema.Dependency.WithAugmentation
              { name = "effectful/effectful:effectful-core"
              , extraDocs = [] : List Schema.DocRef.Type
              , localPathOverride = None Text
              , kind = Some Schema.DependencyKind.ThirdParty
              , source = Some Schema.DependencySource.Hackage
              , scope = Some Schema.DependencyScope.Regular
              , versionConstraint = Some ">=2.6 && <2.7"
              }
          , Schema.Dependency.WithAugmentation
              { name = "hasql/hasql:hasql"
              , extraDocs = [] : List Schema.DocRef.Type
              , localPathOverride = None Text
              , kind = Some Schema.DependencyKind.ThirdParty
              , source = Some Schema.DependencySource.Hackage
              , scope = Some Schema.DependencyScope.Regular
              , versionConstraint = Some ">=1.10 && <1.11"
              }
          , Schema.Dependency.WithAugmentation
              { name = "hasql/hasql:hasql-pool"
              , extraDocs = [] : List Schema.DocRef.Type
              , localPathOverride = None Text
              , kind = Some Schema.DependencyKind.ThirdParty
              , source = Some Schema.DependencySource.Hackage
              , scope = Some Schema.DependencyScope.Regular
              , versionConstraint = Some ">=1.2 && <1.5"
              }
          , Schema.Dependency.WithAugmentation
              { name = "shinzui/shibuya:shibuya-core"
              , extraDocs = [] : List Schema.DocRef.Type
              , localPathOverride = None Text
              , kind = Some Schema.DependencyKind.ThirdParty
              , source = Some Schema.DependencySource.Hackage
              , scope = Some Schema.DependencyScope.Regular
              , versionConstraint = Some "^>=0.9.0.0"
              }
          , Schema.Dependency.WithAugmentation
              { name = "shinzui/shibuya-pgmq-adapter:shibuya-pgmq-adapter"
              , extraDocs = [] : List Schema.DocRef.Type
              , localPathOverride = None Text
              , kind = Some Schema.DependencyKind.ThirdParty
              , source = Some Schema.DependencySource.Hackage
              , scope = Some Schema.DependencyScope.Regular
              , versionConstraint = Some "^>=0.14.0.0"
              }
          ]
        }
      , Schema.Package::{
        , name = "keiro-migrations"
        , type = Schema.PackageType.Library
        , language = Schema.Language.Haskell
        , description = Some
            "Embedded PostgreSQL schema migrations and migration runner for Keiro"
        , dependencies =
          [ Schema.Dependency.WithAugmentation
              { name = "hasql/hasql:hasql"
              , extraDocs = [] : List Schema.DocRef.Type
              , localPathOverride = None Text
              , kind = Some Schema.DependencyKind.ThirdParty
              , source = Some Schema.DependencySource.Hackage
              , scope = Some Schema.DependencyScope.Regular
              , versionConstraint = Some ">=1.10 && <1.11"
              }
          , Schema.Dependency.WithAugmentation
              { name = "hasql/hasql:hasql-pool"
              , extraDocs = [] : List Schema.DocRef.Type
              , localPathOverride = None Text
              , kind = Some Schema.DependencyKind.ThirdParty
              , source = Some Schema.DependencySource.Hackage
              , scope = Some Schema.DependencyScope.Test
              , versionConstraint = Some ">=1.2 && <1.5"
              }
          , Schema.Dependency.WithAugmentation
              { name = "shinzui/kiroku:kiroku-store"
              , extraDocs = [] : List Schema.DocRef.Type
              , localPathOverride = None Text
              , kind = Some Schema.DependencyKind.ThirdParty
              , source = Some Schema.DependencySource.Hackage
              , scope = Some Schema.DependencyScope.Test
              , versionConstraint = Some ">=0.7 && <0.8"
              }
          , Schema.Dependency.WithAugmentation
              { name = "shinzui/kiroku:kiroku-store-migrations"
              , extraDocs = [] : List Schema.DocRef.Type
              , localPathOverride = None Text
              , kind = Some Schema.DependencyKind.ThirdParty
              , source = Some Schema.DependencySource.Hackage
              , scope = Some Schema.DependencyScope.Regular
              , versionConstraint = Some "^>=0.3.2.0"
              }
          ]
        }
      , Schema.Package::{
        , name = "keiro-dsl"
        , type = Schema.PackageType.Other "Toolchain"
        , language = Schema.Language.Haskell
        , description = Some
            "Typed-spec (.keiro) toolchain for aggregates, integration, queues, read models, routers, processes, and workflows: parse/check/scaffold/harness/diff. Authoring skill: agents/skills/keiro-dsl-authoring; corpus index: docs/corpus/keiro-dsl-corpus.md"
        , dependencies =
          [ Schema.Dependency.WithAugmentation
              { name = "effectful/effectful:effectful-core"
              , extraDocs = [] : List Schema.DocRef.Type
              , localPathOverride = None Text
              , kind = Some Schema.DependencyKind.ThirdParty
              , source = Some Schema.DependencySource.Hackage
              , scope = Some Schema.DependencyScope.Test
              , versionConstraint = None Text
              }
          , Schema.Dependency.WithAugmentation
              { name = "hasql/hasql:hasql"
              , extraDocs = [] : List Schema.DocRef.Type
              , localPathOverride = None Text
              , kind = Some Schema.DependencyKind.ThirdParty
              , source = Some Schema.DependencySource.Hackage
              , scope = Some Schema.DependencyScope.Test
              , versionConstraint = Some ">=1.10 && <1.11"
              }
          , Schema.Dependency.WithAugmentation
              { name = "hasql/hasql:hasql-transaction"
              , extraDocs = [] : List Schema.DocRef.Type
              , localPathOverride = None Text
              , kind = Some Schema.DependencyKind.ThirdParty
              , source = Some Schema.DependencySource.Hackage
              , scope = Some Schema.DependencyScope.Test
              , versionConstraint = Some ">=1.1 && <1.3"
              }
          , Schema.Dependency.WithAugmentation
              { name = "shinzui/keiki:keiki"
              , extraDocs = [] : List Schema.DocRef.Type
              , localPathOverride = None Text
              , kind = Some Schema.DependencyKind.ThirdParty
              , source = Some Schema.DependencySource.Hackage
              , scope = Some Schema.DependencyScope.Regular
              , versionConstraint = Some ">=0.9 && <0.10"
              }
          , Schema.Dependency.WithAugmentation
              { name = "shinzui/kiroku:kiroku-store"
              , extraDocs = [] : List Schema.DocRef.Type
              , localPathOverride = None Text
              , kind = Some Schema.DependencyKind.ThirdParty
              , source = Some Schema.DependencySource.Hackage
              , scope = Some Schema.DependencyScope.Test
              , versionConstraint = Some ">=0.7 && <0.8"
              }
          , Schema.Dependency.WithAugmentation
              { name = "shinzui/shibuya:shibuya-core"
              , extraDocs = [] : List Schema.DocRef.Type
              , localPathOverride = None Text
              , kind = Some Schema.DependencyKind.ThirdParty
              , source = Some Schema.DependencySource.Hackage
              , scope = Some Schema.DependencyScope.Test
              , versionConstraint = Some "^>=0.9.0.0"
              }
          ]
        }
      , Schema.Package::{
        , name = "keiro-ops"
        , type = Schema.PackageType.Library
        , language = Schema.Language.Haskell
        , description = Some
            "Embeddable operational command tree and command-line interface for Keiro deployments"
        , dependencies =
          [ Schema.Dependency.WithAugmentation
              { name = "effectful/effectful:effectful"
              , extraDocs = [] : List Schema.DocRef.Type
              , localPathOverride = None Text
              , kind = Some Schema.DependencyKind.ThirdParty
              , source = Some Schema.DependencySource.Hackage
              , scope = Some Schema.DependencyScope.Regular
              , versionConstraint = Some ">=2.6 && <2.7"
              }
          , Schema.Dependency.WithAugmentation
              { name = "effectful/effectful:effectful-core"
              , extraDocs = [] : List Schema.DocRef.Type
              , localPathOverride = None Text
              , kind = Some Schema.DependencyKind.ThirdParty
              , source = Some Schema.DependencySource.Hackage
              , scope = Some Schema.DependencyScope.Regular
              , versionConstraint = Some ">=2.6 && <2.7"
              }
          , Schema.Dependency.WithAugmentation
              { name = "hasql/hasql:hasql"
              , extraDocs = [] : List Schema.DocRef.Type
              , localPathOverride = None Text
              , kind = Some Schema.DependencyKind.ThirdParty
              , source = Some Schema.DependencySource.Hackage
              , scope = Some Schema.DependencyScope.Regular
              , versionConstraint = Some ">=1.10 && <1.11"
              }
          , Schema.Dependency.WithAugmentation
              { name = "hasql/hasql:hasql-transaction"
              , extraDocs = [] : List Schema.DocRef.Type
              , localPathOverride = None Text
              , kind = Some Schema.DependencyKind.ThirdParty
              , source = Some Schema.DependencySource.Hackage
              , scope = Some Schema.DependencyScope.Test
              , versionConstraint = Some ">=1.1 && <1.3"
              }
          , Schema.Dependency.WithAugmentation
              { name = "shinzui/kiroku:kiroku-store"
              , extraDocs = [] : List Schema.DocRef.Type
              , localPathOverride = None Text
              , kind = Some Schema.DependencyKind.ThirdParty
              , source = Some Schema.DependencySource.Hackage
              , scope = Some Schema.DependencyScope.Regular
              , versionConstraint = Some ">=0.7 && <0.8"
              }
          ]
        }
      ]
    , dependencies =
      [ "shinzui/kiroku:kiroku-store"
      , "shinzui/kiroku:kiroku-store-migrations"
      , "shinzui/keiki:keiki"
      , "shinzui/shibuya:shibuya-core"
      , "shinzui/shibuya-pgmq-adapter:shibuya-pgmq-adapter"
      , "hasql/hasql:hasql"
      , "hasql/hasql:hasql-pool"
      , "hasql/hasql:hasql-transaction"
      , "effectful/effectful:effectful"
      , "effectful/effectful:effectful-core"
      ]
    , dependencyRefs =
      [ Schema.MoriRef::{
        , namespace = "shinzui"
        , name = "kiroku"
        , kind = Some Schema.MoriArtifactKind.Package
        , key = Some "kiroku-store"
        }
      , Schema.MoriRef::{
        , namespace = "shinzui"
        , name = "kiroku"
        , kind = Some Schema.MoriArtifactKind.Package
        , key = Some "kiroku-store-migrations"
        }
      , Schema.MoriRef::{
        , namespace = "shinzui"
        , name = "keiki"
        , kind = Some Schema.MoriArtifactKind.Package
        , key = Some "keiki"
        }
      , Schema.MoriRef::{
        , namespace = "shinzui"
        , name = "shibuya"
        , kind = Some Schema.MoriArtifactKind.Package
        , key = Some "shibuya-core"
        }
      , Schema.MoriRef::{
        , namespace = "shinzui"
        , name = "shibuya-pgmq-adapter"
        , kind = Some Schema.MoriArtifactKind.Package
        , key = Some "shibuya-pgmq-adapter"
        }
      , Schema.MoriRef::{
        , namespace = "hasql"
        , name = "hasql"
        , kind = Some Schema.MoriArtifactKind.Package
        , key = Some "hasql"
        }
      , Schema.MoriRef::{
        , namespace = "hasql"
        , name = "hasql"
        , kind = Some Schema.MoriArtifactKind.Package
        , key = Some "hasql-pool"
        }
      , Schema.MoriRef::{
        , namespace = "hasql"
        , name = "hasql"
        , kind = Some Schema.MoriArtifactKind.Package
        , key = Some "hasql-transaction"
        }
      , Schema.MoriRef::{
        , namespace = "effectful"
        , name = "effectful"
        , kind = Some Schema.MoriArtifactKind.Package
        , key = Some "effectful"
        }
      , Schema.MoriRef::{
        , namespace = "effectful"
        , name = "effectful"
        , kind = Some Schema.MoriArtifactKind.Package
        , key = Some "effectful-core"
        }
      ]
    , okfBundles =
      [ Schema.OkfBundle::{
        , name = "capabilities"
        , path = "docs/capabilities"
        , profile = Some "docs/capabilities/profile.dhall"
        , okfVersion = "0.2"
        , description = Some
            "What keiro provides today, one concept per capability, with evidence"
        }
      , Schema.OkfBundle::{
        , name = "improvement-requests"
        , path = "docs/improvement-requests"
        , profile = Some "mori/improvement-requests-profile.dhall"
        , okfVersion = "0.1"
        , description = Some
            "Cross-repository improvement requests owned by Keiro"
        }
      , Schema.OkfBundle::{
        , name = "adrs"
        , path = "docs/adr"
        , profile = Some "docs/adr/profile.dhall"
        , okfVersion = "0.1"
        , description = Some "Durable architecture decisions"
        }
      , Schema.OkfBundle::{
        , name = "research"
        , path = "docs/research"
        , profile = Some "docs/research/profile.dhall"
        , okfVersion = "0.1"
        , description = Some
            "Technical research, surveys, audits, evaluations, and design explorations"
        }
      , Schema.OkfBundle::{
        , name = "reviews"
        , path = "docs/reviews"
        , profile = Some "docs/reviews/profile.dhall"
        , okfVersion = "0.2"
        , description = Some
            "Commit-pinned records of adversarial code, API, and release-blocker reviews"
        }
      ]
    }
