-- Turn an observed release tag into the one immutable Project release fact mori
-- keeps for shinzui/keiro.
--
-- The same shape shinzui/shikumi and shinzui/baikai use. Keiro cuts one tag per
-- package -- seven at 0.15.0.0 -- so it needs the scripts/record-release.sh
-- wrapper for the same reason they do: mori's ref globs understand `*` and `**`
-- and nothing else, so no pattern can say "keiro- followed by a version and no
-- further package segment". shinzui/okf uses the unwrapped form from `mori help
-- registry-releases` only because it cuts a single tag per release.
--
-- The version recorded is the tag text minus the `keiro-` prefix -- `0.15.0.0`,
-- not `keiro-0.15.0.0` -- which is what the 0.1.0.0-0.15.0.0 backfill already
-- put on this project's stream. Mori stores versions as opaque single-line
-- strings and never parses or compares them, so nothing enforces that
-- agreement; it is a convention this repo has to keep on purpose.
--
-- Registered as its own named automation (`--name release`) rather than merged
-- into the existing mori.automation.dhall: a directory is one automation split
-- across files and every file must agree on `queued`, `execution`, `consent`
-- and `signalBounds`. This rule shells out and wants `queued = True`, while the
-- default automation's KeiroDslSurfaceChanged signal must not sit behind a
-- recording in that queue.
--
-- Pinned to mori-schema 9899d45 rather than the 1f70781 that
-- mori.automation.dhall carries: `Automation.queued` does not exist in 1f70781.
-- Not the newer 92dd706 either -- that adds `SignalAction.cascade`, which this
-- file has no use for.
let Schema =
      https://raw.githubusercontent.com/shinzui/mori-schema/9899d4544790da7120e8150c73e56cb53fe35191/package.dhall
        sha256:4024df757a0178e37fb0b5f04d7deb284dc3ee9bfea89a6610b793338101e284

in  Schema.Automation::{
    , events =
      [ Schema.EventSelector.RefSelector Schema.RefSelector::{
        , name = "keiro-release-tag"
        ,
          -- Every release tag in the repo, not only the umbrella one; see the
          -- header. scripts/record-release.sh exits quietly on the six sibling
          -- package tags.
          refPatterns = [ "keiro-*" ]
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
      -- A release cut pushes seven tags in the same second, so this automation
      -- is triggered seven times at once. Recording a version twice is already
      -- safe -- the first committed release time and source win -- but
      -- serializing keeps the seven invocations from racing each other into the
      -- same Project stream.
      queued = True
    , execution = Schema.ExecutionPolicy::{ allowLocal = True }
    }
