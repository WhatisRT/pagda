# Enhanced documentation backend
#
# `modules` are the top-level module-name prefixes agda-docs groups the sidebar
# by. When not given they are derived from the project's sources, so the sidebar
# is populated automatically. The search index is embedded by default so search
# works without a server; pass `offline = false` to load it via fetch
# instead (smaller output, but must be served). `entryModule` (e.g. "Foo.Bar")
# designates the module the generated index.html redirects to; when null,
# index.html lists the module pages instead.
{ pkgs, htmlBackend, agdaDocs }:

{ modules ? null, githubUrl ? null, backButtonUrl ? null, offline ? true, entryModule ? null }:

agdaLib:

let
  inherit (pkgs) lib;
  entry = if entryModule == null then "" else entryModule;
  # htmlBackend's own index.html is dropped below and regenerated after
  # agda-docs, so the options here don't matter.
  raw = htmlBackend { } agdaLib;

  # The sidebar filter is the project's own module names: agda-docs shows a page
  # iff its module name starts with one of these. They are derived them from the
  # .agda-lib's include dirs.
  agdaExts = [ ".lagda.md" ".lagda.rst" ".lagda.tex" ".lagda.org" ".lagda" ".agda" ];
  stripExt = name:
    let ext = lib.findFirst (e: lib.hasSuffix e name) null agdaExts;
    in if ext == null then null else lib.removeSuffix ext name;
  includeDirs = agdaLib.agdaLibInclude or [ "." ];
  modulesUnder = dir:
    let root = if dir == "." || dir == "" then agdaLib.src else agdaLib.src + "/${dir}";
        prefix = toString root + "/";
    in if ! builtins.pathExists root then [ ]
       else lib.pipe (lib.filesystem.listFilesRecursive root) [
         (map (f: stripExt (lib.removePrefix prefix (toString f))))
         (lib.filter (m: m != null))
         (map (m: builtins.replaceStrings [ "/" ] [ "." ] m))
       ];
  autoModules = lib.unique (lib.concatMap modulesUnder includeDirs);
  mods = if modules == null then autoModules else modules;

  config = pkgs.writeText "agda-docs.config.json" (builtins.toJSON (
    { modules = mods; }
    // lib.optionalAttrs (backButtonUrl != null) { inherit backButtonUrl; }
    // lib.optionalAttrs (githubUrl != null) { inherit githubUrl; }
  ));

  # Optional: make search work from file:// (no HTTP server). Embed the index as
  # a global and load a shim that serves search.js's fetch() from it.
  offlinePostProcess = lib.optionalString offline ''
    { printf 'window.__pagdaSearchData = '; cat build/search-index.json; printf ';'; } > build/search-index.js
    cp ${./offline-search.js} build/pagda-offline-search.js
    find build -name '*.html' -exec sed -i \
      's#<script src="search.js"#<script src="search-index.js" defer></script><script src="pagda-offline-search.js" defer></script><script src="search.js"#' {} +
  '';
in
pkgs.runCommand "${agdaLib.pname or "agda-library"}-docs"
  { nativeBuildInputs = [ pkgs.nodejs ]; }
  ''
    # agda-docs edits in place; the raw docs are a read-only store path.
    cp -r ${raw} build
    chmod -R u+w build
    # Drop the basic backend's index.html so agda-docs only processes the real
    # module pages; the final index.html is generated below.
    rm -f build/index.html
    ${lib.getExe agdaDocs} process -i build -c ${config}
    # A green build with an empty sidebar is a silent failure mode: the module
    # filter matched no page (a wrong include layout, or a stale `modules`).
    if ! grep -ql 'module-link' build/*.html 2>/dev/null; then
      echo "pagda: warning: the docs sidebar is empty — the 'modules' filter matched no module page. Check the .agda-lib 'include:' dirs, or pass 'modules' explicitly." >&2
    fi
    ${offlinePostProcess}
    sh ${./gen-index.sh} build "${entry}"
    mkdir -p "$out"
    cp -r build/. "$out"/
  ''
