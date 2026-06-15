mkDerivation {
  pname = "mylib";
  version = "0.1";
  src = ./.;
  meta = { };
  libraryFile = "mylib.agda-lib";
  buildInputs = [
    standard-library
  ];
}
