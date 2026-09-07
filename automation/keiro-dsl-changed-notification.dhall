-- Tell shinzui/keiro-syntax when the keiro-dsl surface it mirrors has moved.
--
-- The signal fires on the CHANGESET, not on a release: keiro-syntax tracks the
-- grammar, parser, and pretty-printer as source, and needs to know a surface
-- moved when it moves -- not when the next version ships.
--
-- Registered as `keiro-dsl-changed-notification` rather than `default`. It was
-- this repository's root mori.automation.dhall until automation/ became the
-- layout; the siblings that have migrated (shinzui/shikumi, shinzui/okf,
-- shinzui/baikai) carry no `default` at all, and a rule named for what it does
-- survives the next one being added.
--
-- Kept separate from automation/release.dhall rather than merged into a
-- directory: a directory is one automation split across files and every file
-- must agree on `queued`. That one shells out and wants `queued = True`; this
-- signal must not sit behind a recording in that queue.
let Schema =
      https://raw.githubusercontent.com/shinzui/mori-schema/1f70781427426c09673d46f8e6733b7e7d0abedc/package.dhall
        sha256:3b79aae9216456678300441ca8616b64a4b4fa520a1286dfcc418f60899d5d4a

in  Schema.Automation::{
    , events =
      [ Schema.EventSelector.ChangesetSelector Schema.ChangesetSelector::{
        , name = "keiro-dsl-surface"
        , paths =
          [ "keiro-dsl/src/Keiro/Dsl/Parser.hs"
          , "keiro-dsl/src/Keiro/Dsl/Grammar.hs"
          , "keiro-dsl/src/Keiro/Dsl/PrettyPrint.hs"
          , "keiro-dsl/test/fixtures/**/*.keiro"
          ]
        , branches = [ "master" ]
        }
      ]
    , reactions =
      [ Schema.Reaction::{
        , name = "notify-keiro-syntax"
        , on = [ "keiro-dsl-surface" ]
        , actions =
          [ Schema.ReactionAction.Signal Schema.SignalAction::{
            , signalType = "KeiroDslSurfaceChanged"
            , targets = [ "shinzui/keiro-syntax" ]
            , payload =
              [ { mapKey = "commit", mapValue = "{{changeset.id}}" }
              , { mapKey = "subject", mapValue = "{{changeset.subject}}" }
              , { mapKey = "timestamp", mapValue = "{{changeset.timestamp}}" }
              ]
            }
          ]
        }
      ]
    , execution = Schema.ExecutionPolicy::{ allowLocal = True }
    }
