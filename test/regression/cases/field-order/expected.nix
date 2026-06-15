mkDerivation {
  pname = "ordered";
  version = "0.1";
  src = ./.;
  meta = { };
  libraryFile = "ordered.agda-lib";
  buildInputs = [
    standard-library
  ];
}
