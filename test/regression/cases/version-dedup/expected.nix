mkDerivation {
  pname = "dedup";
  version = "0.1";
  src = ./.;
  meta = { };
  libraryFile = "dedup.agda-lib";
  buildInputs = [
    standard-library
  ];
}
