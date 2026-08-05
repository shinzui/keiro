module Main (main) where

import Control.Monad (forM_, unless)
import CorpusPlan (CorpusEntry (..), checkCabalInventory, checkRecordDiskConsistency, entryOutDir, loadCorpusPlan, renderInvocation)
import Data.Char (isSpace)
import Data.List (dropWhileEnd, nub, sort)
import Data.Text qualified as T
import System.Directory (setCurrentDirectory)
import System.Environment (getArgs, getEnvironment)
import System.Exit (ExitCode (..), exitFailure)
import System.IO (hPutStr, hPutStrLn, stderr)
import System.Process (CreateProcess (..), callProcess, proc, readCreateProcessWithExitCode, readProcessWithExitCode)

data Command
  = Regenerate [FilePath]
  | Check
  | UpdateGoldens [String]
  | Help

main :: IO ()
main = do
  command <- parseCommand <$> getArgs
  case command of
    Left message -> hPutStrLn stderr message >> hPutStrLn stderr helpText >> exitFailure
    Right Help -> putStrLn helpText
    Right (UpdateGoldens testArguments) -> updateGoldens testArguments
    Right Check -> runRegeneration True []
    Right (Regenerate onlyPaths) -> runRegeneration False onlyPaths

parseCommand :: [String] -> Either String Command
parseCommand [] = Right Help
parseCommand ["--help"] = Right Help
parseCommand ["-h"] = Right Help
parseCommand ("regenerate" : args) = Regenerate <$> parseOnly args
parseCommand ["check"] = Right Check
parseCommand ("update-goldens" : args) = Right (UpdateGoldens args)
parseCommand args = Left ("unknown arguments: " <> unwords args)

parseOnly :: [String] -> Either String [FilePath]
parseOnly [] = Right []
parseOnly ("--only" : path : rest) = (path :) <$> parseOnly rest
parseOnly args = Left ("invalid regenerate arguments: " <> unwords args)

selectEntries :: [FilePath] -> [CorpusEntry] -> IO [CorpusEntry]
selectEntries [] entries = pure entries
selectEntries requested entries = do
  let available = nub (map entryOutDir entries)
      unknown = filter (`notElem` available) requested
  unless (null unknown) $
    dieMany ["--only path is not in the corpus plan: " <> T.pack path | path <- unknown]
  pure [entry | entry <- entries, entryOutDir entry `elem` requested]

runRegeneration :: Bool -> [FilePath] -> IO ()
runRegeneration checking onlyPaths = do
  repoRoot <- resolveRepoRoot
  setCurrentDirectory repoRoot
  planResult <- loadCorpusPlan repoRoot
  (allEntries, exemptions) <- either dieMany pure planResult
  selected <- selectEntries onlyPaths allEntries
  let paths = corpusPaths allEntries
  if checking then requireCleanCorpus paths else pure ()
  putStrLn
    ( "corpus: "
        <> show (length selected)
        <> " of "
        <> show (length allEntries)
        <> " invocations selected"
    )
  keiroDsl <- resolveKeiroDsl
  forM_ selected (runEntry keiroDsl)
  runConsistencyChecks repoRoot allEntries exemptions
  if checking then requireUnchangedCorpus paths else printGitSummary paths

requireCleanCorpus :: [FilePath] -> IO ()
requireCleanCorpus paths = do
  statusText <- gitOutput (["status", "--porcelain", "--"] <> paths)
  unless (null statusText) $ do
    hPutStrLn stderr "conformance corpus check requires clean corpus paths before scaffolding:"
    hPutStr stderr statusText
    exitFailure

requireUnchangedCorpus :: [FilePath] -> IO ()
requireUnchangedCorpus paths = do
  statusText <- gitOutput (["status", "--porcelain", "--"] <> paths)
  diffText <- gitOutput (["diff", "--"] <> paths)
  unless (null statusText && null diffText) $ do
    hPutStrLn stderr "conformance corpus drifted after regeneration; review and commit the generated diff"
    hPutStr stderr statusText
    hPutStr stderr diffText
    exitFailure
  putStrLn "conformance corpus: ok"

resolveRepoRoot :: IO FilePath
resolveRepoRoot = do
  (exitCode, stdoutText, stderrText) <- readProcessWithExitCode "git" ["rev-parse", "--show-toplevel"] ""
  case exitCode of
    ExitSuccess -> pure (dropWhileEnd isSpace stdoutText)
    ExitFailure _ -> hPutStr stderr stderrText >> exitFailure

resolveKeiroDsl :: IO FilePath
resolveKeiroDsl = do
  callProcess "cabal" ["build", "keiro-dsl", "exe:keiro-dsl"]
  (exitCode, stdoutText, stderrText) <- readProcessWithExitCode "cabal" ["list-bin", "exe:keiro-dsl"] ""
  case exitCode of
    ExitSuccess -> pure (dropWhileEnd isSpace stdoutText)
    ExitFailure _ -> hPutStr stderr stderrText >> exitFailure

runEntry :: FilePath -> CorpusEntry -> IO ()
runEntry keiroDsl entry = do
  putStrLn ("scaffold " <> entryOutDir entry)
  input <- case entry of
    SkeletonRun {ceKind} -> do
      (exitCode, stdoutText, stderrText) <-
        readProcessWithExitCode keiroDsl ["new", T.unpack ceKind] ""
      hPutStr stderr stderrText
      case exitCode of
        ExitSuccess -> pure stdoutText
        ExitFailure _ -> dieInvocation entry ["new", T.unpack ceKind]
    _ -> pure ""
  let arguments = renderInvocation entry
  (exitCode, stdoutText, stderrText) <- readProcessWithExitCode keiroDsl arguments input
  putStr stdoutText
  hPutStr stderr stderrText
  case exitCode of
    ExitSuccess -> pure ()
    ExitFailure _ -> dieInvocation entry arguments

runConsistencyChecks :: FilePath -> [CorpusEntry] -> [FilePath] -> IO ()
runConsistencyChecks repoRoot entries exemptions = do
  recordErrors <- checkRecordDiskConsistency repoRoot entries
  unless (null recordErrors) (dieMany recordErrors)
  putStrLn "record/disk consistency: ok"
  cabalErrors <- checkCabalInventory repoRoot entries exemptions
  unless (null cabalErrors) (dieMany cabalErrors)
  putStrLn ("cabal inventory consistency: ok (" <> show (length exemptions) <> " exempted module(s))")

updateGoldens :: [String] -> IO ()
updateGoldens testArguments = do
  repoRoot <- resolveRepoRoot
  setCurrentDirectory repoRoot
  planResult <- loadCorpusPlan repoRoot
  (entries, _) <- either dieMany pure planResult
  environment <- getEnvironment
  let command =
        (proc "cabal" (["test", "keiro-dsl-test"] <> testArguments))
          { env = Just (("KEIRO_DSL_UPDATE_GOLDENS", "1") : filter ((/= "KEIRO_DSL_UPDATE_GOLDENS") . fst) environment)
          }
  (exitCode, stdoutText, stderrText) <- readCreateProcessWithExitCode command ""
  putStr stdoutText
  hPutStr stderr stderrText
  case exitCode of
    ExitFailure _ -> exitFailure
    ExitSuccess -> printGitSummary (corpusPaths entries)

dieInvocation :: CorpusEntry -> [String] -> IO a
dieInvocation entry arguments = do
  hPutStrLn stderr ("corpus invocation failed for " <> entryOutDir entry <> ": " <> unwords arguments)
  exitFailure

corpusPaths :: [CorpusEntry] -> [FilePath]
corpusPaths entries = sort (nub ("keiro-dsl/test/fixtures" : map entryOutDir entries))

printGitSummary :: [FilePath] -> IO ()
printGitSummary paths = do
  statusText <- gitOutput (["status", "--porcelain", "--"] <> paths)
  diffStat <- gitOutput (["diff", "--stat", "--"] <> paths)
  if null statusText && null diffStat
    then putStrLn "corpus regeneration complete; git reports no changes"
    else do
      putStr statusText
      putStr diffStat
      putStrLn "corpus regeneration complete; review and commit the corpus diff"

gitOutput :: [String] -> IO String
gitOutput arguments = do
  (exitCode, stdoutText, stderrText) <- readProcessWithExitCode "git" arguments ""
  case exitCode of
    ExitSuccess -> pure stdoutText
    ExitFailure _ -> hPutStr stderr stderrText >> exitFailure

dieMany :: [T.Text] -> IO a
dieMany messages = do
  forM_ messages (hPutStrLn stderr . T.unpack)
  exitFailure

helpText :: String
helpText =
  unlines
    [ "keiro-dsl-corpus-regen — replay the committed keiro-dsl conformance corpus",
      "",
      "Usage:",
      "  keiro-dsl-corpus-regen regenerate [--only REPOSITORY-RELATIVE-OUT-DIR]...",
      "  keiro-dsl-corpus-regen check",
      "  keiro-dsl-corpus-regen update-goldens [TEST-ARGUMENT]...",
      "",
      "The driver derives ordinary scaffold invocations from tracked records and",
      "uses keiro-dsl/test/conformance-corpus-manifest.txt only for workspace paths,",
      "ordered skeleton runs, extra CLI flags, and reviewed inventory exemptions.",
      "It drives the public keiro-dsl CLI, never forces overwrites, never touches",
      "create-once files, and never commits. Review git status and git diff afterward."
    ]
