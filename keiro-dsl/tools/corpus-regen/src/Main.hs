module Main (main) where

import Control.Monad (forM_, unless)
import CorpusPlan (CorpusEntry (..), checkCabalInventory, checkRecordDiskConsistency, checkSuiteCoverage, entryOutDir, loadCorpusPlan, renderInvocation)
import Data.Char (isSpace)
import Data.List (dropWhileEnd, nub, sort)
import Data.Text qualified as T
import System.Directory (setCurrentDirectory)
import System.Environment (getArgs, getEnvironment)
import System.Exit (ExitCode (..), exitFailure)
import System.IO (hPutStr, hPutStrLn, stderr)
import System.Process (CreateProcess (..), callProcess, proc, readCreateProcessWithExitCode, readProcessWithExitCode)

data Command
  = -- | @regenerate [--only PATH]… [--allow-dirty]@
    Regenerate [FilePath] AllowDirty
  | Check
  | UpdateGoldens [String]
  | Help

-- | Whether @regenerate@ may start from an already-modified corpus.
--
-- Regeneration overwrites the corpus in place, so starting dirty destroys any
-- uncommitted edit with no way to tell afterwards what came from the generator
-- and what was already there. The guard is the default; local iteration that
-- knowingly wants it can opt out.
data AllowDirty = RefuseDirty | AllowDirty
  deriving stock (Eq)

main :: IO ()
main = do
  command <- parseCommand <$> getArgs
  case command of
    Left message -> hPutStrLn stderr message >> hPutStrLn stderr helpText >> exitFailure
    Right Help -> putStrLn helpText
    Right (UpdateGoldens testArguments) -> updateGoldens testArguments
    Right Check -> runRegeneration True [] RefuseDirty
    Right (Regenerate onlyPaths allowDirty) -> runRegeneration False onlyPaths allowDirty

parseCommand :: [String] -> Either String Command
parseCommand [] = Right Help
parseCommand ["--help"] = Right Help
parseCommand ["-h"] = Right Help
parseCommand ("regenerate" : args) =
  Regenerate
    <$> parseOnly [arg | arg <- args, arg /= "--allow-dirty"]
    <*> Right (if "--allow-dirty" `elem` args then AllowDirty else RefuseDirty)
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

runRegeneration :: Bool -> [FilePath] -> AllowDirty -> IO ()
runRegeneration checking onlyPaths allowDirty = do
  repoRoot <- resolveRepoRoot
  setCurrentDirectory repoRoot
  planResult <- loadCorpusPlan repoRoot
  (allEntries, exemptions) <- either dieMany pure planResult
  selected <- selectEntries onlyPaths allEntries
  let paths = corpusPaths allEntries
  -- Both modes start from a clean corpus. `check` always did; `regenerate` did
  -- not, so it would silently overwrite uncommitted corpus edits.
  if checking || allowDirty == RefuseDirty then requireCleanCorpus paths else pure ()
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
    hPutStrLn stderr "conformance corpus requires clean corpus paths before scaffolding:"
    hPutStr stderr statusText
    hPutStrLn stderr ""
    hPutStrLn stderr "Commit or stash the listed paths, or discard them with:"
    hPutStrLn stderr ("  git checkout -- " <> unwords (nub (sort paths)))
    hPutStrLn stderr "Pass --allow-dirty to regenerate over them anyway (local iteration only)."
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
runEntry _ FrozenCorpus {ceOutDir} =
  putStrLn ("frozen " <> ceOutDir <> " (historical authored corpus; verification only)")
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
  -- First, because the other two checks are both scoped to the plan's out-dirs:
  -- a suite that fell out of the plan is invisible to them by construction.
  coverageErrors <- checkSuiteCoverage repoRoot entries
  unless (null coverageErrors) (dieMany coverageErrors)
  putStrLn ("suite coverage: ok (" <> show (length entries) <> " plan entries)")
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
      "  keiro-dsl-corpus-regen regenerate [--only REPOSITORY-RELATIVE-OUT-DIR]... [--allow-dirty]",
      "  keiro-dsl-corpus-regen check",
      "  keiro-dsl-corpus-regen update-goldens [TEST-ARGUMENT]...",
      "",
      "The driver derives ordinary scaffold invocations from tracked records and",
      "uses keiro-dsl/test/conformance-corpus-manifest.txt only for workspace paths,",
      "ordered skeleton runs, explicitly frozen historical corpora, extra CLI flags,",
      "and reviewed inventory exemptions. Frozen corpora remain covered by ledger,",
      "disk, and Cabal checks but are not replayed through current authoring defaults.",
      "It drives the public keiro-dsl CLI, never forces overwrites, never touches",
      "create-once files, and never commits. Review git status and git diff afterward.",
      "",
      "Both commands refuse to start over a modified corpus, so regeneration cannot",
      "silently overwrite an uncommitted edit. --allow-dirty opts out for local",
      "iteration; it is never correct in CI."
    ]
