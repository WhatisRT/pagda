mkDerivation {
  pname = "trailing";
  version = "0.1";
  src = ./.;
  meta = { };
  libraryFile = "trailing.agda-lib";
  buildInputs = [
    standard-library
  ];
}
