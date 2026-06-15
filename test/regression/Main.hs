-- Golden regression tests for the agdaLib2nix command.
--
-- Each directory under test/regression/cases contains one .agda-lib file
-- and either an expected.nix golden file, or an expect-parse-failure marker
-- for inputs that must be rejected. Built on tasty-golden, so the suite
-- shares the e2e suite's conventions:
--
--   cabal test regression --test-options=--accept   (re)generate goldens
--   cabal test regression --test-options='-p name'   run matching cases
--   cabal test regression --test-options=-l          list all cases
module Main (main) where

import AgdaLib
import Control.Monad (filterM)
import Data.ByteString.Lazy (ByteString)
import qualified Data.ByteString.Lazy.Char8 as BL
import Data.List (isSuffixOf, sort)
import GHC.IO.Encoding (setLocaleEncoding, utf8)
import System.Directory (doesDirectoryExist, doesFileExist, listDirectory)
import System.FilePath ((</>))
import Test.Tasty (TestTree, defaultMain, testGroup)
import Test.Tasty.Golden (goldenVsStringDiff)
import Test.Tasty.HUnit (assertFailure, testCase)

casesDir :: FilePath
casesDir = "test" </> "regression" </> "cases"

main :: IO ()
main = do
  -- Goldens are UTF-8 regardless of the system locale (matches the e2e suite).
  setLocaleEncoding utf8
  names <- listDirectory casesDir >>= filterM (doesDirectoryExist . (casesDir </>))
  tests <- mapM caseTest (sort names)
  defaultMain $ testGroup "agdaLib2nix regression" tests

caseTest :: String -> IO TestTree
caseTest name = do
  let caseDir = casesDir </> name
  entries <- listDirectory caseDir
  libFile <- case filter (".agda-lib" `isSuffixOf`) entries of
    [f] -> return f
    fs -> fail $ caseDir ++ ": expected exactly one .agda-lib file, found " ++ show fs
  let libPath = caseDir </> libFile
      goldenPath = caseDir </> "expected.nix"
  expectFailure <- doesFileExist (caseDir </> "expect-parse-failure")
  return $
    if expectFailure
      then testCase name $ do
        content <- readFile libPath
        case parseAgdaLibSource content of
          Left _ -> return ()
          Right _ -> assertFailure "parsed successfully, but a parse failure was expected"
      else goldenVsStringDiff name diffCmd goldenPath (renderNix libPath)
  where
    diffCmd ref new = ["diff", "-u", ref, new]

-- | Parse the .agda-lib file and render its nix derivation, failing the
-- test if the input does not parse. The path is passed through verbatim
-- (as the executable does after canonicalizing) since pname/libraryFile
-- derive from it.
renderNix :: FilePath -> IO ByteString
renderNix libPath = do
  content <- readFile libPath
  case parseAgdaLibSource content of
    Left err -> fail $ "parse error:\n" ++ err
    Right lib -> return $ BL.pack (agdaLibToNix libPath lib)
