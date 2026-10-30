{ mkDerivation, standard-library }:
mkDerivation {
  pname = "Main";
  version = "0.1";
  src = ./.;
  meta = { };
  libraryFile = "Main.agda-lib";
  buildInputs = [
    standard-library
  ];
  passthru = { agdaLibInclude = [ "." ]; };
}
