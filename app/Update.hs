{-# LANGUAGE OverloadedStrings #-}

module Update (onUpdate) where

import Control.Applicative ((<|>))
import Control.Monad (when)
import Data.Aeson (FromJSON (..), eitherDecodeStrictText, withObject, (.:), (.:?), (.!=))
import Data.HashMap.Strict (HashMap)
import qualified Data.HashMap.Strict as HM
import Data.List (intercalate, isPrefixOf)
import Data.Maybe (fromMaybe)
import qualified Data.Text.IO as T
import System.Directory (doesFileExist)
import System.FilePath ((</>))

import Pagda (Config, getProjectRoot, nixFlags, runProcess_)

onUpdate :: Config -> [String] -> IO ()
onUpdate cfg args = do
  root <- getProjectRoot
  let (inputs, nixArgs) = break ("-" `isPrefixOf`) args
      requested = map splitInput inputs
      splitInput input = case break (== '@') input of
        (name, []) -> (name, Nothing)
        (name, _:url) -> (name, Just url)
  when (any (\(name, url) -> null name || url == Just "") requested) $
    fail "update: expected INPUT or INPUT@URL with a non-empty input and URL"
  resolved <- if null requested then pure [] else do
    let lockFile = root </> "flake.lock"
    exists <- doesFileExist lockFile
    when (not exists) $
      fail $ "update: input shorthand requires a local " ++ lockFile
        ++ "; run pagda update first to create the lockfile"
    contents <- T.readFile lockFile
    graph <- either (fail . (("update: invalid " ++ lockFile ++ ": ") ++)) pure $
      eitherDecodeStrictText contents
    pure [(resolvePath graph name, url) | (name, url) <- requested]
  runProcess_ "nix" $
    ["--experimental-features", "nix-command flakes", "flake", "update", "--flake", root]
      ++ map fst resolved
      ++ concat [["--override-input", name, url] | (name, Just url) <- resolved]
      ++ nixArgs ++ nixFlags cfg

splitPath :: String -> [String]
splitPath "" = []
splitPath s = case break (== '/') s of
  (name, []) -> [name]
  (name, _:rest) -> name : splitPath rest

data InputRef = Node String | Follows [String]

instance FromJSON InputRef where
  parseJSON value = (Node <$> parseJSON value) <|> (Follows <$> parseJSON value)

newtype LockNode = LockNode (HashMap String InputRef)

instance FromJSON LockNode where
  parseJSON = withObject "lock node" $ \o -> LockNode <$> o .:? "inputs" .!= HM.empty

data LockGraph = LockGraph String (HashMap String LockNode)

instance FromJSON LockGraph where
  parseJSON = withObject "lock graph" $ \o -> LockGraph <$> o .: "root" <*> o .: "nodes"

resolvePath :: LockGraph -> String -> String
resolvePath (LockGraph root nodes) name =
  fromMaybe name $ intercalate "/" <$> (resolve (splitPath name) <|> inferred)
  where
    inferred = if '/' `elem` name then Nothing else resolve ["agda-nix", name]
    resolve = restart []
    restart seen path
      | path `elem` seen = Nothing
      | otherwise = walk (path:seen) root [] path
    walk _ _ canonical [] = Just (reverse canonical)
    walk seen node canonical (part:rest) = do
      LockNode inputs <- HM.lookup node nodes
      ref <- HM.lookup part inputs
      case ref of
        Node next -> walk seen next (part:canonical) rest
        Follows path -> restart seen (path ++ rest)
