-- Turn an observed release tag into the one immutable Project release fact mori
-- keeps for shinzui/keiro.
--
-- Keiro cuts one tag per package -- seven at 0.16.0.0 -- and only the umbrella
-- `keiro-<version>` tag carries the project's release. `refRegexes` states that
-- directly: a whole-input POSIX extended regex, so `keiro-0.16.0.0` matches and
-- `keiro-core-0.16.0.0` does not. Before mori grew that field this was
-- inexpressible here -- ref globs understand `*` and `**` and nothing else --
-- and the narrowing lived in scripts/record-release.sh, which fired on all
-- seven tags and exited quietly on six. The selector now fires exactly once per
-- release and the script no longer guards.
--
-- The version recorded is the tag text minus the `keiro-` prefix -- `0.16.0.0`,
-- not `keiro-0.16.0.0` -- which is what the 0.1.0.0-0.15.0.0 backfill already
-- put on this project's stream. Mori stores versions as opaque single-line
-- strings and never parses or compares them, so nothing enforces that
-- agreement; it is a convention this repo has to keep on purpose. Regex capture
-- groups create no template variables, so `{{ref.name}}` is still the whole
-- tag and the strip stays in the script.
--
-- Registered as its own named automation (`--name release`) rather than merged
-- into automation/keiro-dsl-changed-notification.dhall: a directory is one
-- automation split across files and every file must agree on `queued`,
-- `execution`, `consent` and `signalBounds`. This rule shells out and wants
-- `queued = True`, while that config's KeiroDslSurfaceChanged signal must not
-- sit behind a recording in the same queue.
--
-- Pinned to mori-schema 7904371, the commit that adds `RefSelector.refRegexes`
-- (and `ChangesetSelector.pathRegexes`). This is the commit the current mori
-- binary embeds, so the import resolves without touching the network.
let Schema =
      https://raw.githubusercontent.com/shinzui/mori-schema/7904371c3ee1f592b427167e213cb1baa835de2c/package.dhall
        sha256:4b3730d985a19575278e3f155d98d5a60992e5f51b4f9223d390ef13e513e3c4

in  Schema.Automation::{
    , events =
      [ Schema.EventSelector.RefSelector Schema.RefSelector::{
        , name = "keiro-release-tag"
        ,
          -- Whole-input match. `[.]` for the literal dot: a Dhall
          -- double-quoted string would otherwise need the backslash doubled.
          refRegexes = [ "keiro-[0-9]+([.][0-9]+)*" ]
        , kinds = [ "tag" ]
        }
      ]
    , reactions =
      [ Schema.Reaction::{
        , name = "record-keiro-release"
        , on = [ "keiro-release-tag" ]
        , actions =
          [ Schema.ReactionAction.RunCommand Schema.RunCommandAction::{
            , command = "./scripts/record-release.sh"
            , args = [ "{{ref.name}}" ]
            ,
              -- Not the 600-second default, which would hold the FIFO group for
              -- ten minutes on a hung database -- but not the 60 seconds
              -- shinzui/shikumi uses either. Every RunCommand is executed as
              -- `nix develop --command`, and that entry, not the single
              -- `mori registry release record` against a local Postgres,
              -- dominates: observed successful runs here take 5-15s, and a
              -- backlog of ref observations timed out six reactions at 60s
              -- while the nix eval cache was cold and contended. 300s is still
              -- a bound worth having and stops costing correctness.
              timeout = Some +300
            }
          ]
        }
      ]
    ,
      -- A release cut now triggers this once, not seven times, so the original
      -- reason for queueing is gone. It is kept for the replay case:
      -- `mori automate reset-checkpoint --to-root` re-observes every umbrella
      -- tag in the repo's history at once, and serializing keeps those
      -- invocations from racing each other into the same Project stream.
      -- Re-recording a version is already safe -- the first committed release
      -- time and source win -- so this is about avoiding contention, not
      -- correctness.
      queued = True
    , execution = Schema.ExecutionPolicy::{ allowLocal = True }
    }
