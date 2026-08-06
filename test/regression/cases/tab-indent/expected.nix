{ mkDerivation, standard-library }:
mkDerivation {
  pname = "tabbed";
  version = "0.1";
  src = ./.;
  meta = { };
  libraryFile = "tabbed.agda-lib";
  buildInputs = [
    standard-library
  ];
  passthru = { agdaLibInclude = [ "." ]; };
}
