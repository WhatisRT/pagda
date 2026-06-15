mkDerivation {
  pname = "commented";
  version = "0.1";
  src = ./.;
  meta = { };
  libraryFile = "commented.agda-lib";
  buildInputs = [
    standard-library
  ];
}
