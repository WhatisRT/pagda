module AgdaLib
  ( AgdaLib(..)
  , parseAgdaLib
  , parseAgdaLibSource
  , agdaLibToNix
  ) where

import Data.Char (isDigit)
import Data.List (intercalate, nub)
import System.FilePath (takeBaseName, takeDirectory, takeFileName)
import qualified Text.Parsec as Parsec

type AgdaLibParser = Parsec.Parsec String ()

data AgdaLib = AgdaLib
  { agdaLibName :: String
  , agdaLibDeps :: [String]
  , agdaLibInclude :: [String]
  }

parseAgdaLib :: FilePath -> IO AgdaLib
parseAgdaLib path = do
  content <- readFile path
  case parseAgdaLibSource content of
    Left err -> fail err
    Right lib -> return lib

parseAgdaLibSource :: String -> Either String AgdaLib
parseAgdaLibSource = either (Left . show) Right . Parsec.parse agdaLibFile ""

data AgdaLibField
  = NameField String
  | DependField [String]
  | IncludeField [String]
  | OtherField

agdaLibFile :: AgdaLibParser AgdaLib
agdaLibFile = do
  skipBlankLines
  fields <- Parsec.many (agdaLibField <* skipBlankLines)
  hspaces *> Parsec.optional comment *> Parsec.eof
  let name = case [n | NameField n <- fields] of
                (n:_) -> n
                [] -> ""
      deps = concat [d | DependField d <- fields]
      -- Agda defaults to `.` when no include field is given.
      include = case concat [i | IncludeField i <- fields] of
                   [] -> ["."]
                   xs -> xs
  return $ AgdaLib name deps include

-- A field starts at the beginning of a line with `key:`; indented lines
-- continue it. Unknown fields (e.g. `flags:`) are parsed and ignored.
agdaLibField :: AgdaLibParser AgdaLibField
agdaLibField = do
  key <- Parsec.many1 (Parsec.alphaNum Parsec.<|> Parsec.oneOf "-_")
  _ <- Parsec.char ':'
  vals <- fieldValues
  return $ case key of
    "name" -> NameField (unwords vals)
    "depend" -> DependField vals
    "include" -> IncludeField vals
    _ -> OtherField

-- Entries may be separated by whitespace or commas, on the field's own
-- line or on indented continuation lines.
fieldValues :: AgdaLibParser [String]
fieldValues = do
  first <- restOfLine
  rest <- Parsec.many (Parsec.try continuationLine)
  return $ concatMap entries (first : rest)
  where
    continuationLine = Parsec.many1 (Parsec.oneOf " \t") *> restOfLine
    entries = words . map (\c -> if c == ',' then ' ' else c) . stripComment

restOfLine :: AgdaLibParser String
restOfLine = Parsec.many (Parsec.noneOf "\n") <* eolOrEof
  where
    eolOrEof = (Parsec.newline >> return ()) Parsec.<|> Parsec.eof

skipBlankLines :: AgdaLibParser ()
skipBlankLines = Parsec.skipMany (Parsec.try blankLine)
  where
    blankLine = hspaces *> Parsec.optional comment *> (Parsec.newline >> return ())

hspaces :: AgdaLibParser ()
hspaces = Parsec.skipMany (Parsec.oneOf " \t")

comment :: AgdaLibParser ()
comment = Parsec.string "--" *> Parsec.skipMany (Parsec.noneOf "\n")

stripComment :: String -> String
stripComment ('-':'-':_) = ""
stripComment (c:cs) = c : stripComment cs
stripComment "" = ""

-- Emit a callPackage-style function `{ mkDerivation, dep1, ... }: mkDerivation { ... }`.
agdaLibToNix :: FilePath -> AgdaLib -> String
agdaLibToNix path lib = unlines $ concat
  [ ["{ " ++ intercalate ", " ("mkDerivation" : deps) ++ " }:"]
  , ["mkDerivation {"]
  , ["  pname = \"" ++ pname ++ "\";"]
  , ["  version = \"0.1\";"]
  , ["  src = ./.;"]
  , ["  meta = { };"]
  , ["  libraryFile = \"" ++ takeFileName path ++ "\";"]
  , ["  buildInputs = ["]
  , map ((++) "    ") deps
  , ["  ];"]
  , ["  passthru = { agdaLibInclude = [ "
      ++ intercalate " " (map (\d -> "\"" ++ d ++ "\"") (agdaLibInclude lib))
      ++ " ]; };"]
  , ["}"]
  ]
  where
    deps = nub (map stripVersion (agdaLibDeps lib))
    -- The name field is optional; fall back to the file name, or to the
    -- directory name for a bare ".agda-lib" file.
    pname = case (agdaLibName lib, takeBaseName path) of
      (n@(_:_), _) -> n
      ("", b@(_:_)) -> b
      _ -> takeFileName (takeDirectory path)

-- Agda library names may end in a version number (e.g. standard-library-2.3),
-- but nix attributes in agdaPackages are unversioned.
stripVersion :: String -> String
stripVersion dep =
  case span (\c -> isDigit c || c == '.') (reverse dep) of
    (ver@(v:_), '-':base@(_:_)) | isDigit v, isDigit (last ver) -> reverse base
    _ -> dep
