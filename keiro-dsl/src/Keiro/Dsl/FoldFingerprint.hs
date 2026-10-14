{-# OPTIONS_GHC -Werror=incomplete-patterns #-}

-- | Public frozen fold identity API. Comparison evidence remains private.
module Keiro.Dsl.FoldFingerprint
  ( FoldSurfaceError (..),
    renderFoldSurfaceError,
    aggregateFoldFingerprintForService,
    aggregateFoldSurfaceForService,
  )
where

import Keiro.Dsl.FoldEvidence
