{ mkDerivation, standard-library, agda-stdlib-classes, agda-stdlib-meta, agda-stdlib-utils }:
mkDerivation {
  pname = "multi";
  version = "0.1";
  src = ./.;
  meta = { };
  libraryFile = "multi.agda-lib";
  buildInputs = [
    standard-library
    agda-stdlib-classes
    agda-stdlib-meta
    agda-stdlib-utils
  ];
  passthru = { agdaLibInclude = [ "src" "lib" ]; };
}
