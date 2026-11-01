let S =
      https://raw.githubusercontent.com/shinzui/seihou-schema/49ff1e5b353b171b1b52946f478623ee4423ea93/package.dhall
        sha256:cadacb688dd31ec39feb7f2fe599973a1ad58ef8fcc8ed1100bf3da22a1222cb

in  S.Blueprint::{
    , name = "domain-scalar-identity-decoder-audit"
    , version = Some "0.1.0"
    , description = Some
        "Audit and remediate domain scalars, identity authority, and owned decoders with exhaustive source-bound classification and behavioral acceptance."
    , prompt = ./prompt.md as Text
    , allowedTools = Some [ "Bash(cabal *)", "Bash(just *)", "Bash(rg *)" ]
    , tags = [ "haskell", "domain-modeling", "identity", "decoding", "audit" ]
    }
