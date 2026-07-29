{- | Whole-__workspace__ scaffolding: one invocation plans and emits the
complete generated module set for every member of a service workspace.

The module exists separately from "Keiro.Dsl.ScaffoldRun" for a structural
reason, not a stylistic one: "Keiro.Dsl.Workspace" already imports
'Keiro.Dsl.ScaffoldRun' (its cross-member collision check asks the planner), so
workspace-aware scaffolding cannot live there without a module cycle. Everything
it needs from the single-spec pipeline is imported, never re-implemented — the
refusal gates, the stale comparison, the constraint plan, the drift computation
— so a workspace and a single spec can never disagree about what is legal.

Two properties are true __by construction__ rather than by test:

  * Emission runs once over the workspace's /merged/ 'Spec'
    ('Keiro.Dsl.Workspace.wsMergedSpec'), so the context-level artifacts — the
    structural projection facade and the replay-audit assembly — are emitted
    exactly once from the complete graph. Concatenating per-member scaffolds
    would emit them N times from N partial graphs, which is the defect this
    module fixes.

  * A one-member workspace produces exactly the single-file module set, in the
    same order, with identical bytes and identical metadata, because it calls
    the same emitters with the same inputs.

History is workspace-keyed ("Keiro.Dsl.WorkspaceRecord"). Each module remembers
which member produced it, so moving an aggregate between member files is an
/ownership move/ rather than a stale-plus-new pair.

Atomicity here means what it means for a single spec: every refusal is computed
before the first output byte changes. There are no staged temp-file writes.
-}
module Keiro.Dsl.WorkspaceScaffold (
    -- * Planning
    ModuleProvenance (..),
    WorkspacePlan (..),
    planWorkspaceScaffold,
    planWorkspaceScaffoldWithGoldens,
    provenanceOwner,

    -- * Golden payload roots
    goldenRootDivergence,
) where

import Data.List (nub)
import Data.Text qualified as T
import Keiro.Dsl.Goldens (GoldenPayload)
import Keiro.Dsl.Grammar
import Keiro.Dsl.Harness (harnessForWithGoldens, harnessProcess, harnessReadModel, harnessRouter, harnessWorkflow)
import Keiro.Dsl.Scaffold
import Keiro.Dsl.ScaffoldRun (Refusal (..), pureRefusals)
import Keiro.Dsl.Validate (nodeIdentity)
import Keiro.Dsl.Workspace (WorkspaceMember (..), WorkspaceSpec (..), declarationOwner, nodeOwner)
import System.Directory (doesFileExist)
import System.FilePath (takeDirectory, (</>))

--------------------------------------------------------------------------------
-- Planning
--------------------------------------------------------------------------------

{- | Which member file produced an emitted module. 'ContextLevel' means the
module belongs to the whole service rather than to any one member: the
structural projection facade, the replay-audit assembly, and any binding
skeleton shared by declarations owned by different members.
-}
data ModuleProvenance
    = ContextLevel
    | MemberOwned !FilePath
    deriving stock (Eq, Ord, Show)

-- | The owning member path, or 'Nothing' for a context-level module.
provenanceOwner :: ModuleProvenance -> Maybe FilePath
provenanceOwner ContextLevel = Nothing
provenanceOwner (MemberOwned path) = Just path

{- | The complete, refusal-free write set for one whole-workspace scaffold, with
each module's producing member attached.
-}
data WorkspacePlan = WorkspacePlan
    { wpWorkspace :: !WorkspaceSpec
    , wpContext :: !Context
    , wpGoldenRoot :: !FilePath
    {- ^ The one golden-payload root for the whole workspace. Carried here so
    execution can refuse a member-adjacent fixture the root lacks before it
    writes anything.
    -}
    , wpModules :: ![(ScaffoldModule, ModuleProvenance)]
    }
    deriving stock (Eq, Show)

-- | 'planWorkspaceScaffoldWithGoldens' with no golden payload fixtures.
planWorkspaceScaffold :: FilePath -> Context -> WorkspaceSpec -> Either [Refusal] WorkspacePlan
planWorkspaceScaffold = planWorkspaceScaffoldWithGoldens []

{- | Plan the whole workspace: build the merged module set once, attribute each
module to its owning member, then run every pure refusal gate over the complete
set. A refusal carries no write set, so it cannot be executed by accident.

Because the gates see the whole workspace, a case-folded module-path collision
between two members is caught here, with both member files named in the
collision's origins.
-}
planWorkspaceScaffoldWithGoldens ::
    [GoldenPayload] ->
    FilePath ->
    Context ->
    WorkspaceSpec ->
    Either [Refusal] WorkspacePlan
planWorkspaceScaffoldWithGoldens goldens goldenRoot ctx workspace =
    case pureRefusals ctx merged (map fst tagged) of
        [] ->
            Right
                WorkspacePlan
                    { wpWorkspace = workspace
                    , wpContext = ctx
                    , wpGoldenRoot = goldenRoot
                    , wpModules = tagged
                    }
        refusals -> Left refusals
  where
    merged = wsMergedSpec workspace
    tagged = workspaceModules goldens ctx workspace

{- | The tagged module set, in exactly the order
'Keiro.Dsl.ScaffoldRun.scaffoldModulesWithGoldens' produces for the merged spec.

Attribution is structural, never a re-parse of the human-readable @origin@
string: structural modules carry the mapped declarations they were emitted for
('scaffoldStructuralOwners') and nodes carry their own identity
('nodeIdentity'), both of which the workspace's ownership index resolves to a
member file.
-}
workspaceModules :: [GoldenPayload] -> Context -> WorkspaceSpec -> [(ScaffoldModule, ModuleProvenance)]
workspaceModules goldens ctx workspace =
    [attributed (declarationProvenance names) m | (m, names) <- scaffoldStructuralOwners ctx merged]
        <> [attributed ContextLevel m | m <- scaffoldReplayAudit ctx merged]
        <> concat
            [ map (attributed (nodeProvenance node)) (emittersFor node)
            | node <- specNodes merged
            ]
  where
    merged = wsMergedSpec workspace
    ownership = wsOwnership workspace

    emittersFor node = case node of
        NAggregate aggregate -> scaffoldAggregate ctx merged aggregate <> harnessForWithGoldens goldens ctx merged aggregate
        NProcess process -> scaffoldProcess ctx process <> harnessProcess ctx process
        NRouter router -> scaffoldRouter ctx router <> harnessRouter ctx router
        NContract contract -> scaffoldContract ctx contract
        NIntake intake -> scaffoldIntake ctx intake
        NPublisher publisher -> scaffoldPublisher ctx publisher
        NWorkqueue workqueue -> scaffoldWorkqueue ctx workqueue
        NReadModel readModel -> scaffoldReadModel ctx readModel <> harnessReadModel ctx readModel
        NWorkflow workflow -> harnessWorkflow ctx workflow
        NEmit _ -> []
        NPgmqDispatch _ -> []
        NOperation _ -> []

    nodeProvenance node =
        let (kind', name, _) = nodeIdentity node
         in maybe ContextLevel (MemberOwned . fst) (nodeOwner ownership kind' name)

    -- A structural module belongs to a member only when every declaration it
    -- was emitted for has the same owner. A binding skeleton shared by
    -- declarations from two members belongs to neither: attributing it to one
    -- would make the other member's obligations look like they moved whenever
    -- the map iteration order changed.
    declarationProvenance names = case nub owners of
        [owner] | length owners == length names -> MemberOwned owner
        _ -> ContextLevel
      where
        owners = [owner | name <- names, Just (owner, _) <- [declarationOwner ownership "mapped" name]]

    -- Name the producing member in refusal messages, so a cross-member path
    -- collision says which files claimed the path. `origin` is metadata read
    -- only by refusal rendering: it never reaches the module text, the record,
    -- or the build manifest. A single-member workspace adds no prefix, which is
    -- what keeps it identical to the single-file path down to this field.
    attributed provenance m = (annotate provenance m, provenance)
    annotate (MemberOwned path) m
        | length (wsMembers workspace) > 1 = m{origin = T.pack path <> ": " <> origin m}
    annotate _ m = m

--------------------------------------------------------------------------------
-- Golden payload roots
--------------------------------------------------------------------------------

{- | Refuse when a member has golden payload fixtures beside it that the
workspace's single golden root does not have.

Golden fixtures are keyed @\<context\>\/\<Aggregate\>\/\<Event\>.v\<N\>.json@ —
by aggregate, and an aggregate has exactly one owner across a workspace — so one
root per workspace cannot collide, while a per-member root would make a
fixture's location depend on which file currently owns the aggregate and break
the rule that an ownership move is not a content change.

Without this check the failure would be silent: a member-adjacent fixture the
workspace root lacks is simply not found, the harness embeds a synthesized weak
stand-in instead of the file-owned payload, and generated bytes change with no
diagnostic at all.
-}
goldenRootDivergence :: FilePath -> WorkspaceSpec -> IO [Refusal]
goldenRootDivergence workspaceRoot workspace = do
    stranded <- concat <$> traverse strandedFor (wsMembers workspace)
    pure [GoldenRootDivergence workspaceRoot stranded | not (null stranded)]
  where
    manifestDir = takeDirectory (wsManifestPath workspace)
    strandedFor member = concat <$> traverse (check member) (upcastFixtures (wmSpec member))
    check member relative = do
        let memberRoot = manifestDir </> takeDirectory (wmPath member) </> "golden-payloads"
        besideMember <- firstExisting memberRoot relative
        case besideMember of
            Nothing -> pure []
            Just found -> do
                atRoot <- firstExisting workspaceRoot relative
                pure (case atRoot of Nothing -> [found]; Just _ -> [])
    -- Mirror the two shapes `loadGoldenPayloads` accepts: a root holding
    -- context directories, or a root that already is the context directory.
    firstExisting root relative = firstJustM [root </> relative, root </> dropContext relative]
    dropContext relative = case break (== '/') relative of
        (_, '/' : rest) -> rest
        _ -> relative
    firstJustM [] = pure Nothing
    firstJustM (path : rest) = do
        exists <- doesFileExist path
        if exists then pure (Just path) else firstJustM rest

{- | The @\<context\>\/\<Aggregate\>\/\<Event\>.v\<N\>.json@ fixture paths a
spec's declared upcasters would load, in spec order.
-}
upcastFixtures :: Spec -> [FilePath]
upcastFixtures spec =
    [ T.unpack (specContext spec) </> T.unpack (aggName aggregate) </> fixtureName event sourceVersion
    | NAggregate aggregate <- specNodes spec
    , event <- aggEvents aggregate
    , Just (sourceVersion, _) <- [evUpcastFrom event]
    ]
  where
    fixtureName event sourceVersion = T.unpack (evName event) <> ".v" <> show sourceVersion <> ".json"
