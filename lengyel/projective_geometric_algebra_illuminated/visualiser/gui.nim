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
const PATH_IMGUI* {.define: "visualiser.path_imgui".} = "../deps/imgui"

const PATH_IMGUI_ROOTED =
  if isAbsolute(PATH_IMGUI): PATH_IMGUI
  else: currentSourcePath().parentDir / PATH_IMGUI
  ## Resolve dependency against this file, as C compiler runs from elsewhere.

{.passC: "-I" & PATH_IMGUI_ROOTED.}

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
  window: Window; context: GlContext; path_font: cstring; size_font: cfloat
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
proc idPush*(id: cint) {.importc: "guiIdPush".}
proc idPop*() {.importc: "guiIdPop".}
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
proc poolBar*(
  are_alive: ptr bool; count: cint; cell_size: cfloat;
  red_alive, green_alive, blue_alive, red_free, green_free, blue_free: cfloat;
) {.importc: "guiPoolBar".}
proc overlayLine*(x1, y1, x2, y2, red, green, blue, alpha, thickness: cfloat)
  {.importc: "guiOverlayLine".}
proc overlayCircle*(cx, cy, radius, red, green, blue, alpha, thickness: cfloat)
  {.importc: "guiOverlayCircle".}
