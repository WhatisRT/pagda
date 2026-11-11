module InitTests (initTests) where

import qualified Data.Aeson as Aeson
import qualified Data.Aeson.Key as Key
import Data.Aeson.Types (parseEither, withObject)
import qualified Data.ByteString as BS
import qualified Data.Text as Text
import System.Directory
  ( canonicalizePath
  , createDirectoryIfMissing
  , doesFileExist
  , executable
  , getPermissions
  , listDirectory
  , setPermissions
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

initTests :: FilePath -> TestTree
initTests pagda = testGroup "init"
  [ testCase "--existing locks an untracked flake" $
      withNixFixture $ \root env -> do
        let project = root </> "project"
            dependency = root </> "dependency"
        writeSource dependency "initial"
        writeProject project ("path:" ++ dependency)
        runSuccessfully "initialize Git repository" env project "git" ["init", "-q", "."]

        runSuccessfully "pagda init --existing" env project pagda ["init", "--existing"]

        assertLockedPath (project </> "flake.lock") "dependency" dependency

  , testCase "--existing preserves locked input revisions" $
      withNixFixture $ \root env -> do
        let project = root </> "project"
            dependency = root </> "dependency"
        writeSource dependency "original"
        runSuccessfully "initialize dependency repository" env dependency "git" ["init", "-q", "."]
        runSuccessfully "stage original dependency" env dependency "git" ["add", "."]
        runSuccessfully "commit original dependency" env dependency "git"
          ["commit", "-q", "-m", "original"]
        writeProject project ("git+file://" ++ dependency)
        runSuccessfully "seed lock file" env project "nix"
          ["flake", "lock", "path:" ++ project]
        lockBefore <- BS.readFile (project </> "flake.lock")
        writeSource dependency "changed"
        runSuccessfully "stage changed dependency" env dependency "git" ["add", "."]
        runSuccessfully "commit changed dependency" env dependency "git"
          ["commit", "-q", "-m", "changed"]

        runSuccessfully "pagda init --existing" env project pagda ["init", "--existing"]

        lockAfter <- BS.readFile (project </> "flake.lock")
        lockAfter @?= lockBefore

  , testCase "missing Nix is reported before files are written" $
      withTempDir $ \root -> do
        let project = root </> "project"
            emptyPath = root </> "empty-path"
        createDirectoryIfMissing True project
        createDirectoryIfMissing True emptyPath
        inherited <- getEnvironment
        let env = overrideEnvironment
              [("HOME", root), ("PATH", emptyPath)] inherited
        (code, _, _) <- run env project pagda ["init", "demo", "--here"]

        code @?= ExitFailure 1
        listDirectory project >>= (@?= [])

  , testCase "Nix lock failures preserve their exit code" $
      withTempDir $ \root -> do
        let project = root </> "project"
            bin = root </> "bin"
            fakeNix = bin </> "nix"
        createDirectoryIfMissing True project
        createDirectoryIfMissing True bin
        writeFile (project </> "demo.agda-lib") "name: demo\ninclude: .\n"
        writeFile (project </> "flake.nix") "{ outputs = _: {}; }\n"
        writeFile fakeNix "#!/bin/sh\nexit 37\n"
        permissions <- getPermissions fakeNix
        setPermissions fakeNix permissions {executable = True}
        inherited <- getEnvironment
        let env = overrideEnvironment [("HOME", root), ("PATH", bin)] inherited
        (code, _, _) <- run env project pagda ["init", "--existing"]

        code @?= ExitFailure 37
        doesFileExist (project </> "flake.lock") >>= (@?= False)
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
          , ("GIT_AUTHOR_NAME", "Pagda Tests")
          , ("GIT_AUTHOR_EMAIL", "pagda-tests@example.invalid")
          , ("GIT_COMMITTER_NAME", "Pagda Tests")
          , ("GIT_COMMITTER_EMAIL", "pagda-tests@example.invalid")
          ]
    action root (overrideEnvironment overrides inherited)

overrideEnvironment :: [(String, String)] -> [(String, String)] -> [(String, String)]
overrideEnvironment overrides inherited =
  let overridden = map fst overrides
  in overrides ++ filter ((`notElem` overridden) . fst) inherited

runSuccessfully
  :: String
  -> [(String, String)]
  -> FilePath
  -> FilePath
  -> [String]
  -> Assertion
runSuccessfully label env workDir executablePath arguments = do
  (code, out, err) <- run env workDir executablePath arguments
  case code of
    ExitSuccess -> pure ()
    ExitFailure status -> assertFailure $ unlines
      [ label ++ " failed with exit code " ++ show status
      , "stdout:"
      , out
      , "stderr:"
      , err
      ]

run
  :: [(String, String)]
  -> FilePath
  -> FilePath
  -> [String]
  -> IO (ExitCode, String, String)
run env workDir executablePath arguments =
  readCreateProcessWithExitCode
    (proc executablePath arguments) {cwd = Just workDir, env = Just env}
    ""

writeSource :: FilePath -> String -> IO ()
writeSource directory identity = do
  createDirectoryIfMissing True directory
  writeFile (directory </> "source-identity") (identity ++ "\n")

writeProject :: FilePath -> String -> IO ()
writeProject project inputUrl = do
  createDirectoryIfMissing True project
  writeFile (project </> "demo.agda-lib") "name: demo\ninclude: .\n"
  writeFile (project </> "flake.nix") $ unlines
    [ "{"
    , "  inputs.dependency = {"
    , "    url = " ++ show inputUrl ++ ";"
    , "    flake = false;"
    , "  };"
    , "  outputs = _: {};"
    , "}"
    ]

assertLockedPath :: FilePath -> String -> FilePath -> Assertion
assertLockedPath lockPath input expected = do
  contents <- BS.readFile lockPath
  value <- case Aeson.eitherDecodeStrict' contents of
    Left err -> assertFailure ("invalid lock file JSON: " ++ err)
      >> pure Aeson.Null
    Right decoded -> pure decoded
  actual <- case lockedPath input value of
    Left err -> assertFailure ("invalid lock file shape: " ++ err)
      >> pure expected
    Right path -> canonicalizePath path
  expectedCanonical <- canonicalizePath expected
  actual @?= expectedCanonical

lockedPath :: String -> Aeson.Value -> Either String FilePath
lockedPath input lock = do
  root <- field "root" lock >>= stringValue
  nodes <- field "nodes" lock
  rootNode <- field root nodes
  inputs <- field "inputs" rootNode
  inputNode <- field input inputs >>= stringValue
  node <- field inputNode nodes
  field "locked" node >>= field "path" >>= stringValue

field :: String -> Aeson.Value -> Either String Aeson.Value
field name = parseEither $ withObject "JSON object" $ \object ->
  object Aeson..: Key.fromString name

stringValue :: Aeson.Value -> Either String String
stringValue (Aeson.String value) = Right (Text.unpack value)
stringValue value = Left ("expected JSON string, got " ++ show value)
