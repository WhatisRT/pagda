# Build an Agda library derivation directly from its .agda-lib file, the way
# nixpkgs' callCabal2nix builds a Haskell package from its .cabal file: run
# `pagda agdaLib2nix` on the source in a derivation, then callPackage the
# generated function against agdaPackages.
#
# `pkgs` and `pagda` are bound by pagda's flake (per system); the caller
# supplies their own `agdaPackages` (e.g. with the agda.nix overlay) and the
# project `src`:
#
#     pagda.lib.${system}.callAgdaLib2nix {
#       agdaPackages = pkgs.agdaPackages;
#       src = ./.;
#     }
#
# The .agda-lib is the source of truth for name and dependencies, which resolve
# by name against agdaPackages. To pin or add a dependency, pass an `overlay`
# (applied to agdaPackages); to tweak the project derivation, pass an
# `overrideAttrs` function. Both are optional (the pagda.nix escape hatch):
#
#       overlay = final: prev: { standard-library = prev.standard-library.overrideAttrs ...; };
#       overrideAttrs = prev: { buildInputs = prev.buildInputs ++ [ ... ]; };
{ pkgs, pagda }:

{ agdaPackages, src, overlay ? null, overrideAttrs ? (_: { }) }:

let
  inherit (pkgs) lib runCommand;

  # Expect exactly one .agda-lib in the source root.
  libFiles = builtins.filter (lib.hasSuffix ".agda-lib")
    (builtins.attrNames (builtins.readDir src));
  libFile =
    if libFiles == [ ] then
      throw "callAgdaLib2nix: no .agda-lib file found in ${toString src}"
    else if builtins.length libFiles > 1 then
      throw ("callAgdaLib2nix: multiple .agda-lib files in ${toString src}: "
        + builtins.concatStringsSep ", " libFiles
        + " (multi-library projects are not supported yet)")
    else
      builtins.head libFiles;

  # `pagda agdaLib2nix` prints a callPackage-style function
  # `{ mkDerivation, <deps...> }: mkDerivation { ... }`, so callPackageWith
  # supplies mkDerivation and each dependency from agdaPackages by name.
  generated = runCommand "${libFile}.nix" { } ''
    ${lib.getExe pagda} agdaLib2nix ${src + "/${libFile}"} > "$out"
  '';
  # pagda.nix may supply an overlay to pin or add dependencies; anything it
  # doesn't touch stays as agdaPackages provides.
  agdaPackages' = if overlay == null then agdaPackages else agdaPackages.overrideScope overlay;
  derivation = lib.callPackageWith agdaPackages' generated { };

  # The generated `src = ./.;` is a placeholder, point it at the real source.
  withSrc = derivation.overrideAttrs (_: { inherit src; });
in
# Layer the caller's escape-hatch overrides (the optional pagda.nix) on top.
# It defaults to a no-op and sees the corrected src in `prev`.
withSrc.overrideAttrs overrideAttrs
