-- | Compiled public-API adoption example over the shared note fixture.
module GuardedCatalogExample
  ( module GuardedCatalogFixture,
    NoteRefusal (..),
    EnsureNoteError (..),
    ensureStateNoteExample,
    noteGuard,
  )
where

import GuardedCatalogFixture
import Keiro
import Keiro.Prelude
import Keiro.Projection
import Keiro.Test.Postgres (StoreRunner (..))
import Kiroku.Store qualified as Store
import "hasql-transaction" Hasql.Transaction qualified as Tx

data NoteRefusal = ExistingNote Text | GuardConfigurationFault Text
  deriving stock (Eq, Show)

data EnsureNoteError
  = EnsureStoreFault Store.StoreError
  | EnsureCommandFault CommandError
  | EnsureGuardFault Text
  | EnsureCatalogFault (DomainProjectionCommandOutcome NoteStream NoteEvent Text Text)
  deriving stock (Eq, Show)

-- Only ExistingNote maps to reuse. Framework faults and a missing/unsupported
-- binding remain distinct failures. No rolled-back position escapes this API.
ensureStateNoteExample :: StoreRunner -> Note -> IO (Either EnsureNoteError (Text, Bool))
ensureStateNoteExample (StoreRunner run) note = do
  outcome <- run (runDomainCommandWithCatalogProjectionsGuarded defaultRunCommandOptions (handler 1) (stream (noteId note)) (CreateNote (notePayload note)) catalog commandSet (noteGuard note))
  pure $ case outcome of
    Right (Right (PreconditionRefused (ExistingNote winner))) -> Right (winner, False)
    Right (Right (CatalogCommandOutcome (DomainProjectionCommandApplied DomainCommandOutcome {decision = DomainAccepted {}}))) -> Right (noteId note, True)
    Left fault -> Left (EnsureStoreFault fault)
    Right (Left fault) -> Left (EnsureCommandFault fault)
    Right (Right (PreconditionRefused (GuardConfigurationFault detail))) -> Left (EnsureGuardFault detail)
    Right (Right (CatalogCommandOutcome other)) -> Left (EnsureCatalogFault other)

noteGuard :: Note -> CatalogPreconditionContext -> Tx.Transaction (Either NoteRefusal ())
noteGuard note context = case catalogPreconditionBindings context of
  [binding] | binding ^. #writeGroupId == identityGroup && binding ^. #writeRevisionId == Nothing ->
    case resolvePhysicalTarget identityTarget (binding ^. #writePhysicalTargets) of
      Nothing -> pure (Left (GuardConfigurationFault "identity target missing"))
      Just table -> do
        winner <- Tx.statement (notePayload note) (identityLookup table)
        pure (maybe (Right ()) (Left . ExistingNote) winner)
  _ -> pure (Left (GuardConfigurationFault "unsupported identity serving binding"))
