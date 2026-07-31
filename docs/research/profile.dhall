--| Shared research-document profile. Bump the tag and semantic hash together when upgrading.
--
-- The upstream `recommended` fields -- `sources`, `reviews`, `relatedDecisions`,
-- `relatedPlans`, and `supersedes` -- are reclassified as `optional`: they are
-- provenance and linkage whose absence is ordinary rather than deficient for
-- this bundle, whose documents are internal design records rather than cited
-- surveys. `optional` still enforces every constraint the upstream rule
-- declares -- including the RES and ADR handle references and the review-entry
-- shape -- whenever the field is present.
let Profiles =
      https://raw.githubusercontent.com/shinzui/okf-profiles/v0.7.0/package.dhall
        sha256:3a785b2ee66301e2bcd6466352e9480e71b7fafdca62256b4a2038cace5d0bb8

let base = Profiles.documentation.researchDocuments

in  base
    //  { frontmatter =
            base.frontmatter
        //  { recommended = [] : List Profiles.FieldRule.Type
            , optional = base.frontmatter.recommended
            }
        }
