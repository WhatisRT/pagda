module UpdateTests (updateTests) where

import qualified Data.Aeson as Aeson
import qualified Data.Aeson.Key as Key
import Data.Aeson.Types (parseEither, withObject)
import qualified Data.ByteString as BS
import qualified Data.Text as Text
import System.Directory
  ( canonicalizePath
  , createDirectoryIfMissing
  , doesFileExist
  , removePathForcibly
  )
import System.IO.Extra (withTempDir)
import System.Environment (getEnvironment)
import System.Exit (ExitCode (..))
import System.FilePath ((</>))
import System.Process
  ( CreateProcess (..)
  , proc
  , readCreateProcessWithExitCode
  )
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit ((@?=), Assertion, assertFailure, testCase)

updateTests :: FilePath -> TestTree
updateTests pagda = testGroup "update"
  [ testCase "native arguments can override the update target" $
      withNixFixture $ \root env -> do
        let current = root </> "current"
            currentAgdaNix = root </> "current-agda-nix"
            currentOld = root </> "current-old-standard-library"
            target = root </> "target"
            targetOld = root </> "target-old-standard-library"
            replacement = root </> "replacement-standard-library"
        writeSource currentOld "current-old"
        writeSource targetOld "target-old"
        writeSource replacement "replacement"
        writeFlake currentAgdaNix
          [sourceInput "standard-library" currentOld]
          "inputs: {}"
        writeFlake current
          [flakeInput "agda-nix" currentAgdaNix]
          "inputs: {}"
        writeFlake target
          [sourceInput "standard-library" targetOld]
          "inputs: {}"

        runSuccessfully "seed current lock" env current "nix"
          ["flake", "lock", current]
        runSuccessfully "seed target lock" env target "nix"
          ["flake", "lock", target]
        currentBefore <- BS.readFile (current </> "flake.lock")
        runSuccessfully "forward target and native override" env current pagda
          [ "update", "--", "--flake", target
          , "--override-input", "standard-library", "path:" ++ replacement
          ]
        assertLockedPath (target </> "flake.lock") ["standard-library"] replacement
        BS.readFile (current </> "flake.lock") >>= (@?= currentBefore)
        targetBefore <- BS.readFile (target </> "flake.lock")
        let pin = "standard-library@path:" ++ replacement

        let subdir = current </> "subdir"
        createDirectoryIfMissing True subdir
        runSuccessfully "update from project subdirectory" env subdir pagda ["update", pin]
        assertLockedPath (current </> "flake.lock")
          ["agda-nix", "standard-library"] replacement
        BS.readFile (target </> "flake.lock") >>= (@?= targetBefore)

  , testCase "shorthand follows a renamed Agda parent" $
      withNixFixture $ \root env -> do
        let project = root </> "project"
            actual = root </> "actual-agda-parent"
            original = root </> "original-standard-library"
            replacement = root </> "replacement-standard-library"
        writeSource original "original"
        writeSource replacement "replacement"
        writeFlake actual
          [sourceInput "standard-library" original]
          "inputs: {}"
        writeFlake project
          [ flakeInput "actual" actual
          , followsInput "agda-nix" "actual"
          ]
          "inputs: {}"

        runSuccessfully "seed followed input lock" env project "nix"
          ["flake", "lock", project]

        runSuccessfully "pagda update followed input" env project pagda
          ["update", "standard-library@path:" ++ replacement]

        assertLockedPath (project </> "flake.lock")
          ["actual", "standard-library"] replacement

  , testCase "replacement does not fetch a missing original leaf" $
      withNixFixture $ \root env -> do
        let project = root </> "project"
            agdaNix = root </> "agda-parent"
            missing = root </> "missing-standard-library"
            replacement = root </> "replacement-standard-library"
        writeSource missing "original"
        writeSource replacement "replacement"
        writeFlake agdaNix
          [sourceInput "standard-library" missing]
          "inputs: {}"
        writeFlake project
          [flakeInput "agda-nix" agdaNix]
          "inputs: {}"

        runSuccessfully "seed original input lock" env project "nix"
          ["flake", "lock", project]
        removePathForcibly missing

        runSuccessfully "pagda update missing original" env project pagda
          ["update", "standard-library@path:" ++ replacement]

        assertLockedPath (project </> "flake.lock")
          ["agda-nix", "standard-library"] replacement

  , testCase "update does not evaluate project outputs" $
      withNixFixture $ \root env -> do
        let project = root </> "project"
            original = root </> "original-standard-library"
            replacement = root </> "replacement-standard-library"
        writeSource original "original"
        writeSource replacement "replacement"
        writeFlake project
          [sourceInput "standard-library" original]
          "inputs: throw \"fixture outputs were evaluated\""

        runSuccessfully "seed lock without evaluating outputs" env project "nix"
          ["flake", "lock", project]

        runSuccessfully "pagda update with throwing outputs" env project pagda
          ["update", "standard-library@path:" ++ replacement]

        assertLockedPath (project </> "flake.lock")
          ["standard-library"] replacement

  , testCase "shorthand requires a lock; update-all creates it" $
      withNixFixture $ \root env -> do
        let project = root </> "project"
            original = root </> "original"
            replacement = root </> "replacement"
            lock = project </> "flake.lock"
        writeSource original "original"
        writeSource replacement "replacement"
        writeFlake project [sourceInput "standard-library" original] "inputs: {}"
        declaration <- BS.readFile (project </> "flake.nix")
        (code, _, _) <- readCreateProcessWithExitCode
          (proc pagda ["update", "standard-library@path:" ++ replacement])
            {cwd = Just project, env = Just env} ""
        code @?= ExitFailure 1
        doesFileExist lock >>= (@?= False)
        BS.readFile (project </> "flake.nix") >>= (@?= declaration)

        runSuccessfully "update all without a lock" env project pagda ["update"]
        assertLockedPath lock ["standard-library"] original
        runSuccessfully "pin after creating the lock" env project pagda
          ["update", "standard-library@path:" ++ replacement]
        assertLockedPath lock ["standard-library"] replacement

  , testCase "native overrides remain usable without a lock" $
      withNixFixture $ \root env -> do
        let project = root </> "project"
            replacement = root </> "replacement"
        writeSource replacement "replacement"
        writeFlake project [sourceInput "dependency" (root </> "missing")] "inputs: {}"
        runSuccessfully "forward native override" env project pagda
          ["update", "--override-input", "dependency", "path:" ++ replacement]
        assertLockedPath (project </> "flake.lock") ["dependency"] replacement
  ]

withNixFixture :: (FilePath -> [(String, String)] -> Assertion) -> Assertion
withNixFixture action =
  withTempDir $ \root -> do
    let home = root </> "home"
        storeRoot = root </> "store"
    createDirectoryIfMissing True home
    createDirectoryIfMissing True storeRoot
    inherited <- getEnvironment
    let overrides =
          [ ("HOME", home)
          , ("NIX_REMOTE", "local?root=" ++ storeRoot)
          , ("NIX_CONFIG", unlines
              [ "experimental-features = nix-command flakes"
              , "flake-registry ="
              , "substituters ="
              ])
          ]
        overridden = map fst overrides
        env = overrides ++ filter ((`notElem` overridden) . fst) inherited
    action root env

runSuccessfully
  :: String
  -> [(String, String)]
  -> FilePath
  -> FilePath
  -> [String]
  -> Assertion
runSuccessfully label env workDir executable arguments = do
  (code, out, err) <- readCreateProcessWithExitCode
    (proc executable arguments) {cwd = Just workDir, env = Just env}
    ""
  case code of
    ExitSuccess -> pure ()
    ExitFailure status -> assertFailure $ unlines
      [ label ++ " failed with exit code " ++ show status
      , "stdout:"
      , out
      , "stderr:"
      , err
      ]

writeSource :: FilePath -> String -> IO ()
writeSource directory identity = do
  createDirectoryIfMissing True directory
  writeFile (directory </> "source-identity") (identity ++ "\n")

writeFlake :: FilePath -> [String] -> String -> IO ()
writeFlake directory inputs outputs = do
  createDirectoryIfMissing True directory
  writeFile (directory </> "flake.nix") $ unlines $
    [ "{"
    , "  inputs = {"
    ]
    ++ inputs
    ++ [ "  };"
       , "  outputs = " ++ outputs ++ ";"
       , "}"
       ]

flakeInput :: String -> FilePath -> String
flakeInput name path =
  "    " ++ name ++ ".url = " ++ show ("path:" ++ path) ++ ";"

sourceInput :: String -> FilePath -> String
sourceInput name path = unlines
  [ "    " ++ name ++ " = {"
  , "      url = " ++ show ("path:" ++ path) ++ ";"
  , "      flake = false;"
  , "    };"
  ]

followsInput :: String -> String -> String
followsInput name target =
  "    " ++ name ++ ".follows = " ++ show target ++ ";"

assertLockedPath :: FilePath -> [String] -> FilePath -> Assertion
assertLockedPath lockFile inputPath expectedPath = do
  bytes <- BS.readFile lockFile
  lock <- case Aeson.eitherDecodeStrict' bytes of
    Left err -> assertFailure ("invalid lock file " ++ lockFile ++ ": " ++ err)
      >> pure Aeson.Null
    Right value -> pure value
  expected <- canonicalizePath expectedPath
  case lockedPathAt inputPath lock of
    Left err -> assertFailure ("cannot inspect " ++ lockFile ++ ": " ++ err)
    Right actual -> do
      resolved <- canonicalizePath actual
      resolved @?= expected

lockedPathAt :: [String] -> Aeson.Value -> Either String FilePath
lockedPathAt inputPath lock = do
  root <- field "root" lock >>= stringValue
  nodes <- field "nodes" lock
  node <- walk nodes root inputPath
  field "locked" node >>= field "path" >>= stringValue
  where
    walk nodes nodeName [] = field nodeName nodes
    walk nodes nodeName (input : rest) = do
      node <- field nodeName nodes
      inputs <- field "inputs" node
      next <- field input inputs >>= stringValue
      walk nodes next rest

field :: String -> Aeson.Value -> Either String Aeson.Value
field name = parseEither $ withObject "JSON object" $ \object ->
  object Aeson..: Key.fromString name

stringValue :: Aeson.Value -> Either String String
stringValue (Aeson.String value) = Right (Text.unpack value)
stringValue value = Left ("expected JSON string, got " ++ show value)
