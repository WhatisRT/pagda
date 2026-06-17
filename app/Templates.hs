module Templates where

flakeNix :: String
flakeNix = unlines
  [ "# Warning: only edit this file if you know what you're doing!"
  , "# To customize the build, prefer the optional pagda.nix escape hatch."
  , "{"
  , "  description = \"Pagda project\";"
  , ""
  , "  inputs = {"
  , "    nixpkgs.url = \"github:NixOS/nixpkgs\";"
  , ""
  , "    flake-utils.url = \"github:numtide/flake-utils\";"
  , ""
  , "    agda-nix = {"
  , "      url = \"github:input-output-hk/agda.nix\";"
  , "      inputs.nixpkgs.follows = \"nixpkgs\";"
  , "    };"
  , ""
  , "    pagda.url = \"github:WhatisRT/pagda\";"
  , "  };"
  , ""
  , "  outputs ="
  , "    inputs@{"
  , "      self,"
  , "        nixpkgs,"
  , "        flake-utils,"
  , "        pagda,"
  , "        ..."
  , "    }:"
  , "      flake-utils.lib.eachDefaultSystem ("
  , "        system:"
  , "        let"
  , "          pkgs = import nixpkgs {"
  , "            inherit system;"
  , "            overlays = ["
  , "              inputs.agda-nix.overlays.default"
  , "            ];"
  , "          };"
  , ""
  , "          # The library derivation is derived from the .agda-lib file. An"
  , "          # optional pagda.nix can pin/add dependencies (overlay), customize"
  , "          # the build (overrideAttrs), and pick a documentation backend (docs)."
  , "          pagdaNix ="
  , "            if builtins.pathExists ./pagda.nix"
  , "            then import ./pagda.nix { inherit pkgs; pagda = pagda.lib.${system}; }"
  , "            else { };"
  , ""
  , "          default = pagda.lib.${system}.callAgdaLib2nix {"
  , "            agdaPackages = pkgs.agdaPackages;"
  , "            src = ./.;"
  , "            overlay = pagdaNix.overlay or null;"
  , "            overrideAttrs = pagdaNix.overrideAttrs or (_: { });"
  , "          };"
  , ""
  , "          docs = (pagdaNix.docs or (pagda.lib.${system}.docBackends.enhancedHtml { })) default;"
  , "        in"
  , "          {"
  , "            packages = {"
  , "              inherit default docs;"
  , "              agda = pkgs.agdaPackages.agda.withPackages"
  , "                (builtins.filter (p: p ? isAgdaDerivation) default.buildInputs);"
  , "            };"
  , "          }"
  , "      );"
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
  ++ [ "    uses: WhatisRT/pagda/.github/workflows/agda-ci.yml@main" ]
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
