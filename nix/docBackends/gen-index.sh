#!/bin/sh
# Write an index.html landing page into $1. `agda --html` (and agda-docs on top
# of it) emit one <Module>.html per module but no index.html, so serving the
# output (e.g. on GitHub Pages) would 404 at the root.
#
# With an entry module ($2, the module designated in pagda.nix) the page
# redirects to that module's page; otherwise it lists the module pages
# alphabetically as a simple table of contents.
set -eu
dir="$1"
entry="${2:-}"

if [ -n "$entry" ]; then
  cat > "$dir/index.html" <<EOF
<!DOCTYPE html>
<html lang="en"><head><meta charset="utf-8">
<title>${entry}</title>
<meta http-equiv="refresh" content="0; url=${entry}.html">
<link rel="canonical" href="${entry}.html"></head>
<body>Redirecting to <a href="${entry}.html">${entry}</a>&hellip;</body></html>
EOF
else
  {
    echo '<!DOCTYPE html>'
    echo '<html lang="en"><head><meta charset="utf-8"><title>Agda documentation</title></head>'
    echo '<body><h1>Modules</h1><ul>'
    for f in "$dir"/*.html; do
      [ -e "$f" ] || continue
      b=${f##*/}
      [ "$b" = index.html ] && continue
      printf '<li><a href="%s">%s</a></li>\n' "$b" "${b%.html}"
    done
    echo '</ul></body></html>'
  } > "$dir/index.html"
fi
