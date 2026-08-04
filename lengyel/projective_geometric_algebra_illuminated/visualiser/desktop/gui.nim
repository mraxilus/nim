## Bind facade over Dear ImGui declared in `gui_shim.cpp`.
##
## Dear ImGui is depended on rather than derived: an immediate-mode widget set is an
## external concern, like windowing and drivers.
##   Its own interface is C++ with overloads and default arguments, which Nim cannot import,
##   so `gui_shim.cpp` flattens the slice used into C entry points and this module binds them.
##   Cost of the facade is that adding a widget means touching two files, not one.
##
## Dear ImGui and its SDL3 and OpenGL 3 backends are compiled straight into the binary,
## so no prebuilt library has to be found at link time.
##   Sources are expected beside the visualiser, at `PATH_IMGUI`; see `dependencies.list`.
##
## Built-in font carries no mathematical operators, so a TrueType face is loaded over it.
##   Where the file is absent the built-in font stands, and notation degrades to boxes;
##   `isFontLoaded` reports which happened, rather than leaving the caller to guess.
##
## Desktop-only; unreachable from the browser build. See `visualiser.nim`'s own "Render
## Paths" table.

{.experimental: "strictFuncs".}

import std/os

import ./sdl3



#[ Dependency Configuration ]#

# Allow caller to point at Dear ImGui checkout elsewhere.
#   E.g. `--define:visualiser.path_imgui=/usr/src/imgui`.
const PATH_IMGUI* {.define: "visualiser.path_imgui".} = "../../deps/imgui"


const PATH_IMGUI_ROOTED =
  if isAbsolute(PATH_IMGUI): PATH_IMGUI
  else: currentSourcePath().parentDir / PATH_IMGUI
  ## Resolve dependency against this file, as C compiler runs from elsewhere.

{.passC: "-I" & PATH_IMGUI_ROOTED.}

# Widen `ImWchar` to 32 bits, which Dear ImGui offers for exactly this and defaults off.
#   The notation this GUI writes uses Lengyel's own bold operands (`𝐦`, U+1D426), and a
#   16-bit `ImWchar` cannot even express a codepoint past U+FFFF -- neither to name it in a
#   glyph range nor to look it up while drawing. Set here as a compiler flag rather than by
#   uncommenting it in the checkout's own `imconfig.h`: that checkout is a build-time
#   dependency this repository never commits, so an edit to it would not survive a reclone.
{.passC: "-DIMGUI_USE_WCHAR32".}

# Compile Dear ImGui and its two backends into binary, alongside facade over them.
{.compile: PATH_IMGUI_ROOTED / "imgui.cpp".}
{.compile: PATH_IMGUI_ROOTED / "imgui_draw.cpp".}
{.compile: PATH_IMGUI_ROOTED / "imgui_tables.cpp".}
{.compile: PATH_IMGUI_ROOTED / "imgui_widgets.cpp".}
{.compile: PATH_IMGUI_ROOTED / "backends/imgui_impl_sdl3.cpp".}
{.compile: PATH_IMGUI_ROOTED / "backends/imgui_impl_opengl3.cpp".}
{.compile: "gui_shim.cpp".}



#[ Facade Lifetime ]#

# Mechanical one-to-one imports of `gui_shim.cpp`; see that file for what each wraps.
proc init*(
  window: Window; context: GlContext;
  path_font, path_font_math, path_font_symbol: cstring; size_font: cfloat
): bool {.importc: "guiInit".}
proc shutdown*() {.importc: "guiShutdown".}
proc isFontLoaded*(): bool {.importc: "guiFontLoaded".}
proc processEvent*(event: ptr Event): bool {.importc: "guiProcessEvent", discardable.}
proc wantsMouse*(): bool {.importc: "guiWantsMouse".}
proc wantsKeyboard*(): bool {.importc: "guiWantsKeyboard".}
proc framerate*(): cfloat {.importc: "guiFramerate".}
proc frameBegin*() {.importc: "guiFrameBegin".}
proc frameEnd*() {.importc: "guiFrameEnd".}



#[ Facade Widgets ]#

# Mechanical one-to-one imports of `gui_shim.cpp`; see that file for what each wraps.
proc windowPlace*(x, y, width, height: cfloat) {.importc: "guiWindowPlace".}
proc windowBegin*(name: cstring): bool {.importc: "guiWindowBegin".}
proc windowEnd*() {.importc: "guiWindowEnd".}
proc childBegin*(name: cstring; width, height: cfloat): bool {.importc: "guiChildBegin".}
proc childEnd*() {.importc: "guiChildEnd".}
proc text*(text: cstring) {.importc: "guiText".}
proc textWrapped*(text: cstring) {.importc: "guiTextWrapped".}
proc textTinted*(text: cstring; red, green, blue: cfloat) {.importc: "guiTextTinted".}
proc header*(label: cstring; is_open_first: bool): bool {.importc: "guiHeader".}
proc button*(label: cstring): bool {.importc: "guiButton".}
proc buttonSmall*(label: cstring): bool {.importc: "guiButtonSmall".}
proc buttonToggle*(label: cstring; is_on: bool; width: cfloat): bool
  {.importc: "guiButtonToggle".}
  ## Draw one segment of a segmented control, tinted where it is the option in force and
  ## recessive where it is not.
proc buttonWide*(label: cstring; width: cfloat): bool {.importc: "guiButtonWide".}
  ## Draw a button filling the given width, for one that leads its own section.
proc checkbox*(label: cstring; value: ptr bool): bool {.importc: "guiCheckbox".}
proc dragFloat*(
  label: cstring; value: ptr cfloat; speed, lowest, highest: cfloat
): bool {.importc: "guiDragFloat".}
proc dragFloat3*(
  label: cstring; values: ptr cfloat; speed: cfloat
): bool {.importc: "guiDragFloat3".}
proc inputText*(label: cstring; buffer: cstring; capacity: cint): bool
  {.importc: "guiInputText".}
proc combo*(
  label: cstring; index: ptr cint; entries: ptr cstring; count: cint
): bool {.importc: "guiCombo".}
proc colorEdit3*(label: cstring; values: ptr cfloat): bool {.importc: "guiColorEdit3".}
proc separator*() {.importc: "guiSeparator".}
proc separatorText*(label: cstring) {.importc: "guiSeparatorText".}
proc sameLine*() {.importc: "guiSameLine".}
proc sameLineAt*(offset: cfloat) {.importc: "guiSameLineAt".}
  ## Continue the current line at a fixed distance from its start, so a column of controls
  ## lines up whatever the length of each one's own name.
proc groupBegin*() {.importc: "guiGroupBegin".}
  ## Start treating what follows as one item, so a name stacked over its own control still
  ## advances `sameLine` by the width of the pair.
proc groupEnd*() {.importc: "guiGroupEnd".}
proc buttonSmallWidth*(label: cstring): cfloat {.importc: "guiButtonSmallWidth".}
  ## Report the width `buttonSmall` would draw this label at, for a caller that has to know
  ## before it places anything.
proc alignRight*(width: cfloat) {.importc: "guiAlignRight".}
  ## Continue the current line with `width` reserved against the right edge, so a run of
  ## controls ends flush there whatever sits to its left.
proc idPush*(id: cint) {.importc: "guiIdPush".}
proc idPop*() {.importc: "guiIdPop".}
proc contentWidth*(): cfloat {.importc: "guiContentWidth".}
proc widthPush*(width: cfloat) {.importc: "guiWidthPush".}
proc widthPop*() {.importc: "guiWidthPop".}
proc disabledPush*(is_disabled: bool) {.importc: "guiDisabledPush".}
proc disabledPop*() {.importc: "guiDisabledPop".}
proc selectable*(
  label: cstring; is_selected: bool; width: cfloat
): bool {.importc: "guiSelectable".}
proc alphaPush*(alpha: cfloat) {.importc: "guiAlphaPush".}
proc alphaPop*() {.importc: "guiAlphaPop".}
proc textColorPush*(red, green, blue: cfloat) {.importc: "guiTextColorPush".}
proc textColorPop*() {.importc: "guiTextColorPop".}
proc tooltip*(text: cstring) {.importc: "guiTooltip".}
proc helpMarker*(text: cstring) {.importc: "guiHelpMarker".}
proc progressBar*(
  fraction: cfloat; overlay: cstring; width, height: cfloat;
  red_fill, green_fill, blue_fill, red_track, green_track, blue_track: cfloat;
) {.importc: "guiProgressBar".}
proc plotLines*(
  label: cstring; values: ptr cfloat; count, offset: cint; overlay: cstring;
  scale_min, scale_max, width, height: cfloat;
) {.importc: "guiPlotLines".}
proc poolBar*(colours: ptr cfloat; count: cint; cell_size: cfloat)
  {.importc: "guiPoolBar".}
  ## Draw one square cell per pool slot, wrapped to the panel's width. `colours` addresses
  ## `count` * 3 floats, red then green then blue per cell, so the caller alone decides
  ## what any slot's colour means.
proc overlayLine*(x1, y1, x2, y2, red, green, blue, alpha, thickness: cfloat)
  {.importc: "guiOverlayLine".}
proc overlayCircle*(cx, cy, radius, red, green, blue, alpha, thickness: cfloat)
  {.importc: "guiOverlayCircle".}
proc overlayPolyline*(
  points: ptr cfloat; count: cint; red, green, blue, alpha, thickness: cfloat;
  is_closed: cint
) {.importc: "guiOverlayPolyline".}
  ## Stroke one joined path through `count` points, `points` addressing that many x/y
  ## pairs -- one call rather than a segment each, so corners join cleanly.
