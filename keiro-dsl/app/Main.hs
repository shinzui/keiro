{- | The @keiro-dsl@ command-line tool. EP-1 ships the @parse@ and @check@
subcommands; a later milestone adds @scaffold@ to the same
optparse-applicative command tree.
-}
module Main (main) where

import Control.Monad (forM_, unless)
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import Keiro.Dsl.Diff (Change (..), ChangeKind (..), diffSpecs, isBreaking)
import Keiro.Dsl.Grammar (Node (..), Spec (..))
import Keiro.Dsl.Harness (harnessFor)
import Keiro.Dsl.Parser (parseSpec)
import Keiro.Dsl.PrettyPrint (renderSpec)
import Keiro.Dsl.Scaffold (Context (..), ModuleKind (..), ScaffoldModule (..), scaffoldAggregate)
import Keiro.Dsl.Validate (Diagnostic (..), Severity (..), renderDiagnostic, validateSpec)
import Options.Applicative
import System.Directory (canonicalizePath, createDirectoryIfMissing, doesFileExist)
import System.Exit (ExitCode (..), exitFailure)
import System.FilePath (makeRelative, takeDirectory, (</>))
import System.IO (hPutStrLn, stderr)
import System.Process (readProcessWithExitCode)

data Command
    = Parse FilePath
    | Check FilePath
    | Scaffold FilePath FilePath
    | Diff FilePath String

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
            (info (Parse <$> fileArg <**> helper) (progDesc "Parse a .kdsl file and pretty-print it back"))
            <> command
                "check"
                (info (Check <$> fileArg <**> helper) (progDesc "Validate a .kdsl file; print diagnostics and exit non-zero on any error"))
            <> command
                "scaffold"
                (info (Scaffold <$> fileArg <*> outOpt <**> helper) (progDesc "Emit the generated layer + typed holes from a .kdsl file"))
            <> command
                "diff"
                (info (Diff <$> fileArg <*> sinceOpt <**> helper) (progDesc "Classify spec changes since a git ref as ADDITIVE/BREAKING; exit non-zero on any breaking change"))
        )

outOpt :: Parser FilePath
outOpt = strOption (long "out" <> metavar "DIR" <> help "Output directory for the scaffolded modules")

sinceOpt :: Parser String
sinceOpt = strOption (long "since" <> metavar "GIT-REF" <> help "Git ref to diff the spec against (e.g. HEAD, a tag, a branch)")

fileArg :: Parser FilePath
fileArg = argument str (metavar "FILE" <> help "Path to a .kdsl spec (use /dev/stdin for stdin)")

run :: Command -> IO ()
run (Parse fp) = do
    input <- TIO.readFile fp
    case parseSpec fp input of
        Left err -> do
            hPutStrLn stderr (T.unpack err)
            exitFailure
        Right spec -> TIO.putStrLn (renderSpec spec)
run (Check fp) = do
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
                else putStrLn "OK"
run (Scaffold fp out) = do
    input <- TIO.readFile fp
    case parseSpec fp input of
        Left err -> do
            hPutStrLn stderr (T.unpack err)
            exitFailure
        Right spec -> do
            let mods =
                    concat
                        [ scaffoldAggregate (mkContext spec) spec agg <> harnessFor (mkContext spec) spec agg
                        | NAggregate agg <- specNodes spec
                        ]
            forM_ mods (writeModule out)
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

{- | Write one module honouring the kind discipline: Generated modules are
overwritten unconditionally; HoleStub modules are written only when absent.
-}
writeModule :: FilePath -> ScaffoldModule -> IO ()
writeModule out m = do
    let path = out </> modulePath m
    createDirectoryIfMissing True (takeDirectory path)
    case kind m of
        Generated -> TIO.writeFile path (moduleText m)
        HoleStub -> do
            exists <- doesFileExist path
            unless exists (TIO.writeFile path (moduleText m))

renderChange :: Change -> String
renderChange c = case c of
    Additive k -> "ADDITIVE: " <> body k
    Breaking k -> "BREAKING: " <> body k <> codeSuffix k
  where
    body k = T.unpack (ckNode k) <> " event " <> T.unpack (ckSubject k) <> ": " <> T.unpack (ckDetail k)
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

mkContext :: Spec -> Context
mkContext spec = Context{contextName = specContext spec, moduleRoot = ""}
