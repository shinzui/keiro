{- | Whole-service evolution findings enriched with workspace source ownership.

The ordinary differ remains the single authority for compatibility. This module
runs it over the two composed 'WorkspaceSpec' graphs and adds only source
citations. Consequently, file layout can never manufacture, suppress, or demote
a wire finding.
-}
module Keiro.Dsl.WorkspaceDiff (
    OwnedSite (..),
    WorkspaceChange (..),
    WorkspaceMeta (..),
    WorkspaceDiffReport,
    workspaceDiffReport,
    diffWorkspaces,
    renderWorkspaceFinding,
) where

import Control.Applicative ((<|>))
import Data.Char (isSpace)
import Data.List (find)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Keiro.Dsl.Diff (Change (..), ChangeKind (..), diffSpecs)
import Keiro.Dsl.DiffReport (OwnedSite (..), WorkspaceChange (..), WorkspaceDiffReport, WorkspaceMeta (..), renderFinding, workspaceDiffReport)
import Keiro.Dsl.Grammar (Loc (..), Name)
import Keiro.Dsl.Workspace (OwnershipIndex (..), WorkspaceSpec (..))

-- | Diff two composed service graphs and cite every participant we can resolve.
diffWorkspaces :: WorkspaceSpec -> WorkspaceSpec -> [WorkspaceChange]
diffWorkspaces old new = map annotate (diffSpecs (wsMergedSpec old) (wsMergedSpec new))
  where
    annotate change =
        WorkspaceChange
            { wcChange = change
            , wcDeclarationSite =
                ownedSiteForName new (declarationName kind)
                    <|> ownedSiteForName old (declarationName kind)
            , wcUseSites =
                [ (path, ownedSiteForName new (pathRoot path) <|> ownedSiteForName old (pathRoot path))
                | path <- ckPaths kind
                ]
            }
      where
        kind = changeKind change

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
    | "mapped-" `T.isPrefixOf` ckFacet kind
    , Just mapped <- mappedNameFromSubject (ckSubject kind) =
        mapped
    | otherwise = ckNode kind

mappedNameFromSubject :: Text -> Maybe Name
mappedNameFromSubject subject =
    case T.breakOn " : " subject of
        (_, rest)
            | not (T.null rest)
            , let name = T.takeWhile (not . isSpace) (T.drop 3 rest)
            , not (T.null name) ->
                Just name
        _ -> Nothing

pathRoot :: Text -> Name
pathRoot = T.takeWhile (\c -> c /= '.' && not (isSpace c))

changeKind :: Change -> ChangeKind
changeKind (Additive kind) = kind
changeKind (Advisory kind) = kind
changeKind (Breaking kind) = kind
