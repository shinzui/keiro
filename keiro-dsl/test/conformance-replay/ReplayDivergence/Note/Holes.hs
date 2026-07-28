{-# LANGUAGE BlockArguments #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE QualifiedDo #-}
{-# LANGUAGE TypeApplications #-}

-- This is a HAND-OWNED hole module. keiro-dsl creates it once and never
-- overwrites it. Fill the transducer body (and any other holes) against the
-- generated signatures, then run the harness to confirm behaviour.
module ReplayDivergence.Note.Holes (
    noteTransducer,
    dishonestWireNoteWritten,
) where

import Data.Text (Text)
import Generated.ReplayDivergence.Note.Domain
import Keiki.Builder ((=:))
import Keiki.Builder qualified as B
import Keiki.Core (HsPred, SymTransducer, WireCtor (..))

-- HOLE: the transducer body. Reproduce the structure below, replacing each
-- `-- HOLE` line with the keiki symbolic operators it describes.
noteTransducer ::
    SymTransducer
        (HsPred NoteRegs NoteCommand)
        NoteRegs
        NoteVertex
        NoteCommand
        NoteEvent
noteTransducer =
    B.buildTransducer NoteEmpty initialNoteRegs isTerminal do
        B.from NoteEmpty do
            B.onCmd inCtorWriteNote $ \d -> B.do
                B.slot @"note" =: d.noteText
                B.emit
                    emitWire
                    NoteWrittenTermFields
                        { noteText = d.noteText
                        , echo = d.echo
                        }
                B.goto NoteRecorded
  where
    isTerminal = \case
        NoteRecorded -> True
        _ -> False

-- The honest generated wire ctor sits behind an indirection that the mutation
-- test changes in one line.
emitWire :: WireCtor NoteEvent (Text, (Text, ()))
emitWire = wireNoteWritten

-- This dormant dishonest ctor copies echo into both event fields. Unlike a
-- simple swap, the rewrite is idempotent: replay's event rebuild check accepts
-- the observed event, then the recovered command writes echo into the note
-- register. Only the generated forward/replay register comparison catches it.
dishonestWireNoteWritten :: WireCtor NoteEvent (Text, (Text, ()))
dishonestWireNoteWritten =
    wireNoteWritten
        { wcBuild = wcBuild wireNoteWritten . duplicateEcho
        }

duplicateEcho :: (Text, (Text, ())) -> (Text, (Text, ()))
duplicateEcho (_noteText, (echo, ())) = (echo, (echo, ()))
