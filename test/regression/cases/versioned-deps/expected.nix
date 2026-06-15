mkDerivation {
  pname = "versioned";
  version = "0.1";
  src = ./.;
  meta = { };
  libraryFile = "versioned.agda-lib";
  buildInputs = [
    standard-library
    agda-stdlib-classes
  ];
}
