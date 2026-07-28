--| Shared research-document profile. Bump the tag and semantic hash together when upgrading.
let Profiles =
      https://raw.githubusercontent.com/shinzui/okf-profiles/v0.6.0/package.dhall
        sha256:cedb24eb0e65fcde48c49e12da748735ac5319053cd471def5c109d9ceff4587

in  Profiles.documentation.researchDocuments
