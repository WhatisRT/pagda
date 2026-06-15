mkDerivation {
  pname = "baseline";
  version = "0.1";
  src = ./.;
  meta = { };
  libraryFile = "baseline.agda-lib";
  buildInputs = [
    standard-library
    standard-library-classes
    standard-library-meta
  ];
}
