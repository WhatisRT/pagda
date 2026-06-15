mkDerivation {
  pname = "dirname-fallback";
  version = "0.1";
  src = ./.;
  meta = { };
  libraryFile = ".agda-lib";
  buildInputs = [
    standard-library
  ];
}
