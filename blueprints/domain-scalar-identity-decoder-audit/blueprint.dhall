let S =
      https://raw.githubusercontent.com/shinzui/seihou-schema/49ff1e5b353b171b1b52946f478623ee4423ea93/package.dhall
        sha256:cadacb688dd31ec39feb7f2fe599973a1ad58ef8fcc8ed1100bf3da22a1222cb

in  S.Blueprint::{
    , name = "domain-scalar-identity-decoder-audit"
    , version = Some "0.2.0"
    , description = Some
        "Audit and remediate domain scalars, identity authority, and owned decoders with exhaustive source-bound classification and behavioral acceptance."
    , prompt = ./prompt.md as Text
    , vars =
      [ S.VarDecl::{
        , name = "audit.stage"
        , type = "text"
        , default = Some "all"
        , description = Some "Stop at the verified classification baseline or run all audit stages."
        , validation = Some "^(classification|all)$"
        }
      ]
    , allowedTools = Some
        [ "Bash(cabal *)"
        , "Bash(ghc *)"
        , "Bash(just *)"
        , "Bash(rg *)"
        , "Bash(git status *)"
        , "Bash(git diff *)"
        , "Bash(git log *)"
        , "Bash(git show *)"
        , "Bash(git ls-files *)"
        , "Bash(git rev-parse *)"
        , "Bash(mori path *)"
        , "Bash(mori registry list *)"
        , "Bash(mori registry search *)"
        , "Bash(mori registry show *)"
        , "Bash(mori registry docs *)"
        , "Bash(nix develop *)"
        , "Bash(jq *)"
        , "Bash(shasum *)"
        ]
    , tags = [ "haskell", "domain-modeling", "identity", "decoding", "audit" ]
    }
