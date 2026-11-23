let S =
      https://raw.githubusercontent.com/shinzui/seihou-schema/49ff1e5b353b171b1b52946f478623ee4423ea93/package.dhall
        sha256:cadacb688dd31ec39feb7f2fe599973a1ad58ef8fcc8ed1100bf3da22a1222cb

in  S.Blueprint::{
    , name = "keiro-adoption"
    , version = Some "0.1.0"
    , description = Some
        "Qualify a Keiro 0.26+ cohort, plan project-specific runtime and DSL adoption, and run the domain audit through staged acceptance."
    , prompt = ./prompt.md as Text
    , vars =
      [ S.VarDecl::{
        , name = "adoption.mode"
        , type = "text"
        , default = Some "prepare"
        , description = Some "Prepare the verified cohort, plans and baseline audit, or implement them through final acceptance."
        , validation = Some "^(prepare|implement)$"
        }
      ]
    , allowedTools = Some
        [ "Bash(rg *)"
        , "Bash(git status *)"
        , "Bash(git diff *)"
        , "Bash(git log *)"
        , "Bash(git show *)"
        , "Bash(git ls-remote *)"
        , "Bash(mori path *)"
        , "Bash(mori registry list *)"
        , "Bash(mori registry search *)"
        , "Bash(mori registry show *)"
        , "Bash(mori registry docs *)"
        , "Bash(nix develop *)"
        , "Bash(cabal *)"
        , "Bash(jq *)"
        , "Bash(seihou --version)"
        , "Bash(seihou list *)"
        , "Bash(seihou validate-blueprint *)"
        , "Bash(seihou agent --debug migrate *)"
        , "Bash(seihou agent migrate *)"
        , "Bash(seihou agent run *)"
        ]
    , tags = [ "haskell", "keiro", "adoption", "migration", "domain-modeling" ]
    }
