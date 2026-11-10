{ mkDerivation, alpha, beta }:
mkDerivation {
  pname = "demo";
  version = "0.1";
  src = ./.;
  meta = { };
  libraryFile = "crlf.agda-lib";
  buildInputs = [
    alpha
    beta
  ];
  passthru = { agdaLibInclude = [ "src" "test files" ]; };
}
