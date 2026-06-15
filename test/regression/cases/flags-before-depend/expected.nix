mkDerivation {
  pname = "flagged";
  version = "0.1";
  src = ./.;
  meta = { };
  libraryFile = "flagged.agda-lib";
  buildInputs = [
    standard-library
  ];
}
