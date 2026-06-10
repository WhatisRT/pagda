module AgdaLib
  ( AgdaLib(..)
  , parseAgdaLib
  , parseAgdaLibSource
  , agdaLibToNix
  ) where

import Data.Char (isDigit)
import Data.List (nub)
import System.FilePath (takeBaseName, takeDirectory, takeFileName)
import qualified Text.Parsec as Parsec

type AgdaLibParser = Parsec.Parsec String ()

data AgdaLib = AgdaLib
  { agdaLibName :: String
  , agdaLibDeps :: [String]
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
  return $ AgdaLib name deps

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

agdaLibToNix :: FilePath -> AgdaLib -> String
agdaLibToNix path lib = unlines $ concat
  [ ["mkDerivation {"]
  , ["  pname = \"" ++ pname ++ "\";"]
  , ["  version = \"0.1\";"]
  , ["  src = ./.;"]
  , ["  meta = { };"]
  , ["  libraryFile = \"" ++ takeFileName path ++ "\";"]
  , ["  buildInputs = ["]
  , map ((++) "    ") (nub (map stripVersion (agdaLibDeps lib)))
  , ["  ];"]
  , ["}"]
  ]
  where
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
