# Basic documentation backend via `agda --html`
#
# `entryModule` (e.g. "Foo.Bar") designates the module the generated index.html
# redirects to; when null, index.html lists the module pages instead.
{ pkgs }:

{ entryModule ? null }:

agdaLib:

let
  inherit (pkgs) lib;
  entry = if entryModule == null then "" else entryModule;
  includeDirs = agdaLib.agdaLibInclude or [ "." ];
in
agdaLib.overrideAttrs (old: {
  pname = "${old.pname or "agda-library"}-docs";
  nativeBuildInputs = (old.nativeBuildInputs or [ ]) ++ [ pkgs.cmark-gfm ];
  buildPhase = ''
    runHook preBuild
    # Reuse the interfaces the library build already produced
    cp -r --no-preserve=mode ${agdaLib}/_build . 2>/dev/null || true

    agdaFiles() {
      find "$1" \( -name '*.agda' -o -name '*.lagda' -o -name '*.lagda.md' \
                   -o -name '*.lagda.rst' -o -name '*.lagda.tex' -o -name '*.lagda.org' \) "$2"
    }

    # `agda --build-library` is not compatible with `--html`. If we just iterate over
    # all modules we get quadratic build times, so we generate a temporary `Everything`
    # module as a workaround.
    aggDir=
    for d in ${lib.escapeShellArgs includeDirs}; do
      if [ -d "$d" ]; then aggDir="$d"; break; fi
    done
    agg="$aggDir/PagdaDocsEverything.agda"
    aggOk=
    if [ -z "$aggDir" ]; then
      :
    elif [ -e "$agg" ]; then
      echo "pagda: warning: $agg already exists; generating docs file by file instead" >&2
    else
      { echo "module PagdaDocsEverything where"
        for d in ${lib.escapeShellArgs includeDirs}; do
          if [ -d "$d" ]; then
            (cd "$d" && agdaFiles . -print) | sed \
              -e 's#^\./##' \
              -e 's#\.lagda\.\(md\|rst\|tex\|org\)$##' -e 's#\.lagda$##' -e 's#\.agda$##' \
              -e 's#/#.#g' -e 's#^#import #'
          fi
          # The redirection below creates the aggregate before this walk runs,
          # so drop it from its own import list.
        done | sort -u | sed '/^import PagdaDocsEverything$/d'
      } > "$agg"
      if agda --html --html-dir="$out" --html-highlight=auto --highlight-occurrences "$agg"
      then
        aggOk=1
      else
        # Most likely [InfectiveImport]: a file enables an infective flag (e.g.
        # --cubical) in an OPTIONS pragma rather than library-wide via the
        # .agda-lib's `flags:` field, so the aggregate cannot import it.
        echo "pagda: warning: single-pass docs generation failed (see above); retrying file by file" >&2
      fi
      rm -f "$agg" "$out/PagdaDocsEverything.html"
    fi
    if [ -z "$aggOk" ]; then
      agdaFiles . -print0 | while IFS= read -r -d "" f; do
        agda --html --html-dir="$out" --html-highlight=auto --highlight-occurrences "$f"
      done
    fi
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
