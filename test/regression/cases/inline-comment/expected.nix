{ mkDerivation, standard-library, agda-stdlib-classes }:
mkDerivation {
  pname = "inline";
  version = "0.1";
  src = ./.;
  meta = { };
  libraryFile = "inline.agda-lib";
  buildInputs = [
    standard-library
    agda-stdlib-classes
  ];
  passthru = { agdaLibInclude = [ "src" ]; };
}
