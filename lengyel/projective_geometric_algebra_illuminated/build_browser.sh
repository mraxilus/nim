#!/usr/bin/env bash
# Assemble browser build into one self-contained page.
#
# Browser target is three tracked sources plus vendored fonts:
#
#   visualiser/browser/shell.html     markup, stylesheet, `@EMBED:<file>@` font tokens
#   visualiser/browser/browser_bridge.nim -> browser_bridge.js, every domain rule, via `nim js`
#   visualiser/browser/glue.js        WebGL upload, DOM construction, pointer wiring
#   fonts/*.woff2             vendored WOFF2 faces, kept locally and never committed
#
# `shell.html` ends on opening `<script>` and two scripts concatenate into it.
#   Closing tag is appended here rather than living in file that would not parse on its
#   own.
#   Font bytes are injected at tokens so tracked shell stays small.
# Override compiler with `NIM=/some/where/nim`.
#   Default is this fork's build, not on `PATH`.

set -euo pipefail

DIR_PROJECT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NIM="${NIM:-${DIR_PROJECT}/../../bin/nim}"
DIR_OUT="${DIR_PROJECT}/bin"
PATH_PAGE="${DIR_OUT}/rga_browser.html"
PATH_BRIDGE="${DIR_OUT}/browser_bridge.js"

# Fail with reason rather than broken page.
#   Missing face renders as box and missing script as blank canvas, neither reporting
#   itself.
for path_needed in \
  "${NIM}" \
  "${DIR_PROJECT}/visualiser/browser/shell.html" \
  "${DIR_PROJECT}/visualiser/browser/glue.js" \
  "${DIR_PROJECT}/visualiser/browser/browser_bridge.nim"
do
  [ -e "${path_needed}" ] || { echo "Missing \`${path_needed}\`." >&2; exit 1; }
done

mkdir -p "${DIR_OUT}"

# Compile every shared module desktop runs, through JS backend.
#   Flags come from `browser_bridge.nim.cfg`, except `-d:release`, property of this
#   artefact: suite's JS build must keep checks and stack traces, page must not carry
#   them.
#   `-d:danger` rejected: buys tenth of frame by removing every bounds, range and field
#   check from one build reader runs; figures in `PROVENANCE.md`.
"${NIM}" js --hints:off -d:release -o:"${PATH_BRIDGE}" \
  "${DIR_PROJECT}/visualiser/browser/browser_bridge.nim"

# Inline each face at token naming it, so page reaches no external font host.
: > "${PATH_PAGE}"
while IFS= read -r line; do
  # Match token only where it stands as URL, so prose above may name it freely.
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
