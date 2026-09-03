## Bind facade over Dear ImGui declared in `gui_shim.cpp`.
##
## Dear ImGui is depended on rather than derived.
##   Immediate-mode widget set is external concern, like windowing and drivers.
##   Its interface is C++ with overloads and default arguments, which Nim cannot import.
##   `gui_shim.cpp` flattens slice used into C entry points and this module binds them.
##   Cost is that adding widget touches two files.
## Dear ImGui and its SDL3 and OpenGL 3 backends are compiled straight into binary.
##   No prebuilt library has to be found at link time.
##   Sources are expected at `PATH_IMGUI`; see `dependencies.list`.
## Built-in font carries no mathematical operators, so TrueType face is loaded over it.
##   Where file is absent built-in font stands and notation degrades to boxes;
##   `isFontLoaded` reports which happened.
##
## Desktop-only; unreachable from browser build. See `visualiser.nim`'s "Render Paths".

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

# Widen `ImWchar` to 32 bits, which Dear ImGui offers and defaults off.
#   Notation uses Lengyel's bold operands (`𝐦`, U+1D426), and 16-bit `ImWchar` cannot
#   express codepoint past U+FFFF.
#   Compiler flag rather than edit to checkout's `imconfig.h`: checkout is build-time
#   dependency never committed, so edit would not survive reclone.
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

# Import `gui_shim.cpp` one to one; see that file for what each wraps.
proc init*(
  window: Window; context: GlContext;
  path_font, path_font_math, path_font_symbol: cstring; size_font: cfloat
): bool {.importc: "guiInit".}
proc shutdown*() {.importc: "guiShutdown".}
proc isFontLoaded*(): bool {.importc: "guiFontLoaded".}
proc processEvent*(event: ptr Event): bool {.importc: "guiProcessEvent", discardable.}
proc wantsMouse*(): bool {.importc: "guiWantsMouse".}
proc wantsKeyboard*(): bool {.importc: "guiWantsKeyboard".}
proc isNavEnabled*(): bool {.importc: "guiIsNavEnabled".}
  ## Report whether Dear ImGui's keyboard navigation is in force.
  ##   What makes every panel control reachable by Tab.
proc wantsKeys*(): bool {.importc: "guiWantsKeys".}
  ## Report whether key belongs to Dear ImGui rather than 3D view.
  ##   See shim on why this is not `wantsKeyboard`.
proc framerate*(): cfloat {.importc: "guiFramerate".}
proc frameBegin*() {.importc: "guiFrameBegin".}
proc frameEnd*() {.importc: "guiFrameEnd".}



#[ Facade Widgets ]#

# Import `gui_shim.cpp` one to one; see that file for what each wraps.
proc windowPlace*(x, y, width, height: cfloat) {.importc: "guiWindowPlace".}
proc windowBegin*(name: cstring): bool {.importc: "guiWindowBegin".}
proc windowEnd*() {.importc: "guiWindowEnd".}
proc viewportWidth*(): cfloat {.importc: "guiViewportWidth".}
proc viewportHeight*(): cfloat {.importc: "guiViewportHeight".}
proc windowBeginPinned*(name: cstring; x, y, pivot_x, pivot_y: cfloat): bool
  {.importc: "guiWindowBeginPinned".}
  ## Begin undecorated window pinned to `x`/`y`; closed with `windowEnd`.
  ##   `pivot` names which of its corners that is.
proc childBegin*(name: cstring; width, height: cfloat): bool {.importc: "guiChildBegin".}
proc childEnd*() {.importc: "guiChildEnd".}
proc text*(text: cstring) {.importc: "guiText".}
proc textWrapped*(text: cstring) {.importc: "guiTextWrapped".}
proc textWrappedAt*(text: cstring, width: cfloat) {.importc: "guiTextWrappedAt".}
proc textTinted*(text: cstring; red, green, blue: cfloat) {.importc: "guiTextTinted".}
proc header*(label: cstring, is_open_first: bool): bool {.importc: "guiHeader".}
proc button*(label: cstring): bool {.importc: "guiButton".}
proc buttonSmall*(label: cstring): bool {.importc: "guiButtonSmall".}
proc buttonToggle*(label: cstring, is_on: bool, width: cfloat): bool
  {.importc: "guiButtonToggle".}
  ## Draw one segment of segmented control, tinted where it is option in force.
proc buttonWide*(label: cstring, width: cfloat): bool {.importc: "guiButtonWide".}
  ## Draw button filling given width, for one leading its section.
proc checkbox*(label: cstring, value: ptr bool): bool {.importc: "guiCheckbox".}
proc dragFloat*(
  label: cstring; value: ptr cfloat; speed, lowest, highest: cfloat
): bool {.importc: "guiDragFloat".}
proc dragFloat3*(
  label: cstring, values: ptr cfloat, speed: cfloat
): bool {.importc: "guiDragFloat3".}
proc inputText*(label: cstring, buffer: cstring, capacity: cint): bool
  {.importc: "guiInputText".}
proc combo*(
  label: cstring, index: ptr cint, entries: ptr cstring, count: cint
): bool {.importc: "guiCombo".}
proc colorEdit3*(label: cstring, values: ptr cfloat): bool {.importc: "guiColorEdit3".}
proc childHeightForRows*(count: cint): cfloat {.importc: "guiChildHeightForRows".}
  ## Report how tall bordered `childBegin` region holding `count` text lines must be.
  ##   Measured against font loaded.
proc tabBarBegin*(name: cstring): bool {.importc: "guiTabBarBegin".}
  ## Begin row of tabs; closed with `tabBarEnd`, entered only where it returns true.
proc tabBarEnd*() {.importc: "guiTabBarEnd".}
proc tabBegin*(label: cstring, is_forced: bool): bool {.importc: "guiTabBegin".}
  ## Begin one tab in row; true only for tab open, and closed with `tabEnd` only then.
  ##   `is_forced` opens it regardless of what reader last chose; see shim.
proc tabEnd*() {.importc: "guiTabEnd".}
proc separator*() {.importc: "guiSeparator".}
proc separatorText*(label: cstring) {.importc: "guiSeparatorText".}
proc sameLine*() {.importc: "guiSameLine".}
proc sameLineAt*(offset: cfloat) {.importc: "guiSameLineAt".}
  ## Continue current line at fixed distance from its start.
  ##   Column of controls then lines up whatever length of each name.
proc groupBegin*() {.importc: "guiGroupBegin".}
  ## Start treating what follows as one item.
  ##   Name stacked over its control then advances `sameLine` by width of pair.
proc groupEnd*() {.importc: "guiGroupEnd".}
proc buttonSmallWidth*(label: cstring): cfloat {.importc: "guiButtonSmallWidth".}
  ## Report width `buttonSmall` would draw this label at.
  ##   For caller that must know before placing anything.
proc textWidth*(text: cstring): cfloat {.importc: "guiTextWidth".}
  ## Measure text as it will be drawn, in pixels.
proc alignRight*(width: cfloat) {.importc: "guiAlignRight".}
  ## Continue current line with `width` reserved against right edge.
  ##   Run of controls then ends flush there.
proc idPush*(id: cint) {.importc: "guiIdPush".}
proc idPop*() {.importc: "guiIdPop".}
proc contentWidth*(): cfloat {.importc: "guiContentWidth".}
proc widthPush*(width: cfloat) {.importc: "guiWidthPush".}
proc widthPop*() {.importc: "guiWidthPop".}
proc disabledPush*(is_disabled: bool) {.importc: "guiDisabledPush".}
proc disabledPop*() {.importc: "guiDisabledPop".}
proc selectable*(
  label: cstring, is_selected: bool, width: cfloat
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
proc poolBar*(colours: ptr cfloat, count: cint, cell_size: cfloat)
  {.importc: "guiPoolBar".}
  ## Draw one square cell per pool slot, wrapped to panel's width.
  ##   `colours` addresses `count` * 3 floats, red then green then blue per cell.
proc overlayLine*(x1, y1, x2, y2, red, green, blue, alpha, thickness: cfloat)
  {.importc: "guiOverlayLine".}
proc overlayCircle*(
  cx, cy, radius, red, green, blue, alpha, thickness: cfloat; is_over_windows: cint
) {.importc: "guiOverlayCircle".}
  ## Stroke whole circle.
  ##   `is_over_windows` picks layer: zero for mark on object, which panels cover; one for
  ##   drag menu's centre dot, part of control being steered; see shim's `overlayList`.
proc overlayArc*(
  cx, cy, radius, fraction, red, green, blue, alpha, thickness: cfloat
) {.importc: "guiOverlayArc".}
  ## Stroke `fraction` of circle, clockwise from twelve o'clock; whole one at 1.
proc overlayChip*(
  cx, cy, width, height, red, green, blue, alpha, rounding: cfloat
) {.importc: "guiOverlayChip".}
  ## Fill rounded rectangle centred on `cx`/`cy`, for one wedge of drag menu.
proc overlayText*(cx, cy, red, green, blue, alpha: cfloat; text: cstring)
  {.importc: "guiOverlayText".}
  ## Write text centred on `cx`/`cy`, measured against font loaded.
proc overlayPolyline*(
  points: ptr cfloat; count: cint; red, green, blue, alpha, thickness: cfloat;
  is_closed: cint
) {.importc: "guiOverlayPolyline".}
  ## Stroke one joined path through `count` points, `points` addressing that many x/y pairs.
  ##   One call rather than segment each, so corners join cleanly.
proc overlayRibbon*(
  points: ptr cfloat; count: cint; red, green, blue, alpha: cfloat
) {.importc: "guiOverlayRibbon".}
  ## Fill one closed outline through `count` points.
  ##   For mark whose width varies along its length: orientation pulse, and drag band's
  ##   head.
