{ pkgs ? import <nixpkgs> { }, doCheck ? false }:

let
  inherit (pkgs.haskell.lib) overrideCabal;
  haskellPackages = pkgs.haskellPackages;
  pagda = haskellPackages.callCabal2nix "pagda" ./. { };
  built = overrideCabal pagda (drv: {
    inherit doCheck;
    testToolDepends = [ pkgs.git pkgs.nix ];
    # The plain Setup.hs used by the nixpkgs builder does not put internal
    # build-tool-depends executables on PATH (cabal-install does), so point
    # the test runner at the freshly built pagda explicitly.
    preCheck = ''
      export PAGDA_BIN=dist/build/pagda/pagda
      export AGDACHECK_BIN=dist/build/agda-check/agda-check
    '';
  });
in
# Lets `nix run` and `lib.getExe` resolve the binary unambiguously.
built.overrideAttrs (old: {
  nativeBuildInputs = (old.nativeBuildInputs or [ ]) ++ [ pkgs.makeWrapper ];
  postInstall = (old.postInstall or "") + ''
    for program in pagda agda-check; do
      wrapProgram "$out/bin/$program" \
        --prefix PATH : ${pkgs.lib.makeBinPath [ pkgs.git ]}
    done
  '';
  meta = (old.meta or { }) // { mainProgram = "pagda"; };
})
