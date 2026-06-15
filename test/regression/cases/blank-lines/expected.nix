mkDerivation {
  pname = "blanky";
  version = "0.1";
  src = ./.;
  meta = { };
  libraryFile = "blanky.agda-lib";
  buildInputs = [
    standard-library
  ];
}
