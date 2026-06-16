# Enhanced documentation backend
#
# `modules` are the top-level module-name prefixes agda-docs groups the sidebar
# by. When not given they are derived from the project's sources, so the sidebar
# is populated automatically. The search index is embedded by default so search
# works without a server; pass `offline = false` to load it via fetch
# instead (smaller output, but must be served).
{ pkgs, htmlBackend, agdaDocs }:

{ modules ? null, githubUrl ? null, backButtonUrl ? "/", offline ? true }:

agdaLib:

let
  inherit (pkgs) lib;
  raw = htmlBackend agdaLib;

  # Derive the project's top-level module prefixes from its source tree. Assumes
  # the usual `include: .`; pass `modules` explicitly for other include layouts.
  agdaExts = [ ".lagda.md" ".lagda.rst" ".lagda.tex" ".lagda.org" ".lagda" ".agda" ];
  stripExt = name:
    let ext = lib.findFirst (e: lib.hasSuffix e name) null agdaExts;
    in if ext == null then null else lib.removeSuffix ext name;
  autoModules = lib.unique (lib.filter (m: m != null) (lib.mapAttrsToList
    (name: type:
      if lib.hasPrefix "." name then null # skip .git, .pagda, ...
      else if type == "directory" then name # a module namespace
      else if type == "regular" then stripExt name # a top-level module (or null)
      else null) # skip symlinks (e.g. result)
    (builtins.readDir agdaLib.src)));
  mods = if modules == null then autoModules else modules;

  config = pkgs.writeText "agda-docs.config.json" (builtins.toJSON (
    { modules = mods; inherit backButtonUrl; }
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
    ${lib.getExe agdaDocs} process -i build -c ${config}
    ${offlinePostProcess}
    mkdir -p "$out"
    cp -r build/. "$out"/
  ''
