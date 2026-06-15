mkDerivation {
  pname = "nofinal";
  version = "0.1";
  src = ./.;
  meta = { };
  libraryFile = "nofinal.agda-lib";
  buildInputs = [
    standard-library
  ];
}
