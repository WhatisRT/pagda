mkDerivation {
  pname = "commas";
  version = "0.1";
  src = ./.;
  meta = { };
  libraryFile = "commas.agda-lib";
  buildInputs = [
    foo
    bar
    baz
  ];
}
