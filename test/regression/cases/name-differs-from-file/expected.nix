mkDerivation {
  pname = "other-name";
  version = "0.1";
  src = ./.;
  meta = { };
  libraryFile = "file-name.agda-lib";
  buildInputs = [
    standard-library
  ];
}
