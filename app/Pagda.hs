{-# LANGUAGE LambdaCase #-}

-- | Core logic shared by the @pagda@ and @agda-check@ executables: the config
-- record, project-root discovery, and building the project's agda.
module Pagda
  ( UseUntracked (..)
  , Config (..)
  , getProjectRoot
  , getUntracked
  , hasUncommittedFiles
  , getUseUntracked
  , buildDerivation
  , runProcess_
  , nixFlags
  , genAgda
  ) where

import Data.Char (toLower)
import System.Directory (createDirectoryIfMissing, doesFileExist, getCurrentDirectory)
import System.Exit (ExitCode (..), exitWith)
import System.FilePath (takeDirectory, (</>))
import System.IO (hFlush, stdout)
import System.Process (rawSystem, readProcessWithExitCode)

data UseUntracked = UseUntrackedTrue | UseUntrackedFalse | UseUntrackedAsk

data Config = Config
  { useUntracked :: UseUntracked
  , warnUntracked :: Bool
  , quiet :: Bool
  }

-- | Untracked files in the working tree, honoring .gitignore. Outside
-- a git repository this returns nothing rather than failing.
getUntracked :: IO [String]
getUntracked = do
  root <- getProjectRoot
  (code, out, _) <- readProcessWithExitCode "git" ["-C", root, "ls-files", "--others", "--exclude-standard"] ""
  return $ case code of
    ExitSuccess -> filter (not . null) (lines out)
    ExitFailure _ -> []

hasUncommittedFiles :: IO Bool
hasUncommittedFiles = not . null <$> getUntracked

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
          parent
            | parent == dir -> fail "Unable to find project root (no flake.nix found)"
            | otherwise -> go parent

getUseUntracked :: Config -> IO Bool
getUseUntracked cfg = case useUntracked cfg of
  UseUntrackedTrue -> return True
  UseUntrackedFalse -> return False
  UseUntrackedAsk -> do
    putStr "Do you want to use untracked files for this build? [y/n]: "
    hFlush stdout
    reply <- getLine
    return $ map toLower reply `elem` ["y", "yes"]

buildDerivation :: Config -> Maybe String -> IO String
buildDerivation cfg mderiv = do
  root <- getProjectRoot
  hasUncommitted <- hasUncommittedFiles
  prefix <-
    if hasUncommitted
      then do
        useUntrackedFlag <- getUseUntracked cfg
        return $ if useUntrackedFlag then "path:" else ""
      else return ""
  return $ prefix ++ root ++ "#" ++ maybe "default" id mderiv

runProcess_ :: String -> [String] -> IO ()
runProcess_ cmd args = rawSystem cmd args >>= \case
  ExitSuccess -> return ()
  code -> exitWith code

-- | Extra nix flags implied by the config (currently just --quiet).
nixFlags :: Config -> [String]
nixFlags cfg = ["--quiet" | quiet cfg]

-- | Build the project's agda (with its dependencies) and link it at a stable
-- path, .pagda/agda, regardless of the working directory. The out-link is a GC
-- root, so the agda survives `nix-collect-garbage`. Returns the agda binary's
-- path.
genAgda :: Config -> IO FilePath
genAgda cfg = do
  root <- getProjectRoot
  installable <- buildDerivation cfg (Just "agda")
  let link = root </> ".pagda" </> "agda"
  createDirectoryIfMissing True (takeDirectory link)
  runProcess_ "nix" $
    [ "--experimental-features"
    , "nix-command flakes"
    , "build"
    , installable
    , "--out-link"
    , link
    ]
      ++ nixFlags cfg
  return (link </> "bin" </> "agda")
