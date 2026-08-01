-- | Whole-service evolution findings enriched with workspace source ownership.
--
-- The ordinary differ remains the single authority for compatibility. This module
-- runs it over the two composed 'WorkspaceSpec' graphs and adds only source
-- citations. Consequently, file layout can never manufacture, suppress, or demote
-- a wire finding.
module Keiro.Dsl.WorkspaceDiff
  ( OwnedSite (..),
    WorkspaceChange (..),
    WorkspaceMeta (..),
    WorkspaceDiffReport,
    workspaceDiffReport,
    diffWorkspaces,
    renderWorkspaceFinding,
  )
where

import Control.Applicative ((<|>))
import Data.Char (isSpace)
import Data.List (find)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Keiro.Dsl.Diff (Change (..), ChangeKind (..), advisoryAt, consumerBuildContext, diffServices, sourceLanguageChange)
import Keiro.Dsl.DiffReport (OwnedSite (..), WorkspaceChange (..), WorkspaceDiffReport, WorkspaceMeta (..), renderFinding, workspaceDiffReport)
import Keiro.Dsl.Grammar (Loc (..), Name, Placement (..))
import Keiro.Dsl.LanguageVersion (SourceLanguage (..))
import Keiro.Dsl.Validate (DiagnosticCode (..))
import Keiro.Dsl.Workspace (OwnershipIndex (..), WorkspaceMember (..), WorkspaceSpec (..), checkedWorkspace)

-- | Diff two composed service graphs and cite every participant we can resolve.
diffWorkspaces :: WorkspaceSpec -> WorkspaceSpec -> [WorkspaceChange]
diffWorkspaces old new =
  memberLanguageChanges old new
    <> map annotate (diffServices (checkedWorkspace old) (checkedWorkspace new))
    <> ownershipMoveChanges old new
    <> authorityChanges old new
  where
    annotate change =
      WorkspaceChange
        { wcChange = change,
          wcDeclarationSite =
            ownedSiteForName new (declarationName kind)
              <|> ownedSiteForName old (declarationName kind),
          wcUseSites =
            [ (path, ownedSiteForName new (pathRoot path) <|> ownedSiteForName old (pathRoot path))
            | path <- ckPaths kind
            ]
        }
      where
        kind = changeKind change

memberLanguageChanges :: WorkspaceSpec -> WorkspaceSpec -> [WorkspaceChange]
memberLanguageChanges old new =
  [ WorkspaceChange
      { wcChange = change,
        wcDeclarationSite = Just (OwnedSite path (sourceLine (wmSourceLanguage newMember))),
        wcUseSites = []
      }
  | (path, newMember) <- Map.toAscList newByPath,
    Just oldMember <- [Map.lookup path oldByPath],
    change <- sourceLanguageChange (wsService new) (T.pack path) (wmSourceLanguage oldMember) (wmSourceLanguage newMember)
  ]
  where
    oldByPath = Map.fromList [(wmPath member, member) | member <- wsMembers old]
    newByPath = Map.fromList [(wmPath member, member) | member <- wsMembers new]
    sourceLine LegacyUnversioned = 1
    sourceLine DeclaredLanguage {languageVersionLoc = Loc lineNumber} = lineNumber

-- | Preserve the existing headline/vector bytes and append indented citations.
renderWorkspaceFinding :: WorkspaceChange -> Text
renderWorkspaceFinding workspaceChange =
  T.intercalate "\n" (renderFinding (wcChange workspaceChange) : declarationLine <> useLines)
  where
    declarationLine = case wcDeclarationSite workspaceChange of
      Nothing -> []
      Just site -> ["    declared: " <> renderOwnedSite site]
    useLines =
      [ "    use-site: " <> path <> " (" <> renderOwnedSite site <> ")"
      | (path, Just site) <- wcUseSites workspaceChange
      ]

renderOwnedSite :: OwnedSite -> Text
renderOwnedSite site = T.pack (osFile site) <> ":" <> T.pack (show (osLine site))

ownedSiteForName :: WorkspaceSpec -> Name -> Maybe OwnedSite
ownedSiteForName workspace name = do
  (_, (file, Loc line)) <- find ((== name) . snd . fst) entries
  pure (OwnedSite file line)
  where
    ownership = wsOwnership workspace
    entries = Map.toAscList (oiDeclarations ownership) <> Map.toAscList (oiNodes ownership)

declarationName :: ChangeKind -> Name
declarationName kind
  | "mapped-" `T.isPrefixOf` ckFacet kind,
    Just mapped <- mappedNameFromSubject (ckSubject kind) =
      mapped
  | otherwise = ckNode kind

mappedNameFromSubject :: Text -> Maybe Name
mappedNameFromSubject subject =
  case T.breakOn " : " subject of
    (_, rest)
      | not (T.null rest),
        let name = T.takeWhile (not . isSpace) (T.drop 3 rest),
        not (T.null name) ->
          Just name
    _ -> Nothing

pathRoot :: Text -> Name
pathRoot = T.takeWhile (\c -> c /= '.' && not (isSpace c))

changeKind :: Change -> ChangeKind
changeKind (Additive kind) = kind
changeKind (Advisory kind) = kind
changeKind (Breaking kind) = kind

ownershipMoveChanges :: WorkspaceSpec -> WorkspaceSpec -> [WorkspaceChange]
ownershipMoveChanges old new =
  [ WorkspaceChange
      { wcChange =
          advisoryAt
            (consumerBuildContext name [])
            name
            "ownership"
            name
            OwnershipMoved
            ( "declaration moved "
                <> T.pack oldFile
                <> " -> "
                <> T.pack newFile
                <> "; source ownership changed while wire evolution remains independently classified"
            ),
        wcDeclarationSite = Just (OwnedSite newFile (unLoc newLoc)),
        wcUseSites = []
      }
  | (key@(_, name), (oldFile, _)) <- Map.toAscList (ownershipEntries (wsOwnership old)),
    Just (newFile, newLoc) <- [Map.lookup key (ownershipEntries (wsOwnership new))],
    oldFile /= newFile
  ]

ownershipEntries :: OwnershipIndex -> Map.Map (Text, Name) (FilePath, Loc)
ownershipEntries ownership = oiDeclarations ownership <> oiNodes ownership

authorityChanges :: WorkspaceSpec -> WorkspaceSpec -> [WorkspaceChange]
authorityChanges old new =
  concat
    [ changed "service-identity" (wsService old) (wsService new) serviceDetail,
      changed "context" (wsContext old) (wsContext new) contextDetail,
      changed "module-root" (renderModuleRoot (wsModuleRoot old)) (renderModuleRoot (wsModuleRoot new)) moduleDetail,
      changed "layout" (renderLayout (wsLayout old)) (renderLayout (wsLayout new)) layoutDetail
    ]
  where
    changed field before after detail
      | before == after = []
      | otherwise =
          [ WorkspaceChange
              { wcChange =
                  advisoryAt
                    (consumerBuildContext (wsService new) [])
                    (wsService new)
                    "workspace-authority"
                    field
                    WorkspaceAuthorityChanged
                    (field <> " changed '" <> before <> "' -> '" <> after <> "'; " <> detail),
                wcDeclarationSite = Nothing,
                wcUseSites = []
              }
          ]
    serviceDetail = "scaffold and compatibility history are re-keyed; follow the workspace adoption path"
    contextDetail = "generated module namespaces change, and read-model registry/subscription identities may emit separate DerivedIdentityChanged findings"
    moduleDetail = "generated module paths change without changing persisted wire identity"
    layoutDetail = "generated module placement changes without changing persisted wire identity"

renderModuleRoot :: Maybe Text -> Text
renderModuleRoot = maybe "(default)" id

renderLayout :: Maybe Placement -> Text
renderLayout Nothing = "(default)"
renderLayout (Just GeneratedPrefix) = "prefixed"
renderLayout (Just CollocatedLeaf) = "collocated"
