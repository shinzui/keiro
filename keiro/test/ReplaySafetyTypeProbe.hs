module ReplaySafetyTypeProbe where

import Keiro

bareProbeEventStream :: EventStream phi rs state command event
bareProbeEventStream = error "type-only fixture; never evaluated"

badRunCommand =
    runCommand
        defaultRunCommandOptions
        bareProbeEventStream
