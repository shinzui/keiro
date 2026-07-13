{- | The @keiro-dsl@ command-line tool. EP-1 ships the @parse@ and @check@
subcommands; a later milestone adds @scaffold@ to the same
optparse-applicative command tree.
-}
module Main (main) where

import Control.Monad (unless, when)
import Data.Maybe (fromMaybe)
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import Keiro.Dsl.Diff (Change (..), ChangeKind (..), diffSpecs, isBreaking)
import Keiro.Dsl.Grammar (Node (..), Placement (..), Spec (..))
import Keiro.Dsl.Harness (harnessFor, harnessProcess, harnessWorkflow)
import Keiro.Dsl.Manifest (moduleNameOf, renderManifest)
import Keiro.Dsl.Parser (parseSpec)
import Keiro.Dsl.PrettyPrint (renderSpec)
import Keiro.Dsl.Scaffold (Context (..), ModuleKind (..), ScaffoldModule (..), firewallBreaches, scaffoldAggregate, scaffoldContract, scaffoldIntake, scaffoldProcess, scaffoldPublisher, scaffoldWorkqueue)
import Keiro.Dsl.Skeleton (skeletonFor)
import Keiro.Dsl.Validate (Diagnostic (..), Severity (..), renderDiagnostic, validateSpec)
import Options.Applicative
import System.Directory (canonicalizePath, createDirectoryIfMissing, doesFileExist)
import System.Exit (ExitCode (..), exitFailure)
import System.FilePath (makeRelative, takeDirectory, (</>))
import System.IO (hPutStrLn, stderr)
import System.Process (readProcessWithExitCode)

data Command
    = Parse FilePath
    | Check FilePath Bool
    | Scaffold FilePath FilePath (Maybe String) Bool
    | Diff FilePath String
    | New String

main :: IO ()
main = run =<< execParser opts
  where
    opts =
        info
            (commands <**> helper)
            (fullDesc <> progDesc "keiro-dsl: a typed-specification toolchain for keiro services")

commands :: Parser Command
commands =
    subparser
        ( command
            "parse"
            (info (Parse <$> fileArg <**> helper) (progDesc "Parse a .keiro file and pretty-print it back"))
            <> command
                "check"
                (info (Check <$> fileArg <*> emitSwitch <**> helper) (progDesc "Validate a .keiro file; print diagnostics and exit non-zero on any error"))
            <> command
                "scaffold"
                (info (Scaffold <$> fileArg <*> outOpt <*> optional moduleRootOpt <*> collocateSwitch <**> helper) (progDesc "Emit the generated layer + typed holes from a .keiro file"))
            <> command
                "diff"
                (info (Diff <$> fileArg <*> sinceOpt <**> helper) (progDesc "Classify spec changes since a git ref as ADDITIVE/WARNING/BREAKING over the decode and identity surface; exit non-zero on any BREAKING change"))
            <> command
                "new"
                (info (New <$> kindArg <**> helper) (progDesc "Print a minimal valid .keiro skeleton for a node kind (aggregate, process, contract, intake, emit, publisher, workqueue, dispatch, workflow, operation)"))
        )

outOpt :: Parser FilePath
outOpt = strOption (long "out" <> metavar "DIR" <> help "Output directory for the scaffolded modules")

moduleRootOpt :: Parser String
moduleRootOpt = strOption (long "module-root" <> metavar "PREFIX" <> help "Namespace prefix for emitted modules, e.g. Acme or Acme.Services (overrides the spec's module clause)")

collocateSwitch :: Parser Bool
collocateSwitch = switch (long "collocate" <> help "Place the generated layer as a leaf under the domain (<Ctx>.<Node>.Generated) instead of a parallel Generated.* tree")

emitSwitch :: Parser Bool
emitSwitch = switch (long "emit" <> help "On success, pretty-print the parsed spec to stdout (folds parse + check into one call)")

sinceOpt :: Parser String
sinceOpt = strOption (long "since" <> metavar "GIT-REF" <> help "Git ref to diff the spec against (e.g. HEAD, a tag, a branch)")

fileArg :: Parser FilePath
fileArg = argument str (metavar "FILE" <> help "Path to a .keiro spec (use /dev/stdin for stdin)")

kindArg :: Parser String
kindArg = argument str (metavar "KIND" <> help "Node kind to scaffold a starter spec for")

run :: Command -> IO ()
run (Parse fp) = do
    input <- TIO.readFile fp
    case parseSpec fp input of
        Left err -> do
            hPutStrLn stderr (T.unpack err)
            exitFailure
        Right spec -> TIO.putStrLn (renderSpec spec)
run (Check fp emit) = do
    input <- TIO.readFile fp
    case parseSpec fp input of
        Left err -> do
            hPutStrLn stderr (T.unpack err)
            exitFailure
        Right spec -> do
            let diags = validateSpec spec
            mapM_ (TIO.hPutStrLn stderr . renderDiagnostic fp) diags
            if any ((== Error) . severity) diags
                then exitFailure
                else
                    if emit
                        then TIO.putStrLn (renderSpec spec)
                        else putStrLn "OK"
run (Scaffold fp out cliRoot cliCollocate) = do
    input <- TIO.readFile fp
    case parseSpec fp input of
        Left err -> do
            hPutStrLn stderr (T.unpack err)
            exitFailure
        Right spec -> do
            -- Validation gate: never scaffold an invalid spec. Abort on any
            -- error-severity diagnostic before writing a single module.
            let diags = validateSpec spec
            mapM_ (TIO.hPutStrLn stderr . renderDiagnostic fp) diags
            when (any ((== Error) . severity) diags) exitFailure
            let ctx = mkContext cliRoot cliCollocate spec
                aggMods =
                    concat
                        [ scaffoldAggregate ctx spec agg <> harnessFor ctx spec agg
                        | NAggregate agg <- specNodes spec
                        ]
                procMods = concat [scaffoldProcess ctx p <> harnessProcess ctx p | NProcess p <- specNodes spec]
                contractMods = concat [scaffoldContract ctx c | NContract c <- specNodes spec]
                intakeMods = concat [scaffoldIntake ctx ik | NIntake ik <- specNodes spec]
                pubMods = concat [scaffoldPublisher ctx pb | NPublisher pb <- specNodes spec]
                wqMods = concat [scaffoldWorkqueue ctx wq | NWorkqueue wq <- specNodes spec]
                wfMods = concat [harnessWorkflow ctx wf | NWorkflow wf <- specNodes spec]
                allMods = aggMods <> procMods <> contractMods <> intakeMods <> pubMods <> wqMods <> wfMods
            createDirectoryIfMissing True out
            dispositions <- mapM (writeModule out) allMods
            let manifestPath = out </> ("keiro-dsl-manifest." <> T.unpack (specContext spec) <> ".txt")
            TIO.writeFile manifestPath (renderManifest (T.pack fp) allMods spec)
            let breaches = firewallBreaches allMods
            mapM_ (hPutStrLn stderr) (reportLines fp out ctx dispositions breaches manifestPath)
            unless (null breaches) exitFailure
run (New kind) =
    case skeletonFor (T.pack kind) of
        Left err -> hPutStrLn stderr (T.unpack err) >> exitFailure
        Right skel -> TIO.putStr skel
run (Diff fp ref) = do
    -- Resolve the spec to a repo-relative path so `git show <ref>:<relpath>` works.
    let dir = takeDirectory fp
    rootRes <- git dir ["rev-parse", "--show-toplevel"]
    case rootRes of
        Left err -> hPutStrLn stderr err >> exitFailure
        Right rootRaw -> do
            let repoRoot = trim rootRaw
            absFp <- canonicalizePath fp
            let relPath = makeRelative repoRoot absFp
            oldRes <- git repoRoot ["show", ref <> ":" <> relPath]
            case oldRes of
                Left err -> hPutStrLn stderr ("git show " <> ref <> ":" <> relPath <> " failed:\n" <> err) >> exitFailure
                Right oldText -> do
                    newText <- TIO.readFile fp
                    case (,) <$> parseSpec (ref <> ":" <> relPath) (T.pack oldText) <*> parseSpec fp newText of
                        Left perr -> hPutStrLn stderr (T.unpack perr) >> exitFailure
                        Right (oldSpec, newSpec) -> do
                            let changes = diffSpecs oldSpec newSpec
                            mapM_ (putStrLn . renderChange) changes
                            if any isBreaking changes then exitFailure else pure ()

-- | What happened to a module on disk during a scaffold run.
data WriteDisposition = Overwritten | Created | Skipped
    deriving stock (Eq, Show)

{- | Write one module honouring the kind discipline: Generated modules are
overwritten unconditionally; HoleStub modules are written only when absent.
Returns the module and what happened to it, for the post-scaffold report.
-}
writeModule :: FilePath -> ScaffoldModule -> IO (ScaffoldModule, WriteDisposition)
writeModule out m = do
    let path = out </> modulePath m
    createDirectoryIfMissing True (takeDirectory path)
    case kind m of
        Generated -> do
            TIO.writeFile path (moduleText m)
            pure (m, Overwritten)
        HoleStub -> do
            exists <- doesFileExist path
            if exists
                then pure (m, Skipped)
                else TIO.writeFile path (moduleText m) >> pure (m, Created)

{- | The post-scaffold report (printed to standard error): every module written
with its disposition, the firewall verdict, the harness component(s), and the
manifest path.
-}
reportLines ::
    FilePath ->
    FilePath ->
    Context ->
    [(ScaffoldModule, WriteDisposition)] ->
    [(FilePath, T.Text, Int)] ->
    FilePath ->
    [String]
reportLines fp out ctx dispositions breaches manifestPath =
    [ "scaffold: " <> fp <> " -> " <> out <> " (module-root=" <> rootLabel <> ", layout=" <> layoutLabel <> ")"
    ]
        ++ map moduleLine dispositions
        ++ [firewallLine]
        ++ harnessLines
        ++ ["manifest: " <> manifestPath]
  where
    rootLabel = case T.unpack (moduleRoot ctx) of "" -> "(none)"; r -> r
    layoutLabel = case placement ctx of GeneratedPrefix -> "prefixed"; CollocatedLeaf -> "collocated"
    nameOf m = T.unpack (moduleNameOf (modulePath m))
    nameWidth = maximum (1 : [length (nameOf m) | (m, _) <- dispositions])
    pad s = s <> replicate (nameWidth - length s) ' '
    moduleLine (m, disp) =
        "  " <> kindTag (kind m) <> "  " <> pad (nameOf m) <> "  " <> dispTag disp
    kindTag Generated = "generated"
    kindTag HoleStub = "hole     "
    dispTag Overwritten = "(overwritten)"
    dispTag Created = "(created)"
    dispTag Skipped = "(skipped: already present)"
    genCount = length [() | (m, _) <- dispositions, kind m == Generated]
    firewallLine = case breaches of
        [] -> "firewall: OK (" <> show genCount <> " generated modules scanned, 0 forbidden operators)"
        bs ->
            "firewall: BREACH ("
                <> show (length bs)
                <> " forbidden operator occurrence(s)):\n"
                <> unlines ["  " <> p <> ":" <> show n <> " contains " <> T.unpack op | (p, op, n) <- bs]
    harnessModules =
        [ nameOf m
        | (m, _) <- dispositions
        , let nm = T.pack (nameOf m)
        , any (`T.isSuffixOf` nm) [".Harness", ".ProcessHarness", ".WorkflowFacts"]
        ]
    harnessLines = case harnessModules of
        [] -> ["harness:  (none emitted)"]
        hs -> ["harness:  run `cabal test <your-component>` over " <> unwords hs]

renderChange :: Change -> String
renderChange c = case c of
    Additive k -> "ADDITIVE: " <> body k
    Advisory k -> "WARNING: " <> body k <> codeSuffix k
    Breaking k -> "BREAKING: " <> body k <> codeSuffix k
  where
    body k = T.unpack (ckNode k) <> " " <> T.unpack (ckFacet k) <> " " <> T.unpack (ckSubject k) <> ": " <> T.unpack (ckDetail k)
    codeSuffix k = maybe "" (\dc -> " [" <> show dc <> "]") (ckCode k)

-- | Run git in a directory, returning trimmed stdout or stderr.
git :: FilePath -> [String] -> IO (Either String String)
git dir args = do
    (ec, out, err) <- readProcessWithExitCode "git" (["-C", dir] <> args) ""
    pure $ case ec of
        ExitSuccess -> Right out
        ExitFailure _ -> Left (if null err then out else err)

trim :: String -> String
trim = f . f where f = reverse . dropWhile (`elem` (" \t\r\n" :: String))

{- | Fold the spec's @module@/@layout@ clauses with the CLI overrides to a
'Context'. Precedence is CLI flag > spec clause > built-in default.
-}
mkContext :: Maybe String -> Bool -> Spec -> Context
mkContext cliRoot cliCollocate spec =
    Context
        { contextName = specContext spec
        , moduleRoot = maybe (fromMaybe "" (specModuleRoot spec)) T.pack cliRoot
        , placement =
            if cliCollocate
                then CollocatedLeaf
                else fromMaybe GeneratedPrefix (specLayout spec)
        }
