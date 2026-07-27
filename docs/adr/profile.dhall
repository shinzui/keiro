--| Shared ADR profile. Bump the tag and semantic hash together when upgrading.
let Profiles =
      https://raw.githubusercontent.com/shinzui/okf-profiles/v0.4.0/package.dhall
        sha256:39e79b65672439cde9c1271e3d92abf68ba1e2427541598e0d04de23e741f0cb

in  Profiles.documentation.architectureDecisions
