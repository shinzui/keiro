{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}

module Conformance.Structural.Bindings (
    artifactInfoBinding,
    artifactInfoCases,
    emptyArtifactInfo,
    artifactMetadataBinding,
    artifactMetadataCases,
    artifactKindBinding,
    artifactKindCases,
    artifactLocationBinding,
    artifactLocationCases,
    geometryCases,
    emptyGeometry,
) where

import Conformance.Structural.Domain qualified as Domain
import Data.List.NonEmpty (NonEmpty (..))
import Data.Text (Text)
import Generated.StructuralConformance.Structural.Shape.ArtifactInfo qualified as InfoShape
import Generated.StructuralConformance.Structural.Shape.ArtifactKind qualified as KindShape
import Generated.StructuralConformance.Structural.Shape.ArtifactLocation qualified as LocationShape
import Generated.StructuralConformance.Structural.Shape.ArtifactMetadata qualified as MetadataShape
import Keiro.Codec.Structural (FixtureCases (..), StructuralBinding (..))
import Keiro.Codec.Structural.Generic (genericStructuralBinding)

artifactKindBinding :: StructuralBinding Domain.ArtifactKind KindShape.ArtifactKindShape
artifactKindBinding = genericStructuralBinding

artifactLocationBinding :: StructuralBinding Domain.ArtifactLocation LocationShape.ArtifactLocationShape
artifactLocationBinding = genericStructuralBinding

artifactMetadataBinding :: StructuralBinding Domain.ArtifactMetadata MetadataShape.ArtifactMetadataShape
artifactMetadataBinding = genericStructuralBinding

artifactInfoBinding :: StructuralBinding Domain.ArtifactInfo InfoShape.ArtifactInfoShape
artifactInfoBinding =
    StructuralBinding
        { bindingToShape = \value ->
            InfoShape.ArtifactInfo
                value.artifactKey
                value.displayName
                value.artifactHash
                (bindingToShape artifactKindBinding value.artifactKind)
                (bindingToShape artifactLocationBinding value.location)
                (bindingToShape artifactMetadataBinding value.metadata)
                value.active
                value.tags
        , bindingFromShape = \(InfoShape.ArtifactInfo artifactKey displayName artifactHash artifactKind location metadata active tags) ->
            Domain.ArtifactInfo
                artifactKey
                displayName
                artifactHash
                (bindingFromShape artifactKindBinding artifactKind)
                (bindingFromShape artifactLocationBinding location)
                (bindingFromShape artifactMetadataBinding metadata)
                active
                tags
        }

artifactKindCases :: FixtureCases Domain.ArtifactKind
artifactKindCases = FixtureCases (("guide", Domain.Guide) :| [("reference", Domain.Reference)])

artifactLocationCases :: FixtureCases Domain.ArtifactLocation
artifactLocationCases =
    FixtureCases
        ( ("local-file", Domain.LocalFile "/tmp/artifact.txt")
            :| [ ("local-dir", Domain.LocalDir "/tmp/artifacts")
               , ("repo-path", Domain.RepoPath "docs/artifact.md")
               , ("url", Domain.LocUrl "https://example.test/artifact")
               , ("canonical", Domain.Canonical)
               ]
        )

artifactMetadataCases :: FixtureCases Domain.ArtifactMetadata
artifactMetadataCases =
    FixtureCases
        ( ("without-note", Domain.ArtifactMetadata Nothing)
            :| [("with-note", Domain.ArtifactMetadata (Just "consumer note"))]
        )

artifactInfoCases :: FixtureCases Domain.ArtifactInfo
artifactInfoCases =
    FixtureCases
        ( ( "local-file-no-hash"
          , artifact "artifact-local-file" "Local file" Nothing Domain.Guide (Domain.LocalFile "/tmp/artifact.txt") Nothing
          )
            :| [
                   ( "local-dir-with-hash"
                   , artifact "artifact-local-dir" "Local directory" (Just "sha256:01") Domain.Reference (Domain.LocalDir "/tmp/artifacts") (Just "directory")
                   )
               ,
                   ( "repo-path"
                   , artifact "artifact-repo" "Repository path" Nothing Domain.Guide (Domain.RepoPath "docs/artifact.md") (Just "repository")
                   )
               ,
                   ( "url"
                   , artifact "artifact-url" "URL" (Just "sha256:02") Domain.Reference (Domain.LocUrl "https://example.test/artifact") Nothing
                   )
               ,
                   ( "canonical"
                   , artifact "artifact-canonical" "Canonical" Nothing Domain.Guide Domain.Canonical (Just "canonical")
                   )
               ]
        )

artifact :: Text -> Text -> Maybe Text -> Domain.ArtifactKind -> Domain.ArtifactLocation -> Maybe Text -> Domain.ArtifactInfo
artifact artifactKey displayName artifactHash artifactKind location note =
    Domain.ArtifactInfo
        { Domain.artifactKey = artifactKey
        , Domain.displayName = displayName
        , Domain.artifactHash = artifactHash
        , Domain.artifactKind = artifactKind
        , Domain.location = location
        , Domain.metadata = Domain.ArtifactMetadata note
        , Domain.active = True
        , Domain.tags = ["conformance", artifactKey]
        }

emptyArtifactInfo :: Domain.ArtifactInfo
emptyArtifactInfo = artifact "artifact-empty" "Empty" Nothing Domain.Guide Domain.Canonical Nothing

geometryCases :: FixtureCases Domain.Geometry
geometryCases =
    FixtureCases
        ( ("point", Domain.Geometry "POINT (1 2)")
            :| [("polygon", Domain.Geometry "POLYGON ((0 0, 1 0, 1 1, 0 0))")]
        )

emptyGeometry :: Domain.Geometry
emptyGeometry = Domain.Geometry "GEOMETRYCOLLECTION EMPTY"
