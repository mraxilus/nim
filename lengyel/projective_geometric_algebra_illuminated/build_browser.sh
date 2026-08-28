#!/usr/bin/env bash
# Assemble the browser build into one self-contained page.
#
# The browser target is three tracked sources plus vendored fonts:
#
#   visualiser/browser/shell.html     markup, stylesheet, `@EMBED:<file>@` font tokens
#   visualiser/browser/browser_bridge.nim -> browser_bridge.js, every domain rule, via `nim js`
#   visualiser/browser/glue.js        WebGL upload, DOM construction, pointer wiring
#   fonts/*.woff2             vendored WOFF2 faces, kept locally and never committed
#
# `shell.html` ends on an opening `<script>` and the two scripts concatenate into it, so
# the closing tag is appended here rather than living in a file that would then not parse
# on its own. Font bytes are injected at their tokens so the tracked shell stays 26 KB
# instead of the ~940 KB the payload costs -- see that file's own comment.
#
# Override the compiler with `NIM=/some/where/nim`; the default is this fork's own build,
# which is what the project requires and is not on `PATH`.

set -euo pipefail

DIR_PROJECT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NIM="${NIM:-${DIR_PROJECT}/../../bin/nim}"
DIR_OUT="${DIR_PROJECT}/bin"
PATH_PAGE="${DIR_OUT}/rga_browser.html"
PATH_BRIDGE="${DIR_OUT}/browser_bridge.js"

# Fail with the reason rather than a broken page, since a missing face renders as a box
#   and a missing script renders as a blank canvas -- neither reports itself.
for path_needed in \
  "${NIM}" \
  "${DIR_PROJECT}/visualiser/browser/shell.html" \
  "${DIR_PROJECT}/visualiser/browser/glue.js" \
  "${DIR_PROJECT}/visualiser/browser/browser_bridge.nim"
do
  [ -e "${path_needed}" ] || { echo "Missing \`${path_needed}\`." >&2; exit 1; }
done

mkdir -p "${DIR_OUT}"

# Compile every shared module the desktop runs, through the JS backend. Flags come from
#   `browser_bridge.nim.cfg` beside the source, not from here -- except `-d:release`, which
#   is a property of *this artefact* rather than of the source: the suite's own JS build
#   (`tools/verify.sh`) must keep its checks and stack traces, and the page must not carry
#   them. Measured on the opening scene, one `nimBuildFrame` call: **36.7 ms debug against
#   21.9 ms released**, for identical output. `-d:danger` was measured too, at 18.4 ms, and
#   rejected: it buys a further tenth of the frame by removing every bounds, range and
#   field check from the one build a reader actually runs.
"${NIM}" js --hints:off -d:release -o:"${PATH_BRIDGE}" \
  "${DIR_PROJECT}/visualiser/browser/browser_bridge.nim"

# Inline each face at the token naming it, so the page reaches no external font host.
: > "${PATH_PAGE}"
while IFS= read -r line; do
  # Match the token only where it stands as a URL, so prose above may name it freely.
  while [[ "${line}" == *"url(@EMBED:"* ]]; do
    name_font="${line#*url(@EMBED:}"
    name_font="${name_font%%@*}"
    path_font="${DIR_PROJECT}/fonts/${name_font}"
    [ -f "${path_font}" ] || {
      echo "Missing font \`${path_font}\`; see \`dependencies.list\`." >&2; exit 1
    }
    line="${line/@EMBED:${name_font}@/data:font/woff2;base64,$(base64 -w0 "${path_font}")}"
  done
  printf '%s\n' "${line}"
done < "${DIR_PROJECT}/visualiser/browser/shell.html" >> "${PATH_PAGE}"

cat "${PATH_BRIDGE}" "${DIR_PROJECT}/visualiser/browser/glue.js" >> "${PATH_PAGE}"
printf '\n</script>\n' >> "${PATH_PAGE}"

echo "Wrote ${PATH_PAGE} ($(wc -c < "${PATH_PAGE}") bytes)."
