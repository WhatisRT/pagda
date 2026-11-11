{-# LANGUAGE LambdaCase #-}

module Main (main) where

import Options.Applicative
import System.Directory (canonicalizePath, createDirectoryIfMissing, doesFileExist, findExecutable, getHomeDirectory, getCurrentDirectory, getSymbolicLinkTarget, listDirectory, pathIsSymbolicLink, removeFile, removePathForcibly)
import System.FilePath (isPathSeparator, takeDirectory, takeExtension, takeFileName, (</>))
import System.IO (hFlush, hPutStrLn, stdout, stderr)
import System.IO.Error (isUserError, ioeGetErrorString)
import System.Exit (ExitCode(..), exitFailure)
import GHC.IO.Encoding (setLocaleEncoding, utf8)
import Control.Applicative ((<|>))
import Control.Monad (filterM, when)
import Data.List (intercalate, isPrefixOf, sort)
import Data.Maybe (fromMaybe, isJust)
import Data.Version (showVersion)
import Paths_pagda (version)
import Data.HashMap.Strict (HashMap)
import qualified Data.HashMap.Strict as HM
import Control.Exception (catch, IOException, SomeException, fromException, throwIO, displayException)

import AgdaLib
import Templates
import Pagda
  ( UseUntracked(..), Config(..), getProjectRoot, getUntracked
  , buildDerivation, runProcess_, nixFlags, genAgda )

data CliConfig = CliConfig
  { cliUseUntracked :: Maybe UseUntracked
  , cliWarnUntracked :: Maybe Bool
  , cliQuiet :: Bool
  }

data PagdaOpts
  = Init (Maybe String) (Maybe FilePath) Bool Bool
  | Build (Maybe String)
  | GenAgda Bool
  | Shell (Maybe String)
  | AgdaLib2Nix FilePath
  | Regenerate
  | Check [String]
  | Doc
  | GenCi Bool Bool
  | Clean
  | Debug
  deriving Show

pagdaParser :: Parser PagdaOpts
pagdaParser = subparser
  ( command "init" (info (initCmd <**> helper)
      (progDesc "Initialize a project (use --existing to add pagda to an existing one)"))
  <> command "build" (info (Build <$> buildArg <**> helper)
      (progDesc "Build a project"))
  <> command "gen-agda" (info
      (GenAgda <$> switch (long "print-path" <> help "Print the path to the agda binary on stdout") <**> helper)
      (progDesc "Build agda (with the project's dependencies) and link it at .pagda/agda"))
  <> command "shell" (info (Shell <$> buildArg <**> helper)
      (progDesc "Launch an interactive shell"))
  <> command "debug" (info (pure Debug <**> helper)
      (progDesc "Debug information"))
  <> command "agdaLib2nix" (info (AgdaLib2Nix <$> agdaLibArg <**> helper)
      (progDesc "Generate a nix derivation based on an agda-lib file"))
  <> command "regenerate" (info (pure Regenerate <**> helper)
      (progDesc "Regenerate flake.nix from the current template"))
  <> command "check" (info (Check <$> checkArgs <**> helper)
      (progDesc "Typecheck the project (or a file) with agda; extra arguments are passed to agda"
        <> forwardOptions))
  <> command "doc" (info (pure Doc <**> helper)
      (progDesc "Build browsable HTML documentation for the project"))
  <> command "gen-ci" (info (GenCi
        <$> switch (long "pages" <> help "Also build the docs and deploy them to GitHub Pages")
        <*> switch (long "cache" <> help "Cache the Nix store via the GitHub Actions cache")
        <**> helper)
      (progDesc "Write a GitHub Actions CI workflow (.github/workflows/ci.yml)"))
  <> command "clean" (info (pure Clean <**> helper)
      (progDesc "Remove build artifacts (_build, result*, .pagda)"))
  )
  where
    initCmd = Init
      <$> optional (argument str (metavar "[PROJECT_NAME]" <> help "Project name (prompted if omitted)"))
      <*> optional (argument str (metavar "[PROJECT_ROOT]" <> help "Project root directory (prompted if omitted)"))
      <*> switch (long "here" <> help "Initialize in the current directory")
      <*> switch (long "existing" <> help "Add pagda to an existing project in the current directory")
    buildArg = optional $ argument str (metavar "[DERIVATION]" <> help "Optional target (default: default)")
    agdaLibArg = argument str (metavar "AGDA_LIB_FILE" <> help "Path to .agda-lib file")
    -- forwardOptions (above) lets unrecognized flags through to here, so they
    -- reach agda; a positional file (if any) lands here too.
    checkArgs = many (strArgument (metavar "[AGDA_ARG...]"
        <> help "File to check and/or flags to pass to agda"))

parserInfo :: ParserInfo (CliConfig, PagdaOpts)
parserInfo = info
  ( (,) <$> configParser <*> pagdaParser
    <**> simpleVersioner ("pagda " ++ showVersion version) <**> helper )
  $ fullDesc <> progDesc "Pagda - Agda project build tool using Nix"

parseUseUntracked :: String -> Maybe UseUntracked
parseUseUntracked v = case v of
  "true" -> Just UseUntrackedTrue
  "false" -> Just UseUntrackedFalse
  "ask" -> Just UseUntrackedAsk
  _ -> Nothing

parseBool :: String -> Maybe Bool
parseBool v = case v of
  "true" -> Just True
  "false" -> Just False
  _ -> Nothing

configParser :: Parser CliConfig
configParser = CliConfig
  <$> option (Just <$> maybeReader parseUseUntracked)
      ( long "useUntracked"
      <> metavar "true|false|ask"
      <> help "What to do with untracked files"
      <> value Nothing
      <> showDefaultWith (const "ask")
      )
  <*> option (Just <$> maybeReader parseBool)
      ( long "warnUntracked"
      <> metavar "true|false"
      <> help "Warn if recommended files are untracked"
      <> value Nothing
      <> showDefaultWith (const "true")
      )
  <*> switch
      ( long "quiet"
      <> help "Suppress pagda's informational output"
      )

hasNix :: IO Bool
hasNix = isJust <$> findExecutable "nix"

warnAboutUntrackedFiles :: IO ()
warnAboutUntrackedFiles = do
  untracked <- getUntracked
  let warns = filter (`elem` ["flake.nix", "flake.lock"]) $ map takeFileName untracked
  if null warns
    then return ()
    else putStrLn $ "The following files which are recommended to be part of your repository are untracked:\n  " ++ unwords warns

parseConfig :: FilePath -> IO (HashMap String String)
parseConfig path = do
  content <- readFile path `catch` (\(_ :: IOException) -> return "")
  return $ foldr addConfig HM.empty (lines content)
  where
    addConfig :: String -> HashMap String String -> HashMap String String
    addConfig line m = case parseLine line of
      Just (k, v) -> HM.insert k v m
      Nothing -> m
    parseLine :: String -> Maybe (String, String)
    parseLine line = do
      let (key, rest) = break (`elem` ('=':[' '..' '])) line
      guard $ not (null key) && not (null rest)
      let rest' = drop 1 rest
      let v = reverse $ dropWhile (`elem` (';':[' '..' '])) $ reverse rest'
      guard $ not (null v)
      return (key, v)
    guard :: Bool -> Maybe ()
    guard True = Just ()
    guard False = Nothing

adjustConfig :: CliConfig -> IO Config
adjustConfig cli = do
  root <- getProjectRoot
  home <- getHomeDir
  globalConfig <- parseConfig (home </> ".config" </> "pagda.conf")
  projectConfig <- parseConfig (root </> "pagda.conf")
  return Config
    { useUntracked = fromMaybe UseUntrackedAsk
        ( cliUseUntracked cli
        <|> (parseUseUntracked =<< HM.lookup "useUntracked" projectConfig)
        <|> (parseUseUntracked =<< HM.lookup "useUntracked" globalConfig)
        )
    , warnUntracked = fromMaybe True
        ( cliWarnUntracked cli
        <|> (parseBool =<< HM.lookup "warnUntracked" projectConfig)
        <|> (parseBool =<< HM.lookup "warnUntracked" globalConfig)
        )
    , quiet = cliQuiet cli
    }

getHomeDir :: IO FilePath
getHomeDir = getHomeDirectory

runNix :: String -> Maybe String -> Config -> IO ()
runNix cmd mderiv cfg = do
  der <- buildDerivation cfg mderiv
  let args = ["--experimental-features", "nix-command flakes", cmd, der] ++ nixFlags cfg
  runProcess_ "nix" args

-- | Build the project's agda via 'genAgda' and either print its path (machine
-- readable, with --print-path) or report where it was linked.
onGenAgda :: Config -> Bool -> IO ()
onGenAgda cfg printPath = do
  agdaBin <- genAgda cfg
  if printPath
    then putStrLn agdaBin
    else when (not (quiet cfg)) $ putStrLn $ "Linked agda at " ++ agdaBin

-- | Prompt for a value, re-asking until the answer is non-empty.
promptRequired :: String -> IO String
promptRequired label = do
  putStr (label ++ ": ")
  System.IO.hFlush stdout
  answer <- getLine
  if null answer then promptRequired label else return answer

-- | Prompt for a value, falling back to a default on an empty answer.
promptDefault :: String -> String -> IO String
promptDefault label def = do
  putStr (label ++ " [" ++ def ++ "]: ")
  System.IO.hFlush stdout
  answer <- getLine
  return $ if null answer then def else answer

lockFlake :: FilePath -> IO ()
lockFlake root = do
  canonicalRoot <- canonicalizePath root
  runProcess_ "nix"
    [ "--experimental-features", "nix-command flakes"
    , "flake", "lock", "path:" ++ canonicalRoot
    ]

-- | Initialize a project. By default this scaffolds a fresh project
-- (a new directory, or the current one with --here) with flake.nix,
-- flake.lock, a .agda-lib and a sample module; missing name/root are prompted
-- for. With --existing it instead adds pagda to an existing project
-- in the current directory. In this mode flake.nix and library files are
-- never overwritten and no sample module is added.
onInit :: Maybe String -> Maybe FilePath -> Bool -> Bool -> IO ()
onInit mname mroot here existing
  | existing = do
      when (here || isJust mroot) $
        fail "init: --existing operates on the current directory and cannot be combined with --here or PROJECT_ROOT"
      root <- getCurrentDirectory
      findAgdaLibs root >>= \case
        (lib:_) -> putStrLn $ "Found existing library file " ++ lib ++ "; leaving it untouched."
        [] -> do
          name <- maybe (promptRequired "Project name") return mname >>= validateProjectName
          writeFile (root </> name ++ ".agda-lib") (bareAgdaLib name)
          putStrLn $ "Wrote " ++ name ++ ".agda-lib"
      flakeExists <- doesFileExist (root </> "flake.nix")
      if flakeExists
        then putStrLn "flake.nix already exists; leaving it untouched (run `pagda regenerate` to update it)."
        else writeFile (root </> "flake.nix") flakeNix >> putStrLn "Wrote flake.nix"
      lockFlake root
  | otherwise = do
      when (here && isJust mroot) $
        fail "init: PROJECT_ROOT cannot be combined with --here"
      projectName <- maybe (promptRequired "Project name") return mname >>= validateProjectName
      projectRoot <- if here
        then getCurrentDirectory
        else maybe (promptDefault "Project root" projectName) return mroot
      createDirectoryIfMissing True projectRoot
      let isGenerated f = f == "flake.nix" || f == "flake.lock"
                       || f == "Test.agda" || takeExtension f == ".agda-lib"
      blockers <- sort . filter isGenerated <$> listDirectory projectRoot
      when (not (null blockers)) $
        fail $ "init: " ++ projectRoot ++ " already contains " ++ intercalate ", " blockers
             ++ "; refusing to overwrite. To add pagda to an existing project, run `pagda init --existing`."
      let subst = substitute "example" projectName
      writeFile (projectRoot </> "flake.nix") flakeNix
      writeFile (projectRoot </> projectName ++ ".agda-lib") (subst agdaLib)
      writeFile (projectRoot </> "Test.agda") testAgda
      lockFlake projectRoot

validateProjectName :: String -> IO String
validateProjectName name
  | null name || name == "." || name == ".." || '\0' `elem` name
      || name /= takeFileName name || any isPathSeparator name =
      fail $ "init: invalid project name " ++ show name ++ ": expected a name, not a path"
  | otherwise = return name

-- | The .agda-lib files in a directory (non-recursive).
findAgdaLibs :: FilePath -> IO [FilePath]
findAgdaLibs dir = filter ((== ".agda-lib") . takeExtension) <$> listDirectory dir

onDebug :: IO ()
onDebug = do
  putStrLn "Debug info:"
  root <- getProjectRoot
  putStrLn $ "Project root: " ++ root

-- | Typecheck inside the project's dev shell. With no arguments,
-- typecheck the whole library (@--build-library@); otherwise the
-- arguments (a file to check and/or agda flags) are passed straight
-- through to agda.
onCheck :: Config -> [String] -> IO ()
onCheck cfg agdaArgs = do
  root <- getProjectRoot
  installable <- buildDerivation cfg Nothing
  -- Record the dev environment in a per-project profile. A profile is a GC
  -- root, so the agda derivation (agda plus the libraries) survives
  -- `nix-collect-garbage` and is reused by later checks instead of rebuilt.
  let profile = root </> ".pagda" </> "check-env"
      agdaArgs' = if null agdaArgs then ["--build-library"] else agdaArgs
      args = [ "--experimental-features", "nix-command flakes"
             , "develop", installable, "--profile", profile ] ++ nixFlags cfg ++
             [ "--command", "agda" ] ++ agdaArgs'
  createDirectoryIfMissing True (takeDirectory profile)
  runProcess_ "nix" args
  -- Keep only the current generation, so old dev environments stop being GC roots.
  runProcess_ "nix" $
    [ "--experimental-features", "nix-command flakes"
    , "profile", "wipe-history", "--profile", profile ] ++ nixFlags cfg

onAgdaLib2Nix :: FilePath -> IO ()
onAgdaLib2Nix path = do
  lib <- parseAgdaLib path
  absPath <- canonicalizePath path
  putStrLn $ agdaLibToNix absPath lib

-- | Rewrite flake.nix in the project root from the current template. flake.nix
-- is a generated artifact, so this lets a project pick up template changes.
onRegenerate :: IO ()
onRegenerate = do
  root <- getProjectRoot
  let path = root </> "flake.nix"
  writeFile path flakeNix
  putStrLn $ "Regenerated " ++ path

-- | Remove build artifacts from the project root: Agda's @_build@, the nix
-- build symlinks (@result@, @result-*@) and pagda's own @.pagda@.
onClean :: IO ()
onClean = do
  root <- getProjectRoot
  entries <- listDirectory root
  outputLinks <- filterM (isNixOutputLink root) entries
  let internalArtifacts = filter (`elem` ["_build", ".pagda"]) entries
      artifacts = sort (internalArtifacts ++ outputLinks)
  if null artifacts
    then putStrLn "Nothing to clean."
    else mapM_
      (\f -> removeArtifact root f >> putStrLn ("Removed " ++ f))
      artifacts
  where
    removeArtifact root f
      | f `elem` ["_build", ".pagda"] = removePathForcibly (root </> f)
      | otherwise = removeFile (root </> f)

isNixOutputLink :: FilePath -> FilePath -> IO Bool
isNixOutputLink root name
  | name /= "result" && not ("result-" `isPrefixOf` name) = return False
  | otherwise = do
      let path = root </> name
      isLink <- pathIsSymbolicLink path
      if not isLink
        then return False
        else do
          target <- getSymbolicLinkTarget path
          return ("/nix/store/" `isPrefixOf` target)

-- | Write a GitHub Actions CI workflow to the project.
onGenCi :: Bool -> Bool -> IO ()
onGenCi pages cache = do
  root <- getProjectRoot
  let dir = root </> ".github" </> "workflows"
      path = dir </> "ci.yml"
  exists <- doesFileExist path
  if exists
    then putStrLn $ path ++ " already exists; not overwriting."
    else do
      createDirectoryIfMissing True dir
      writeFile path (ciYml pages cache)
      putStrLn $ "Wrote " ++ path

main :: IO ()
main = runPagda `catch` topHandler

-- | Report an uncaught error as a clean @pagda: <message>@
-- and exit non-zero. ExitCode exceptions — raised by optparse-applicative for
-- @--help@ and for argument-parsing errors — are re-thrown so its own exit
-- behaviour is preserved.
topHandler :: SomeException -> IO a
topHandler e = case fromException e of
  Just (ec :: ExitCode) -> throwIO ec
  Nothing -> do
    hPutStrLn stderr ("pagda: " ++ cleanMessage e)
    exitFailure
  where
    -- For IO errors (our `fail`s, missing/unreadable files, …) render the
    -- bare exception — unwrapping the SomeException strips GHC's backtrace —
    -- and drop the noisy "user error (…)" wrapper from our own `fail`s. Any
    -- other (genuinely unexpected) exception keeps its backtrace as a bug hint.
    cleanMessage ex = case fromException ex of
      Just ioe
        | isUserError ioe -> ioeGetErrorString ioe
        | otherwise       -> displayException (ioe :: IOException)
      Nothing -> displayException ex

runPagda :: IO ()
runPagda = do
  setLocaleEncoding utf8
  (cfg, opts) <- customExecParser (prefs showHelpOnEmpty) parserInfo

  case opts of
    AgdaLib2Nix path -> onAgdaLib2Nix path

    Regenerate -> onRegenerate

    GenCi pages cache -> onGenCi pages cache

    Clean -> onClean

    Debug -> onDebug

    _ -> do
      hasNixFlag <- hasNix
      if not hasNixFlag
        then hPutStrLn stderr "Nix not found. Please install Nix before proceeding." >> exitFailure
        else case opts of
          Init name root here existing -> onInit name root here existing
          _ -> do
            cfg' <- adjustConfig cfg
            when (warnUntracked cfg' && not (quiet cfg')) warnAboutUntrackedFiles

            case opts of
              Build mderiv -> runNix "build" mderiv cfg'
              GenAgda printPath -> onGenAgda cfg' printPath
              Shell mderiv -> runNix "develop" mderiv cfg'
              Check agdaArgs -> onCheck cfg' agdaArgs
              Doc -> runNix "build" (Just "docs") cfg'
