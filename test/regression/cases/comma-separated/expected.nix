{ mkDerivation, foo, bar, baz }:
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
  passthru = { agdaLibInclude = [ "src" ]; };
}
