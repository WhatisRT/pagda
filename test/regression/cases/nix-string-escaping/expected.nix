{ mkDerivation }:
mkDerivation {
  pname = "library\"\\\${name}";
  version = "0.1";
  src = ./.;
  meta = { };
  libraryFile = "my library\"\${file}.agda-lib";
  buildInputs = [
  ];
  passthru = { agdaLibInclude = [ "source files" "slash\\path" "quote\"dir" "\${missing}" ]; };
}
