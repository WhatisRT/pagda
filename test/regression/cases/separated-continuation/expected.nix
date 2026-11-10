{ mkDerivation, standard-library, standard-library-meta }:
mkDerivation {
  pname = "continued";
  version = "0.1";
  src = ./.;
  meta = { };
  libraryFile = "continued.agda-lib";
  buildInputs = [
    standard-library
    standard-library-meta
  ];
  passthru = { agdaLibInclude = [ "src" ]; };
}
