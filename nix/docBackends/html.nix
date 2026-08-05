# Basic documentation backend via `agda --html`
#
# `entryModule` (e.g. "Foo.Bar") designates the module the generated index.html
# redirects to; when null, index.html lists the module pages instead.
{ pkgs }:

{ entryModule ? null }:

agdaLib:

let
  entry = if entryModule == null then "" else entryModule;
in
agdaLib.overrideAttrs (old: {
  pname = "${old.pname or "agda-library"}-docs";
  nativeBuildInputs = (old.nativeBuildInputs or [ ]) ++ [ pkgs.cmark-gfm ];
  buildPhase = ''
    runHook preBuild
    find . \( -name '*.agda' -o -name '*.lagda' -o -name '*.lagda.md' \
              -o -name '*.lagda.rst' -o -name '*.lagda.tex' -o -name '*.lagda.org' \) -print0 \
      | while IFS= read -r -d "" f; do
          agda --html --html-dir="$out" --html-highlight=auto --highlight-occurrences "$f"
        done
    # Literate Markdown modules come out as .md (agda highlights the code and
    # leaves the prose as markdown); render those to .html so the prose and any
    # images display. --unsafe passes the embedded highlighted-code HTML through.
    for md in "$out"/*.md; do
      [ -e "$md" ] || continue
      name=$(basename "$md" .md)
      {
        printf '<!DOCTYPE html>\n<html lang="en"><head><meta charset="utf-8">'
        printf '<title>%s</title><link rel="stylesheet" href="Agda.css"></head><body>\n' "$name"
        cmark-gfm --unsafe "$md"
        printf '</body></html>\n'
      } > "''${md%.md}.html"
      rm "$md"
    done
    # After the conversion above, so literate pages appear in the index.
    sh ${./gen-index.sh} "$out" "${entry}"
    runHook postBuild
  '';
  installPhase = "true";
})
