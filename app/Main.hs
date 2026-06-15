{-# LANGUAGE LambdaCase #-}

module Main (main) where

import Options.Applicative
import System.Directory (canonicalizePath, createDirectoryIfMissing, doesFileExist, findExecutable, getHomeDirectory, getCurrentDirectory)
import System.FilePath (takeDirectory, takeFileName, (</>))
import System.Process (callProcess, readProcess)
import System.IO (hFlush, stdout)
import GHC.IO.Encoding (setLocaleEncoding, utf8)
import Data.Char (toLower)
import Data.Maybe (isJust)
import Data.HashMap.Strict (HashMap)
import qualified Data.HashMap.Strict as HM
import Control.Exception (catch, IOException)

import AgdaLib
import Templates

data UseUntracked = UseUntrackedTrue | UseUntrackedFalse | UseUntrackedAsk

data Config = Config
  { useUntracked :: UseUntracked
  , warnUntracked :: Bool
  }

data PagdaOpts
  = Init String FilePath
  | Build (Maybe String)
  | GenAgda
  | Shell (Maybe String)
  | AgdaLib2Nix FilePath
  | Regenerate
  | Check [String]
  | Debug
  deriving Show

pagdaParser :: Parser Config -> Parser PagdaOpts
pagdaParser cfg = subparser
  ( command "init" (info (initCmd <**> helper)
      (progDesc "Initialize a new project"))
  <> command "build" (info (Build <$> buildArg <**> helper)
      (progDesc "Build a project"))
  <> command "gen-agda" (info (pure GenAgda <**> helper)
      (progDesc "Generate a symlink to agda"))
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
  )
  where
    initCmd = Init
      <$> argument str (metavar "PROJECT_NAME" <> help "Project name")
      <*> argument str (metavar "PROJECT_ROOT" <> help "Project root directory")
    buildArg = optional $ argument str (metavar "[DERIVATION]" <> help "Optional target (default: default)")
    agdaLibArg = argument str (metavar "AGDA_LIB_FILE" <> help "Path to .agda-lib file")
    -- forwardOptions (above) lets unrecognized flags through to here, so they
    -- reach agda; a positional file (if any) lands here too.
    checkArgs = many (strArgument (metavar "[AGDA_ARG...]"
        <> help "File to check and/or flags to pass to agda"))

parserInfo :: ParserInfo (Config, PagdaOpts)
parserInfo = info ((,) <$> configParser <*> pagdaParser configParser <**> helper)
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

configParser :: Parser Config
configParser = Config
  <$> option (maybeReader parseUseUntracked)
      ( long "useUntracked"
      <> metavar "true|false|ask"
      <> help "What to do with untracked files"
      <> value UseUntrackedAsk
      <> showDefaultWith (\_ -> "ask")
      )
  <*> option (maybeReader parseBool)
      ( long "warnUntracked"
      <> metavar "true|false"
      <> help "Warn if recommended files are untracked"
      <> value True
      <> showDefault
      )

hasNix :: IO Bool
hasNix = isJust <$> findExecutable "nix"

getUntracked :: IO [String]
getUntracked = do
  result <- readProcess "git" ["ls-files", "--others"] ""
  return $ filter (not . null) (lines result)

hasUncommittedFiles :: IO Bool
hasUncommittedFiles = do
  untracked <- getUntracked
  return $ not (null untracked)

warnAboutUntrackedFiles :: IO ()
warnAboutUntrackedFiles = do
  untracked <- getUntracked
  let warns = filter (`elem` ["flake.nix", "flake.lock"]) $ map takeFileName untracked
  if null warns
    then return ()
    else putStrLn $ "The following files which are recommended to be part of your repository are untracked:\n  " ++ unwords warns

getProjectRoot :: IO FilePath
getProjectRoot = do
  current <- getCurrentDirectory
  go current
  where
    go :: FilePath -> IO FilePath
    go dir = do
      exists <- doesFileExist (dir </> "flake.nix")
      if exists
        then return dir
        else case takeDirectory dir of
          parent | parent == dir -> fail "Unable to find project root (no flake.nix found)"
                 | otherwise -> go parent

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

adjustConfig :: Config -> IO Config
adjustConfig cfg = do
  root <- getProjectRoot
  home <- getHomeDir

  globalConfig <- parseConfig (home </> ".config" </> "pagda.conf")
  let cfg' = applyConfig globalConfig cfg

  projectConfig <- parseConfig (root </> "pagda.conf")
  let cfg'' = applyConfig projectConfig cfg'

  return cfg''
  where
    applyConfig :: HashMap String String -> Config -> Config
    applyConfig m c = c
      { useUntracked = maybe (useUntracked c) id $
          parseUseUntracked =<< HM.lookup "useUntracked" m
      , warnUntracked = maybe (warnUntracked c) id $
          parseBool =<< HM.lookup "warnUntracked" m
      }

getHomeDir :: IO FilePath
getHomeDir = getHomeDirectory

getUseUntracked :: Config -> IO Bool
getUseUntracked cfg = case useUntracked cfg of
  UseUntrackedTrue -> return True
  UseUntrackedFalse -> return False
  UseUntrackedAsk -> do
    putStr "Do you want to use untracked files for this build? [y/n]: "
    System.IO.hFlush stdout
    reply <- getLine
    return $ map toLower reply `elem` ["y", "yes"]

buildDerivation :: Config -> Maybe String -> IO String
buildDerivation cfg mderiv = do
  hasUncommitted <- hasUncommittedFiles
  prefix <- if hasUncommitted
    then do
      useUntrackedFlag <- getUseUntracked cfg
      return $ if useUntrackedFlag then "path:" else ""
    else return ""
  return $ prefix ++ ".#" ++ maybe "default" id mderiv

runNix :: String -> Maybe String -> Config -> Bool -> IO ()
runNix cmd mderiv cfg useDerivation = do
  der <- if useDerivation
    then buildDerivation cfg mderiv
    else return ""
  let args = ["--experimental-features", "nix-command flakes", cmd] ++ words der
  callProcess "nix" args

onInit :: String -> FilePath -> IO ()
onInit projectName projectRoot = do
  createDirectoryIfMissing True projectRoot
  let subst = substitute "example" projectName
  writeFile (projectRoot </> "flake.nix") flakeNix
  writeFile (projectRoot </> projectName ++ ".agda-lib") $ subst agdaLib
  writeFile (projectRoot </> "Test.agda") testAgda

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
             , "develop", installable, "--profile", profile
             , "--command", "agda" ] ++ agdaArgs'
  createDirectoryIfMissing True (takeDirectory profile)
  callProcess "nix" args
  -- Keep only the current generation, so old dev environments stop being GC roots.
  callProcess "nix"
    [ "--experimental-features", "nix-command flakes"
    , "profile", "wipe-history", "--profile", profile ]

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

main :: IO ()
main = do
  setLocaleEncoding utf8
  (cfg, opts) <- customExecParser (prefs showHelpOnEmpty) parserInfo

  case opts of
    Init name root -> onInit name root

    AgdaLib2Nix path -> onAgdaLib2Nix path

    Regenerate -> onRegenerate

    Debug -> onDebug

    _ -> do
      hasNixFlag <- hasNix
      if not hasNixFlag
        then putStrLn "Nix not found. Please install Nix before proceeding."
        else do
          cfg' <- adjustConfig cfg
          if warnUntracked cfg'
            then warnAboutUntrackedFiles
            else return ()

          case opts of
            Build mderiv -> runNix "build" mderiv cfg' True
            GenAgda -> runNix "build" (Just ".#agda") cfg' False
            Shell mderiv -> runNix "develop" mderiv cfg' True
            Check agdaArgs -> onCheck cfg' agdaArgs
