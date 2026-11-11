module Templates where

flakeNix :: String
flakeNix = unlines
  [ "# Warning: only edit this file if you know what you're doing!"
  , "# To customize the build, prefer the optional pagda.nix escape hatch."
  , "{"
  , "  description = \"Pagda project\";"
  , ""
  , "  inputs = {"
  , "    nixpkgs.url = \"github:NixOS/nixpkgs/nixos-26.05\";"
  , ""
  , "    agda-nix = {"
  , "      url = \"github:input-output-hk/agda.nix\";"
  , "      inputs.nixpkgs.follows = \"nixpkgs\";"
  , "    };"
  , ""
  , "    pagda.url = \"github:WhatisRT/pagda\";"
  , "  };"
  , ""
  , "  # The build logic lives in pagda (lib.mkFlake), so this file stays a thin"
  , "  # caller: bump the pagda input to pick up improvements."
  , "  outputs = inputs: inputs.pagda.lib.mkFlake { inherit inputs; src = ./.; };"
  , "}"
  ]

agdaLib :: String
agdaLib = unlines
  [ "name: example"
  , "depend: standard-library"
  , "        standard-library-classes"
  , "        standard-library-meta"
  , "include: ."
  ]

-- A minimal .agda-lib for adding pagda to an existing project that has none;
-- the user fills in the dependencies their code needs.
bareAgdaLib :: String -> String
bareAgdaLib name = unlines
  [ "name: " ++ name
  , "depend:"
  , "include: ."
  ]

testAgda :: String
testAgda = unlines
  [ "module Test where"
  , ""
  , "open import Data.Product"
  , "open import Data.List"
  , "open import Tactic.Defaults"
  , "open import Tactic.Derive.DecEq"
  , ""
  , "data Test : Set where"
  , "  t1 t2 t3 : Test"
  , ""
  , "unquoteDecl DecEq-Test = derive-DecEq ((quote Test , DecEq-Test) ∷ [])"
  ]

ciYml :: Bool -> Bool -> String
ciYml pages cache = unlines $
     [ "name: CI"
     , ""
     , "on: [push, pull_request]"
     , ""
     , "jobs:"
     , "  pagda:"
     ]
  ++ (if pages then
       [ "    permissions:"
       , "      contents: read"
       , "      pages: write"
       , "      id-token: write"
       ]
     else [])
  ++ [ "    uses: WhatisRT/pagda/.github/workflows/agda-ci.yml@v1.0.0" ]
  ++ (let inputs = [ "pages: true" | pages ] ++ [ "cache: true" | cache ]
      in if null inputs then [] else "    with:" : map ("      " ++) inputs)

substitute :: String -> String -> String -> String
substitute old new s = go s
  where
    go [] = []
    go s' = case matchAt s' of
      True -> new ++ go (drop (length old) s')
      False -> case s' of
        (c:cs) -> c : go cs
    matchAt [] = False
    matchAt s' = length old <= length s' && take (length old) s' == old
