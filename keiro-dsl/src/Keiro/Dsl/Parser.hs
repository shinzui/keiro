-- | Stable compatibility facade for the Keiro DSL language frontend.
module Keiro.Dsl.Parser
  ( ParseError,
    ParseFailure (..),
    ParsedSource (..),
    parseSource,
    parseSpec,
    parseSpecText,
    renderParseFailure,
  )
where

import Data.Bifunctor (first)
import Data.Text (Text)
import Keiro.Dsl.Frontend (lowerSurfaceSource, parseSurfaceSource)
import Keiro.Dsl.Frontend.Internal
  ( frontendCompatibilityFailure,
    frontendFailureFromLowering,
  )
import Keiro.Dsl.Grammar (Spec)
import Keiro.Dsl.LanguageVersion

-- | A rendered, line-numbered parse error, ready to print to the user.
type ParseError = Text

-- | Parse a @.keiro@ source. The 'FilePath' is used only as the source name in
-- diagnostics; it need not exist on disk.
parseSpec :: FilePath -> Text -> Either ParseError Spec
parseSpec sourceName input = parsedSpec <$> first renderParseFailure (parseSource sourceName input)

-- | Convenience wrapper for callers without a source name (tests, stdin).
parseSpecText :: Text -> Either ParseError Spec
parseSpecText = parseSpec "<input>"

-- | Parse a source without discarding its selected language contract.
parseSource :: FilePath -> Text -> Either ParseFailure ParsedSource
parseSource sourceName input = do
  surface <- first frontendCompatibilityFailure (parseSurfaceSource sourceName input)
  first (frontendCompatibilityFailure . frontendFailureFromLowering) (lowerSurfaceSource surface)
