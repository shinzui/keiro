let Schema =
      https://raw.githubusercontent.com/shinzui/mori-schema/1f70781427426c09673d46f8e6733b7e7d0abedc/package.dhall
        sha256:3b79aae9216456678300441ca8616b64a4b4fa520a1286dfcc418f60899d5d4a

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
      ]
    , dependencies =
      [ "shinzui/kiroku"
      , "shinzui/keiki"
      , "shinzui/shibuya"
      , "hasql/hasql"
      , "effectful/effectful"
      ]
    }
