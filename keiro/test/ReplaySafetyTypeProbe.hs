{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeOperators #-}

module ReplaySafetyTypeProbe where

import Effectful (Eff, IOE, (:>))
import Effectful.Error.Static (Error)
import Keiki.Core (BoolAlg, HsPred, RegFile)
import Keiro
import Kiroku.Store.Effect (Store)
import Kiroku.Store.Error (StoreError)

data ProbeCommand = ProbeAdd Int
    deriving stock (Eq, Show)

data ProbeEvent = ProbeAdded Int
    deriving stock (Eq, Show)

data ProbeState = ProbeCounting
    deriving stock (Eq, Ord, Show, Enum, Bounded)

type ProbeEventStream =
    EventStream (HsPred '[] ProbeCommand) '[] ProbeState ProbeCommand ProbeEvent

bareProbeEventStream :: ProbeEventStream
bareProbeEventStream = error "type-only fixture; never evaluated"

badRunCommand ::
    ( IOE :> es
    , Store :> es
    , Error StoreError :> es
    , BoolAlg (HsPred '[] ProbeCommand) (RegFile '[], ProbeCommand)
    ) =>
    Eff es (Either CommandError (CommandResult ProbeEventStream))
badRunCommand =
    runCommand
        defaultRunCommandOptions
        bareProbeEventStream
        (stream "type-guard-probe" :: Stream ProbeEventStream)
        (ProbeAdd 1)
