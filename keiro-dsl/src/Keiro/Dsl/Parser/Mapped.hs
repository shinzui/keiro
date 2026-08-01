{-# LANGUAGE ImportQualifiedPost #-}

-- | Consumer-owned mapped and nominal type syntax.
module Keiro.Dsl.Parser.Mapped
  ( pMappedTopItem,
    pMappedTypeExpr,
    pUsingNominalBinding,
  )
where

import Data.Maybe (mapMaybe)
import Data.Text (Text)
import Keiro.Dsl.Grammar
import Keiro.Dsl.LanguageVersion
import Keiro.Dsl.Parser.Core
import Keiro.Dsl.Syntax (SurfaceTopItem (..))
import Text.Megaparsec

-- Consumer-owned mapped and nominal types
--------------------------------------------------------------------------------

data MappedKind = MappedRecord | MappedEnum | MappedUnion

data MappedClause
  = MCHaskell HaskellSource
  | MCBinding Text
  | MCBindingVersion Text
  | MCCanonical Text
  | MCFixtures Text
  | MCInitial Text
  | MCCodec Text
  | MCCodecVersion Text
  | MCShape MappedShape

pMappedTopItem :: LanguageVersion -> P SurfaceTopItem
pMappedTopItem version = do
  loc <- getLoc
  keyword "mapped"
  choice
    [ if languageSupportsFeature version NominalBindingSyntax
        then SurfaceNominalScalar <$> pNominalScalarAfterMapped loc
        else do
          _ <- try (keyword "nominal")
          contextualFailureAt loc LanguageFeatureRequiresVersion,
      SurfaceMapped <$> pMappedStructural version loc,
      SurfaceMapped <$> pMappedOpaque loc
    ]

pMappedStructural :: LanguageVersion -> Loc -> P MappedDecl
pMappedStructural version loc = do
  keyword "structural"
  kind <-
    choice
      [ MappedRecord <$ keyword "record",
        MappedEnum <$ keyword "enum",
        MappedUnion <$ keyword "union"
      ]
  name <- ident
  clauses <- braces (many (pStructuralClause version kind))
  hs <- oneClause "haskell" (\case MCHaskell value -> Just value; _ -> Nothing) clauses
  binding <- oneClause "binding" (\case MCBinding value -> Just value; _ -> Nothing) clauses
  bindingVersion <- oneClause "binding-version" (\case MCBindingVersion value -> Just value; _ -> Nothing) clauses
  canonical <- oneClause "canonical-type" (\case MCCanonical value -> Just value; _ -> Nothing) clauses
  fixtures <- oneClause "fixtures" (\case MCFixtures value -> Just value; _ -> Nothing) clauses
  initial <- oneClause "initial" (\case MCInitial value -> Just value; _ -> Nothing) clauses
  shape <- requiredClause "wire" (\case MCShape value -> Just value; _ -> Nothing) clauses
  pure
    MappedStructural
      { msName = name,
        msHaskell = hs,
        msBinding = binding,
        msBindingVersion = bindingVersion,
        msCanonical = canonical,
        msFixtures = fixtures,
        msInitial = initial,
        msShape = shape,
        msLoc = loc
      }

pMappedOpaque :: Loc -> P MappedDecl
pMappedOpaque loc = do
  keyword "opaque"
  name <- ident
  clauses <- braces (many pOpaqueClause)
  hs <- oneClause "haskell" (\case MCHaskell value -> Just value; _ -> Nothing) clauses
  codec <- oneClause "codec" (\case MCCodec value -> Just value; _ -> Nothing) clauses
  version <- oneClause "version" (\case MCCodecVersion value -> Just value; _ -> Nothing) clauses
  fixtures <- oneClause "fixtures" (\case MCFixtures value -> Just value; _ -> Nothing) clauses
  initial <- oneClause "initial" (\case MCInitial value -> Just value; _ -> Nothing) clauses
  pure
    MappedOpaque
      { moName = name,
        moHaskell = hs,
        moCodecId = codec,
        moCodecVersion = version,
        moFixtures = fixtures,
        moInitial = initial,
        moLoc = loc
      }

pNominalScalarAfterMapped :: Loc -> P NominalScalarDecl
pNominalScalarAfterMapped loc = do
  keyword "nominal"
  name <- ident
  _ <- symbol ":"
  representation <- ident
  binding <- pNominalBindingBlock loc
  pure
    NominalScalarDecl
      { nominalScalarName = name,
        nominalScalarRepresentation = representation,
        nominalScalarBinding = binding,
        nominalScalarLoc = loc
      }

pUsingNominalBinding :: P NominalBindingDecl
pUsingNominalBinding = do
  keyword "using"
  loc <- getLoc
  pNominalBindingBlock loc

pNominalBindingBlock :: Loc -> P NominalBindingDecl
pNominalBindingBlock loc = do
  clauses <- braces (many pNominalClause)
  hs <- oneClause "haskell" (\case MCHaskell value -> Just value; _ -> Nothing) clauses
  binding <- oneClause "binding" (\case MCBinding value -> Just value; _ -> Nothing) clauses
  bindingVersion <- oneClause "binding-version" (\case MCBindingVersion value -> Just value; _ -> Nothing) clauses
  canonical <- oneClause "canonical-type" (\case MCCanonical value -> Just value; _ -> Nothing) clauses
  fixtures <- oneClause "fixtures" (\case MCFixtures value -> Just value; _ -> Nothing) clauses
  initial <- oneClause "initial" (\case MCInitial value -> Just value; _ -> Nothing) clauses
  pure
    NominalBindingDecl
      { nominalHaskell = hs,
        nominalBinding = binding,
        nominalBindingVersion = bindingVersion,
        nominalCanonicalType = canonical,
        nominalFixtures = fixtures,
        nominalInitial = initial,
        nominalLoc = loc
      }

pNominalClause :: P MappedClause
pNominalClause =
  choice
    [ MCHaskell <$> pHaskellSource,
      MCBindingVersion <$> pQuotedFact "binding-version",
      MCBinding <$> pQuotedFact "binding",
      MCCanonical <$> pQuotedFact "canonical-type",
      MCFixtures <$> pQuotedFact "fixtures",
      MCInitial <$> pQuotedFact "initial"
    ]

pStructuralClause :: LanguageVersion -> MappedKind -> P MappedClause
pStructuralClause version kind =
  choice
    [ MCHaskell <$> pHaskellSource,
      MCBindingVersion <$> pQuotedFact "binding-version",
      MCBinding <$> pQuotedFact "binding",
      MCCanonical <$> pQuotedFact "canonical-type",
      MCFixtures <$> pQuotedFact "fixtures",
      MCInitial <$> pQuotedFact "initial",
      MCShape <$> pMappedShape version kind
    ]

pOpaqueClause :: P MappedClause
pOpaqueClause =
  choice
    [ MCHaskell <$> pHaskellSource,
      MCCodec <$> pQuotedFact "codec",
      MCCodecVersion <$> pQuotedFact "version",
      MCFixtures <$> pQuotedFact "fixtures",
      MCInitial <$> pQuotedFact "initial"
    ]

pHaskellSource :: P HaskellSource
pHaskellSource = do
  keyword "haskell"
  keyword "package"
  _ <- symbol "="
  packageName <- wireWord
  keyword "module"
  _ <- symbol "="
  moduleName <- pModulePrefix
  keyword "type"
  _ <- symbol "="
  typeName <- ident
  pure HaskellSource {hsPackage = packageName, hsModule = moduleName, hsType = typeName}

pQuotedFact :: Text -> P Text
pQuotedFact factName = keyword factName *> symbol "=" *> stringLit

pMappedShape :: LanguageVersion -> MappedKind -> P MappedShape
pMappedShape version kind = do
  keyword "wire"
  case kind of
    MappedRecord -> do
      keyword "object"
      keyword "constructor"
      _ <- symbol "="
      constructor <- ident
      unknownFields <- pUnknownFieldsFact
      fields <- braces (many (pWireField version))
      pure (ShapeRecord constructor unknownFields fields)
    MappedEnum -> do
      keyword "string"
      ShapeEnum <$> braces (many pWireEnum)
    MappedUnion -> do
      keyword "tagged-object"
      keyword "tag"
      _ <- symbol "="
      tagField <- stringLit
      keyword "contents"
      _ <- symbol "="
      contentsField <- stringLit
      unknownFields <- pUnknownFieldsFact
      arms <- braces (many (pWireArm version))
      pure (ShapeUnion (TaggedObject tagField contentsField unknownFields) arms)

pUnknownFieldsFact :: P UnknownFields
pUnknownFieldsFact = do
  keyword "unknown-fields"
  _ <- symbol "="
  choice [RejectUnknown <$ keyword "reject", IgnoreUnknown <$ keyword "ignore"]

pWireField :: LanguageVersion -> P WireField
pWireField version = do
  loc <- getLoc
  haskellName <- ident
  keyword "as"
  wireKey <- stringLit
  _ <- symbol ":"
  fieldType <- pMappedTypeExpr version
  presence <- choice [PRequired <$ keyword "required", POptional <$ keyword "optional"]
  onMissing <- optional (keyword "on-missing" *> symbol "=" *> pOnMissing)
  pure
    WireField
      { wfHaskell = haskellName,
        wfKey = wireKey,
        wfType = fieldType,
        wfPresence = presence,
        wfOnMissing = onMissing,
        wfLoc = loc
      }

pWireEnum :: P WireEnum
pWireEnum = do
  loc <- getLoc
  constructor <- ident
  keyword "as"
  wireTag <- stringLit
  pure WireEnum {weCtor = constructor, weTag = wireTag, weLoc = loc}

pWireArm :: LanguageVersion -> P WireArm
pWireArm version = do
  loc <- getLoc
  constructor <- ident
  keyword "as"
  wireTag <- stringLit
  payload <- optional (symbol ":" *> pMappedTypeExpr version)
  pure WireArm {waCtor = constructor, waTag = wireTag, waPayload = payload, waLoc = loc}

pMappedTypeExpr :: LanguageVersion -> P TypeExpr
pMappedTypeExpr version =
  choice
    [ TOptional <$> (keyword "Optional" *> pTypeArgument),
      TList <$> (keyword "List" *> pTypeArgument),
      TMap <$> (keyword "Map" *> pTypeArgument),
      TText <$ keyword "Text",
      TInt <$ keyword "Int",
      TInteger <$ languageFeatureKeyword version IntegerScalarSyntax "Integer",
      TBool <$ keyword "Bool",
      TNatural <$ keyword "Natural",
      TTime <$ (keyword "Time" <|> keyword "UTCTime"),
      TJson <$ keyword "Json",
      TRef <$> ident
    ]
  where
    pTypeArgument = parens (pMappedTypeExpr version) <|> pTypeAtom
    pTypeAtom =
      choice
        [ TText <$ keyword "Text",
          TInt <$ keyword "Int",
          TInteger <$ languageFeatureKeyword version IntegerScalarSyntax "Integer",
          TBool <$ keyword "Bool",
          TNatural <$ keyword "Natural",
          TTime <$ (keyword "Time" <|> keyword "UTCTime"),
          TJson <$ keyword "Json",
          TRef <$> ident
        ]

languageFeatureKeyword :: LanguageVersion -> LanguageFeature -> Text -> P ()
languageFeatureKeyword version feature spelling = do
  loc <- getLoc
  keyword spelling
  requireLanguageFeatureAt version feature loc

pOnMissing :: P OnMissing
pOnMissing =
  choice
    [ OmNull <$ keyword "null",
      OmEmptyList <$ (symbol "[" *> symbol "]"),
      OmEmptyMap <$ (symbol "{" *> symbol "}"),
      OmBool True <$ keyword "true",
      OmBool False <$ keyword "false",
      OmText <$> stringLit,
      OmInt <$> integerLiteral,
      OmCtor <$> ident
    ]

oneClause :: String -> (MappedClause -> Maybe a) -> [MappedClause] -> P (Maybe a)
oneClause clauseName select clauses =
  case mapMaybe select clauses of
    [] -> pure Nothing
    [value] -> pure (Just value)
    _ -> fail ("duplicate " <> clauseName <> " clause in mapped declaration")

requiredClause :: String -> (MappedClause -> Maybe a) -> [MappedClause] -> P a
requiredClause clauseName select clauses = do
  found <- oneClause clauseName select clauses
  maybe (fail ("missing " <> clauseName <> " clause in mapped structural declaration")) pure found

--------------------------------------------------------------------------------
