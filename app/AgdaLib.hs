module AgdaLib
  ( AgdaLib(..)
  , parseAgdaLib
  , parseAgdaLibSource
  , agdaLibToNix
  ) where

import Data.Char (isDigit, isSpace)
import Data.List (dropWhileEnd, intercalate, nub)
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

-- A field starts at the beginning of a line with `key:` (or `key :`); indented lines
-- continue it. Unknown fields (e.g. `flags:`) are parsed and ignored.
agdaLibField :: AgdaLibParser AgdaLibField
agdaLibField = do
  key <- Parsec.many1 (Parsec.alphaNum Parsec.<|> Parsec.oneOf "-_")
  hspaces
  _ <- Parsec.char ':'
  vals <- fieldValueLines
  return $ case key of
    "name" -> NameField (unwords (concatMap entries vals))
    "depend" -> DependField (concatMap entries vals)
    "include" -> IncludeField (concatMap includePaths vals)
    _ -> OtherField
  where
    entries = words . map (\c -> if c == ',' then ' ' else c) . stripComment

-- Values may continue on indented lines, including across blank and comment lines.
fieldValueLines :: AgdaLibParser [String]
fieldValueLines = do
  hspaces
  first <- restOfLine
  rest <- Parsec.many (Parsec.try (skipBlankLines *> continuationLine))
  return (first : rest)
  where
    continuationLine = Parsec.many1 (Parsec.oneOf " \t") *> restOfLine

-- Agda include paths use backslash to escape spaces and backslashes. Dependency
-- fields deliberately keep their separate comma/whitespace syntax.
includePaths :: String -> [FilePath]
includePaths = go id . dropWhileEnd isSpace . stripComment
  where
    finish acc = [path | let path = acc [], not (null path)]
    go acc [] = finish acc
    go acc ('\\':' ':cs) = go (acc . (' ':)) cs
    go acc ('\\':'\\':cs) = go (acc . ('\\':)) cs
    go acc (' ':cs) = finish acc ++ go id cs
    go acc (c:cs) = go (acc . (c:)) cs

restOfLine :: AgdaLibParser String
restOfLine = Parsec.many (Parsec.noneOf "\r\n") <* eolOrEof
  where
    eolOrEof = lineEnd Parsec.<|> Parsec.eof

skipBlankLines :: AgdaLibParser ()
skipBlankLines =
  Parsec.skipMany (Parsec.try blankLine)
    *> Parsec.optional (Parsec.try finalBlankLine)
  where
    blankLine = hspaces *> Parsec.optional comment *> lineEnd
    finalBlankLine =
      (Parsec.many1 (Parsec.oneOf " \t") *> Parsec.optional comment *> Parsec.eof)
        Parsec.<|> (comment *> Parsec.eof)

lineEnd :: AgdaLibParser ()
lineEnd =
  (Parsec.try (Parsec.string "\r\n") >> return ())
    Parsec.<|> (Parsec.newline >> return ())

hspaces :: AgdaLibParser ()
hspaces = Parsec.skipMany (Parsec.oneOf " \t")

comment :: AgdaLibParser ()
comment = Parsec.string "--" *> Parsec.skipMany (Parsec.noneOf "\r\n")

stripComment :: String -> String
stripComment ('-':'-':_) = ""
stripComment (c:cs) = c : stripComment cs
stripComment "" = ""

-- Emit a callPackage-style function `{ mkDerivation, dep1, ... }: mkDerivation { ... }`.
agdaLibToNix :: FilePath -> AgdaLib -> String
agdaLibToNix path lib = unlines $ concat
  [ ["{ " ++ intercalate ", " ("mkDerivation" : deps) ++ " }:"]
  , ["mkDerivation {"]
  , ["  pname = " ++ nixString pname ++ ";"]
  , ["  version = \"0.1\";"]
  , ["  src = ./.;"]
  , ["  meta = { };"]
  , ["  libraryFile = " ++ nixString (takeFileName path) ++ ";"]
  , ["  buildInputs = ["]
  , map ((++) "    ") deps
  , ["  ];"]
  , ["  passthru = { agdaLibInclude = [ "
      ++ intercalate " " (map nixString (agdaLibInclude lib))
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

nixString :: String -> String
nixString value = '"' : escape value ++ "\""
  where
    escape ('"':cs) = '\\' : '"' : escape cs
    escape ('\\':cs) = '\\' : '\\' : escape cs
    escape ('$':'{':cs) = '\\' : '$' : '{' : escape cs
    escape ('\n':cs) = '\\' : 'n' : escape cs
    escape ('\r':cs) = '\\' : 'r' : escape cs
    escape ('\t':cs) = '\\' : 't' : escape cs
    escape (c:cs) = c : escape cs
    escape [] = []

-- Agda library names may end in a version number (e.g. standard-library-2.3),
-- but nix attributes in agdaPackages are unversioned.
stripVersion :: String -> String
stripVersion dep =
  case span (\c -> isDigit c || c == '.') (reverse dep) of
    (ver@(v:_), '-':base@(_:_)) | isDigit v, isDigit (last ver) -> reverse base
    _ -> dep
