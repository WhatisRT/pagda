-- End-to-end tests for the pagda executable, built on tasty-golden.
--
-- Each directory under test/e2e/cases describes one test case:
--
--   cmd            (required) arguments passed to pagda, whitespace-separated
--   initial/       (optional) file tree the work directory starts from
--   home/          (optional) file tree for the isolated $HOME
--   bin/           (optional) stub executables prepended to $PATH
--   setup.sh       (optional) shell script run in the work directory before pagda
--   stdin          (optional) text piped to pagda's stdin
--   cwd            (optional) subdirectory of the work directory to run pagda in
--   output.golden  golden rendering of the outcome: exit code, stdout,
--                  stderr and the complete file tree of the work directory
--
-- Each case runs in a fresh sandbox under the system temp directory with an
-- isolated $HOME, so global configuration never leaks in. Occurrences of the
-- work directory and the isolated home directory in the output are replaced
-- by $TESTDIR and $TESTHOME, GHC HasCallStack backtraces are stripped from
-- stderr, and .git directories are excluded, so goldens are independent of
-- the machine and GHC version.
--
-- Useful test options (pass via cabal test e2e --test-options='...'):
--   --accept   (re)generate the golden files from the actual results
--   -p PATTERN run only matching cases, e.g. -p init
--   -l         list all cases

module Main (main) where

import Control.Monad (filterM, when)
import Control.Monad.Extra (ifM)
import Data.ByteString.Lazy (ByteString, fromStrict)
import Data.Char (isSpace)
import Data.List (isInfixOf, isPrefixOf, sort)
import Data.List.Extra (replace, trim)
import Data.Maybe (fromMaybe)
import qualified Data.Text as T
import Data.Text.Encoding (encodeUtf8)
import GHC.IO.Encoding (setLocaleEncoding, utf8)
import System.Directory.Extra
import System.Environment (getEnvironment, lookupEnv)
import System.Exit (ExitCode (..), die)
import System.FilePath (makeRelative, searchPathSeparator, splitDirectories, takeDirectory, (</>))
import System.IO (readFile')
import System.Process (CreateProcess (..), proc, readCreateProcessWithExitCode)
import Test.Tasty (TestTree, defaultMain, testGroup)
import Test.Tasty.Golden (goldenVsStringDiff)

main :: IO ()
main = do
  -- Golden files are UTF-8 regardless of the system locale.
  setLocaleEncoding utf8
  casesDir <- fromMaybe ("test" </> "e2e" </> "cases") <$> lookupEnv "PAGDA_E2E_CASES"
  pagdaBin <- findPagda
  agdaCheckBin <- findAgdaCheck
  names <- listDirectory casesDir
    >>= filterM (\n -> doesDirectoryExist (casesDir </> n))
  defaultMain $ testGroup "pagda e2e"
    [caseTest pagdaBin agdaCheckBin (casesDir </> name) name | name <- sort names]

findPagda :: IO FilePath
findPagda = lookupEnv "PAGDA_BIN" >>= \mbin -> case mbin of
  Just p -> canonicalizePath p
  Nothing -> findExecutable "pagda"
    >>= maybe (die "pagda executable not found on PATH (set PAGDA_BIN to override)") return

-- | The agda-check executable, if available (AGDACHECK_BIN or on PATH). Only
-- cases whose `program` is "agda-check" need it.
findAgdaCheck :: IO (Maybe FilePath)
findAgdaCheck = lookupEnv "AGDACHECK_BIN" >>= \menv -> case menv of
  Just p -> Just <$> canonicalizePath p
  Nothing -> findExecutable "agda-check"

caseTest :: FilePath -> Maybe FilePath -> FilePath -> String -> TestTree
caseTest pagdaBin agdaCheckBin caseDir name =
  goldenVsStringDiff name diffCmd (caseDir </> "output.golden")
    (runCase pagdaBin agdaCheckBin caseDir name)
  where
    diffCmd ref new = ["diff", "-u", ref, new]

-- | Run one case in a fresh sandbox and render the outcome as the golden
-- manifest. A case's optional `program` file picks the executable to run
-- ("pagda", the default, or "agda-check").
runCase :: FilePath -> Maybe FilePath -> FilePath -> String -> IO ByteString
runCase pagdaBin agdaCheckBin caseDir name = do
  cmdArgs <- words <$> readFile' (caseDir </> "cmd")
  program <- readProgram caseDir
  bin <- case program of
    "agda-check" -> maybe (die "agda-check executable not found (set AGDACHECK_BIN)") return agdaCheckBin
    _ -> return pagdaBin
  tmp <- getTemporaryDirectory
  let sandbox = tmp </> "pagda-e2e" </> name
      workDir = sandbox </> "work"
      homeDir = sandbox </> "home"
  removePathForcibly sandbox
  createDirectoryIfMissing True workDir
  createDirectoryIfMissing True homeDir
  copyTreeIfExists (caseDir </> "initial") workDir
  copyTreeIfExists (caseDir </> "home") homeDir

  env' <- caseEnvironment caseDir homeDir
  norm <- normalizer workDir homeDir

  runSetup caseDir workDir env'
  stdinContents <- readFileIfExists (caseDir </> "stdin")
  cwdRel <- trim <$> readFileIfExists (caseDir </> "cwd")
  let runDir = if null cwdRel then workDir else workDir </> cwdRel
  (code, out, err) <- readCreateProcessWithExitCode
    (proc bin cmdArgs) { cwd = Just runDir, env = Just env' }
    stdinContents
  let exitN = case code of
        ExitSuccess -> 0
        ExitFailure n -> n

  files <- workFiles workDir
  contents <- mapM (\rel -> (,) rel <$> readFile' (workDir </> rel)) files
  return $ toBytes $ norm $ render exitN out (stripBacktrace err) contents
  where
    toBytes = fromStrict . encodeUtf8 . T.pack

render :: Int -> String -> String -> [(FilePath, String)] -> String
render exitN out err files = unlines . concat $
  [ ["exit code: " ++ show exitN]
  , section "stdout" out
  , section "stderr" err
  ] ++ [section ("file: " ++ rel) c | (rel, c) <- files]
  where
    section title body =
      ("=== " ++ title ++ " ===")
      : lines body
      ++ ["\\ no newline at end" | not (null body) && last body /= '\n']

-- | Environment for the child processes: isolated $HOME, the case's
-- stub bin directory (if any) prepended to $PATH, a UTF-8 locale (pagda
-- writes templates containing non-ASCII characters), and a git ceiling at
-- the sandbox so git cannot discover a repository above it.
caseEnvironment :: FilePath -> FilePath -> IO [(String, String)]
caseEnvironment caseDir homeDir = do
  extraPath <- ifM (doesDirectoryExist (caseDir </> "bin"))
    ((: []) <$> canonicalizePath (caseDir </> "bin"))
    (return [])
  baseEnv <- getEnvironment
  -- The sandbox (parent of work/ and home/). Pinning GIT_CEILING_DIRECTORIES
  -- here stops git from walking up past it, so a case with no `git init` runs
  -- genuinely outside any repository even when the system temp dir happens to
  -- live inside one (otherwise git would find that outer repo).
  gitCeiling <- canonicalizePath (takeDirectory homeDir)
  let basePath = fromMaybe "" (lookup "PATH" baseEnv)
      path' = concatMap (++ [searchPathSeparator]) extraPath ++ basePath
      hasUtf8Locale = any (\k -> maybe False ("UTF-8" `isInfixOf`) (lookup k baseEnv))
                          ["LC_ALL", "LC_CTYPE", "LANG"]
      localeOverride = [("LC_ALL", "C.UTF-8") | not hasUtf8Locale]
      overridden = "HOME" : "PATH" : "GIT_CEILING_DIRECTORIES" : map fst localeOverride
  return $ ("HOME", homeDir) : ("PATH", path')
        : ("GIT_CEILING_DIRECTORIES", gitCeiling) : localeOverride
        ++ [(k, v) | (k, v) <- baseEnv, k `notElem` overridden]

runSetup :: FilePath -> FilePath -> [(String, String)] -> IO ()
runSetup caseDir workDir env' = do
  setupExists <- doesFileExist (caseDir </> "setup.sh")
  when setupExists $ do
    setupAbs <- canonicalizePath (caseDir </> "setup.sh")
    (code, out, err) <- readCreateProcessWithExitCode
      (proc "sh" [setupAbs]) { cwd = Just workDir, env = Just env' } ""
    case code of
      ExitSuccess -> return ()
      ExitFailure n -> fail $
        "setup.sh failed with exit code " ++ show n ++ "\n" ++ out ++ err

-- | Replace the sandbox paths (canonicalized and as given) by placeholders.
normalizer :: FilePath -> FilePath -> IO (String -> String)
normalizer workDir homeDir = do
  workC <- canonicalizePath workDir
  homeC <- canonicalizePath homeDir
  return $ replace workC "$TESTDIR" . replace homeC "$TESTHOME"
         . replace workDir "$TESTDIR" . replace homeDir "$TESTHOME"

-- | GHC >= 9.10 appends a HasCallStack backtrace to uncaught exceptions;
-- older compilers do not. Strip it so goldens are GHC-version-independent.
stripBacktrace :: String -> String
stripBacktrace s
  | null kept = ""
  | otherwise = unlines kept
  where
    isHeader l = "HasCallStack backtrace:" `isPrefixOf` dropWhile isSpace l
    upToHeader = takeWhile (not . isHeader) (lines s)
    kept = reverse (dropWhile (all isSpace) (reverse upToHeader))

-- | Relative paths of all files below the work directory, sorted,
-- skipping .git.
workFiles :: FilePath -> IO [FilePath]
workFiles workDir = do
  files <- listFilesRecursive workDir
  return $ sort
    [ rel
    | f <- files
    , let rel = makeRelative workDir f
    , ".git" `notElem` splitDirectories rel
    ]

readFileIfExists :: FilePath -> IO String
readFileIfExists path = ifM (doesFileExist path) (readFile' path) (return "")

-- | The program a case runs, from its optional `program` file ("pagda" default).
readProgram :: FilePath -> IO String
readProgram caseDir = do
  let path = caseDir </> "program"
  ifM (doesFileExist path) (filter (not . isSpace) <$> readFile' path) (return "pagda")

copyTreeIfExists :: FilePath -> FilePath -> IO ()
copyTreeIfExists src dst = do
  exists <- doesDirectoryExist src
  when exists $ copyTree src dst

copyTree :: FilePath -> FilePath -> IO ()
copyTree src dst = do
  createDirectoryIfMissing True dst
  names <- listDirectory src
  mapM_ copyEntry [n | n <- names, n /= ".git"]
  where
    copyEntry n = ifM (doesDirectoryExist (src </> n))
      (copyTree (src </> n) (dst </> n))
      (copyFile (src </> n) (dst </> n))
