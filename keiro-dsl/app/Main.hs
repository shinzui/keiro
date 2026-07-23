{- | The @keiro-dsl@ command-line tool. EP-1 ships the @parse@ and @check@
subcommands; a later milestone adds @scaffold@ to the same
optparse-applicative command tree.
-}
module Main (main) where

import Control.Monad (when)
import Data.Aeson qualified as Aeson
import Data.Maybe (fromMaybe)
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import Keiro.Dsl.Diff (Change (..), ChangeKind (..), diffSpecs, isBreaking)
import Keiro.Dsl.Goldens (emitGoldenPayloads, loadGoldenPayloads)
import Keiro.Dsl.Grammar (Placement (..), Spec (..))
import Keiro.Dsl.Parser (parseSpec)
import Keiro.Dsl.PrettyPrint (renderSpec)
import Keiro.Dsl.ReplayImpact (renderReplayImpact, replayImpact)
import Keiro.Dsl.Scaffold (Context (..))
import Keiro.Dsl.ScaffoldRun (executeScaffold, planScaffoldWithGoldens, renderRefusals, renderScaffoldReport)
import Keiro.Dsl.Skeleton (skeletonFor)
import Keiro.Dsl.Validate (Diagnostic (..), Severity (..), renderDiagnostic, validateSpec)
import Options.Applicative
import System.Directory (canonicalizePath)
import System.Exit (ExitCode (..), exitFailure)
import System.FilePath (makeRelative, takeDirectory, (</>))
import System.IO (hPutStrLn, stderr)
import System.Process (readProcessWithExitCode)

data Command
    = Parse FilePath
    | Check FilePath Bool
    | Scaffold FilePath FilePath (Maybe String) Bool Bool (Maybe FilePath)
    | Diff FilePath String (Maybe FilePath) (Maybe FilePath)
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
                (info (Scaffold <$> fileArg <*> outOpt <*> optional moduleRootOpt <*> collocateSwitch <*> forceGeneratedOverwriteSwitch <*> optional goldensOpt <**> helper) (progDesc "Emit the generated layer + typed holes from a .keiro file"))
            <> command
                "diff"
                (info (Diff <$> fileArg <*> sinceOpt <*> optional emitGoldensOpt <*> optional replayImpactOutOpt <**> helper) (progDesc "Classify spec changes since a git ref as ADDITIVE/WARNING/BREAKING over the decode and identity surface; exit non-zero on any BREAKING change"))
            <> command
                "new"
                (info (New <$> kindArg <**> helper) (progDesc "Print a minimal valid .keiro skeleton for a node kind (aggregate, process, router, contract, intake, emit, publisher, workqueue, dispatch, workflow, operation)"))
        )

outOpt :: Parser FilePath
outOpt = strOption (long "out" <> metavar "DIR" <> help "Output directory for the scaffolded modules")

moduleRootOpt :: Parser String
moduleRootOpt = strOption (long "module-root" <> metavar "PREFIX" <> help "Namespace prefix for emitted modules, e.g. Acme or Acme.Services (overrides the spec's module clause)")

collocateSwitch :: Parser Bool
collocateSwitch = switch (long "collocate" <> help "Place the generated layer as a leaf under the domain (<Ctx>.<Node>.Generated) instead of a parallel Generated.* tree")

forceGeneratedOverwriteSwitch :: Parser Bool
forceGeneratedOverwriteSwitch = switch (long "force-generated-overwrite" <> help "Overwrite a Generated path even when the existing file lacks the @generated banner")

goldensOpt :: Parser FilePath
goldensOpt = strOption (long "goldens" <> metavar "DIR" <> help "Golden-payload root to embed in generated aggregate harnesses")

emitGoldensOpt :: Parser FilePath
emitGoldensOpt = strOption (long "emit-goldens" <> metavar "DIR" <> help "Write old-shape payload fixtures for event version bumps without overwriting existing files")

replayImpactOutOpt :: Parser FilePath
replayImpactOutOpt = strOption (long "replay-impact-out" <> metavar "FILE" <> help "Write the replay-neutral or affected audit input as JSON")

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
run (Scaffold fp out cliRoot cliCollocate forceGeneratedOverwrite cliGoldens) = do
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
                goldenRoot = fromMaybe (takeDirectory fp </> "golden-payloads") cliGoldens
            goldens <- loadGoldenPayloads goldenRoot spec
            case planScaffoldWithGoldens goldens ctx spec of
                Left refusals -> do
                    mapM_ (TIO.hPutStrLn stderr) (renderRefusals refusals)
                    exitFailure
                Right modules -> do
                    result <- executeScaffold out forceGeneratedOverwrite fp ctx spec modules
                    case result of
                        Left refusals -> do
                            mapM_ (TIO.hPutStrLn stderr) (renderRefusals refusals)
                            exitFailure
                        Right report -> mapM_ (TIO.hPutStrLn stderr) (renderScaffoldReport report)
run (New kind) =
    case skeletonFor (T.pack kind) of
        Left err -> hPutStrLn stderr (T.unpack err) >> exitFailure
        Right skel -> TIO.putStr skel
run (Diff fp ref emitGoldensRoot replayImpactOut) = do
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
                            written <- maybe (pure []) (\root -> emitGoldenPayloads root oldSpec newSpec) emitGoldensRoot
                            mapM_ (putStrLn . ("golden: wrote " <>)) written
                            let changes = diffSpecs oldSpec newSpec
                                impact = replayImpact oldSpec newSpec
                            mapM_ (putStrLn . renderChange) changes
                            TIO.putStrLn (renderReplayImpact impact)
                            mapM_ (`Aeson.encodeFile` impact) replayImpactOut
                            if any isBreaking changes then exitFailure else pure ()

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
