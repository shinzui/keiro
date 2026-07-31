--| Shared ADR profile. Bump the tag and semantic hash together when upgrading.
--
-- `supersedes`, `supersededBy`, and `originatingPlan` are reclassified from the
-- upstream `recommended` list to `optional`: they are provenance whose absence
-- is ordinary, not deficient. A live decision that has never been superseded has
-- nothing to record, and the pre-plan ADRs predate originating-plan tracking.
-- `optional` still enforces every constraint the upstream rule declares --
-- including the ADR handle references -- whenever the field is present.
let Profiles =
      https://raw.githubusercontent.com/shinzui/okf-profiles/v0.7.0/package.dhall
        sha256:3a785b2ee66301e2bcd6466352e9480e71b7fafdca62256b4a2038cace5d0bb8

let base = Profiles.documentation.architectureDecisions

in  base
    //  { frontmatter =
            base.frontmatter
        //  { recommended = [] : List Profiles.FieldRule.Type
            , optional = base.frontmatter.recommended
            }
        }
