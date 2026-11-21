let S =
      https://raw.githubusercontent.com/shinzui/seihou-schema/49ff1e5b353b171b1b52946f478623ee4423ea93/package.dhall
        sha256:cadacb688dd31ec39feb7f2fe599973a1ad58ef8fcc8ed1100bf3da22a1222cb

in  S.Blueprint::{
    , name = "keiro-ui-ops"
    , version = Some "0.1.0"
    , description = Some
        "Connect keiro-ui to application ops with DSL-generated aggregate inspectors and a checked service topology."
    , prompt = ./prompt.md as Text
    , allowedTools = Some
        [ "Bash(rg *)", "Bash(mori path *)", "Bash(nix develop *)", "Bash(cabal *)", "Bash(just *)", "Bash(keiro-dsl *)", "Bash(curl *)", "Bash(jq *)", "Bash(cmp *)" ]
    , tags = [ "haskell", "keiro", "keiro-ui", "operations", "topology" ]
    }
