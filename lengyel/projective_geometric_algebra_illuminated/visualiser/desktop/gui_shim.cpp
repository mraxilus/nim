// Expose the slice of Dear ImGui that the visualiser calls, as flat C entry points.
//
// Dear ImGui's own interface is C++ with default arguments, overloads and namespaces,
// none of which Nim can import. A facade is cheaper than a generated binding: it declares
// exactly the widgets used, and every default the visualiser relies on is written here
// once rather than repeated at each call site.
//
// Backends are Dear ImGui's own for SDL3 and OpenGL 3, used unmodified.
//
// Desktop-only; unreachable from the browser build. See visualiser.nim's own "Render
// Paths" table.

#include "imgui.h"
#include "backends/imgui_impl_sdl3.h"
#include "backends/imgui_impl_opengl3.h"

#include <SDL3/SDL.h>

#include <utility>

// No single face covers what this GUI writes, so the atlas is built from three, merged in
// order of decreasing generality. Each range list names only what its own face is here to
// supply, so a glyph is never taken from a face that merely happens to have it too.
//   Verified by rendering every non-ASCII codepoint the source actually uses against all
//   three faces: 36 distinct codepoints, none missing. Re-run that check before narrowing
//   any range below.
static const ImWchar RANGES_TEXT[] = {
  0x0020, 0x00FF, // Latin and supplement.
  0x02B0, 0x02FF, // Spacing modifiers, which the notation accents its operands with.
  0x2010, 0x205F, // Punctuation, superscripts and subscripts.
  0x2080, 0x209F, // Subscript digits, used by basis element names.
  0,
};
static const ImWchar RANGES_MATH[] = {
  0x2190, 0x21FF, // Arrows.
  0x2200, 0x22FF, // Mathematical operators: the wedge, antiwedge, dots and complements.
  0x2300, 0x23FF, // Miscellaneous technical.
  0x27C0, 0x27EF, // Supplemental mathematical operators A: the geometric (anti)product.
  0x2A00, 0x2AFF, // Supplemental mathematical operators B.
  0x1D400, 0x1D7FF, // Mathematical alphanumerics: Lengyel's own bold operands.
  0,
};
static const ImWchar RANGES_SYMBOL[] = {
  0x25A0, 0x25FF, // Geometric shapes.
  0x2600, 0x26FF, // Miscellaneous symbols: the bulk and weight dual stars.
  0x2700, 0x27BF, // Dingbats: the abandon button's own cross.
  0,
};

// Remember whether the requested face was accepted, since Dear ImGui reports that only
// at the moment of loading and the caller wants to say so once, at startup.
static bool is_font_loaded = false;

extern "C" {

bool guiInit(SDL_Window* window, SDL_GLContext context, const char* path_font,
             const char* path_font_math, const char* path_font_symbol, float size_font) {
  IMGUI_CHECKVERSION();
  if (ImGui::CreateContext() == nullptr) return false;
  ImGui::StyleColorsDark();
  // Let the keyboard reach the panels at all. Without this every button, combo and field
  // here is pointer-only -- a total WCAG 2.1.1 Level A failure that this one line caused,
  // and that no amount of binding keys in the application itself could have fixed, since
  // the widgets are Dear ImGui's and only its own navigation can move between them.
  ImGui::GetIO().ConfigFlags |= ImGuiConfigFlags_NavEnableKeyboard;
  // Keep panel layout in memory only, so running the visualiser leaves no file behind.
  ImGui::GetIO().IniFilename = nullptr;
  ImGui::GetStyle().WindowRounding = 4.0f;
  ImGui::GetStyle().FrameRounding = 3.0f;
  if (!ImGui_ImplSDL3_InitForOpenGL(window, context)) return false;
  if (!ImGui_ImplOpenGL3_Init("#version 330 core")) return false;
  if (path_font != nullptr && path_font[0] != '\0') {
    ImFontAtlas* atlas = ImGui::GetIO().Fonts;
    is_font_loaded =
        atlas->AddFontFromFileTTF(path_font, size_font, nullptr, RANGES_TEXT) != nullptr;
    // Merge the two supplementary faces into that same font rather than adding separate
    // fonts: a merged range is drawn without the caller having to push a font around
    // whichever character happens to need it, which no caller could do mid-string anyway.
    ImFontConfig merge;
    merge.MergeMode = true;
    for (auto pair : {std::pair<const char*, const ImWchar*>{path_font_math, RANGES_MATH},
                      {path_font_symbol, RANGES_SYMBOL}}) {
      if (pair.first == nullptr || pair.first[0] == '\0') continue;
      if (atlas->AddFontFromFileTTF(pair.first, size_font, &merge, pair.second) == nullptr)
        is_font_loaded = false;
    }
  }
  return true;
}

void guiShutdown() {
  ImGui_ImplOpenGL3_Shutdown();
  ImGui_ImplSDL3_Shutdown();
  ImGui::DestroyContext();
}

bool guiFontLoaded() { return is_font_loaded; }

bool guiProcessEvent(const SDL_Event* event) { return ImGui_ImplSDL3_ProcessEvent(event); }

bool guiWantsMouse() { return ImGui::GetIO().WantCaptureMouse; }

bool guiWantsKeyboard() { return ImGui::GetIO().WantCaptureKeyboard; }

// Report whether keyboard navigation is actually in force, for a headless run to check
//   the configuration it cannot check the behaviour of: a window that never takes focus
//   never gives Dear ImGui the focus its navigation needs, so a scripted Tab demonstrates
//   nothing there, while this at least demonstrates the flag is set.
bool guiIsNavEnabled() {
  return (ImGui::GetIO().ConfigFlags & ImGuiConfigFlags_NavEnableKeyboard) != 0;
}

// Report whether Dear ImGui should get a key rather than the 3D view behind it.
//   Not `WantCaptureKeyboard`, which is what this looked like it should be and is wrong
//   here: enabling keyboard navigation makes that flag true from the very first frame,
//   with nothing focused and nobody having pressed Tab, so using it swallowed every view
//   key outright. Measured, not guessed -- `--drive-keys` reported the camera still at its
//   opening placement with the flag reading true.
//   The two things that genuinely mean "these keys are ImGui's": a text field is taking
//   input, or navigation has actually landed on a widget. Neither is true while the
//   reader is simply looking at the scene, which is when the view wants its own keys.
bool guiWantsKeys() {
  return ImGui::GetIO().WantTextInput || ImGui::IsAnyItemFocused();
}

float guiFramerate() { return ImGui::GetIO().Framerate; }

void guiFrameBegin() {
  ImGui_ImplOpenGL3_NewFrame();
  ImGui_ImplSDL3_NewFrame();
  ImGui::NewFrame();
}

void guiFrameEnd() {
  ImGui::Render();
  ImGui_ImplOpenGL3_RenderDrawData(ImGui::GetDrawData());
}

void guiWindowPlace(float x, float y, float width, float height) {
  ImGui::SetNextWindowPos(ImVec2(x, y), ImGuiCond_FirstUseEver);
  ImGui::SetNextWindowSize(ImVec2(width, height), ImGuiCond_FirstUseEver);
}

// Report the drawable area, so a caller can anchor something to a corner of it rather
//   than to a coordinate it guessed. Changes with the window, which is the point.
float guiViewportWidth() { return ImGui::GetIO().DisplaySize.x; }
float guiViewportHeight() { return ImGui::GetIO().DisplaySize.y; }

// Begin a window pinned where it is put, with nothing a reader could grab: no title bar,
//   no resize corner, no scrollbar, and sized to whatever it ends up holding. `pivot` is
//   which of the window's own corners `x`/`y` names -- (1, 1) anchors its bottom-right,
//   which is what a corner affordance wants and what a caller would otherwise have to
//   compute by laying the window out once and measuring it.
bool guiWindowBeginPinned(const char *name, float x, float y, float pivot_x,
                          float pivot_y) {
  ImGui::SetNextWindowPos(ImVec2(x, y), ImGuiCond_Always, ImVec2(pivot_x, pivot_y));
  return ImGui::Begin(name, nullptr,
                      ImGuiWindowFlags_NoTitleBar | ImGuiWindowFlags_NoResize |
                          ImGuiWindowFlags_NoMove | ImGuiWindowFlags_NoScrollbar |
                          ImGuiWindowFlags_NoSavedSettings |
                          ImGuiWindowFlags_AlwaysAutoResize);
}

bool guiWindowBegin(const char* name) { return ImGui::Begin(name); }

void guiWindowEnd() { ImGui::End(); }

bool guiChildBegin(const char* name, float width, float height) {
  return ImGui::BeginChild(name, ImVec2(width, height), ImGuiChildFlags_Borders);
}

void guiChildEnd() { ImGui::EndChild(); }

void guiText(const char* text) { ImGui::TextUnformatted(text); }

// Wrap at the panel's own right edge instead of clipping, for a line whose length is the
// data's to decide -- a full multivector runs past any width worth reserving for it.
void guiTextWrapped(const char* text) {
  ImGui::PushTextWrapPos(0.0f);
  ImGui::TextUnformatted(text);
  ImGui::PopTextWrapPos();
}

// Wrap at a width the caller states, for a window that sizes itself to its contents. Zero
// -- what `guiTextWrapped` passes -- means "the content region's right edge", which in an
// auto-sizing window is decided by the widest item in it; a wrapped paragraph is then both
// an input to that width and a consequence of it, and settles wherever the circularity
// leaves it. The help panel already knows the width it wants, so it says so.
void guiTextWrappedAt(const char* text, float width) {
  ImGui::PushTextWrapPos(ImGui::GetCursorPosX() + width);
  ImGui::TextUnformatted(text);
  ImGui::PopTextWrapPos();
}

void guiTextTinted(const char* text, float red, float green, float blue) {
  ImGui::PushStyleColor(ImGuiCol_Text, ImVec4(red, green, blue, 1.0f));
  ImGui::TextUnformatted(text);
  ImGui::PopStyleColor();
}

// Section headers carry the browser's own weight rather than Dear ImGui's default, which
// is a saturated blue bar per section -- five of them stacked read as the loudest thing in
// a panel whose job is to sit over a 3D scene. Tones are the browser's `--surface-raised`
// and `--border`, so a header is legible as a header and no louder than that.
bool guiHeader(const char* label, bool is_open_first) {
  ImGui::PushStyleColor(ImGuiCol_Header, ImVec4(0.106f, 0.129f, 0.169f, 1.0f));
  ImGui::PushStyleColor(ImGuiCol_HeaderHovered, ImVec4(0.165f, 0.196f, 0.239f, 1.0f));
  ImGui::PushStyleColor(ImGuiCol_HeaderActive, ImVec4(0.204f, 0.243f, 0.298f, 1.0f));
  const bool is_open = ImGui::CollapsingHeader(
      label, is_open_first ? ImGuiTreeNodeFlags_DefaultOpen : 0);
  ImGui::PopStyleColor(3);
  return is_open;
}

bool guiButton(const char* label) { return ImGui::Button(label); }

bool guiButtonSmall(const char* label) { return ImGui::SmallButton(label); }

// One segment of a segmented control: a button that shows whether it is the option in
// force, so both choices stay visible and switching costs one click rather than opening a
// list. Both states are styled explicitly, from the browser's own `.toggles button` rules
// -- the segment not in force must be *recessive*, and Dear ImGui's default button is a
// prominent blue that would otherwise make it read as the selected one.
bool guiButtonToggle(const char* label, bool is_on, float width) {
  if (is_on) {
    ImGui::PushStyleColor(ImGuiCol_Button, ImVec4(0.0f, 0.655f, 0.647f, 0.22f));
    ImGui::PushStyleColor(ImGuiCol_ButtonHovered, ImVec4(0.0f, 0.655f, 0.647f, 0.34f));
    ImGui::PushStyleColor(ImGuiCol_ButtonActive, ImVec4(0.0f, 0.655f, 0.647f, 0.48f));
    ImGui::PushStyleColor(ImGuiCol_Text, ImVec4(0.741f, 0.953f, 0.941f, 1.0f));
    ImGui::PushStyleColor(ImGuiCol_Border, ImVec4(0.0f, 0.655f, 0.647f, 1.0f));
  } else {
    // Filled and bordered rather than transparent, unlike the browser's own segment: there
    // the pill's track is what makes an unselected segment visible, and a panel drawn
    // straight onto the scene has no track to sit on. Tones are the browser's `--surface`
    // and `--border` so the two controls still read as the same thing.
    ImGui::PushStyleColor(ImGuiCol_Button, ImVec4(0.086f, 0.106f, 0.133f, 0.82f));
    ImGui::PushStyleColor(ImGuiCol_ButtonHovered, ImVec4(1.0f, 1.0f, 1.0f, 0.06f));
    ImGui::PushStyleColor(ImGuiCol_ButtonActive, ImVec4(1.0f, 1.0f, 1.0f, 0.12f));
    ImGui::PushStyleColor(ImGuiCol_Text, ImVec4(0.545f, 0.588f, 0.639f, 1.0f));
    ImGui::PushStyleColor(ImGuiCol_Border, ImVec4(0.165f, 0.196f, 0.239f, 1.0f));
  }
  ImGui::PushStyleVar(ImGuiStyleVar_FrameBorderSize, 1.0f);
  const bool pressed = ImGui::Button(label, ImVec2(width, 0.0f));
  ImGui::PopStyleVar();
  ImGui::PopStyleColor(5);
  return pressed;
}

// A button that fills a width the caller names, for one that leads its own section the way
// the browser's `.btn.primary` does -- Dear ImGui's plain button is only as wide as its
// own label.
bool guiButtonWide(const char* label, float width) {
  return ImGui::Button(label, ImVec2(width, 0.0f));
}

bool guiCheckbox(const char* label, bool* value) { return ImGui::Checkbox(label, value); }

bool guiDragFloat(const char* label, float* value, float speed, float lowest,
                  float highest) {
  // Four significant digits, not four decimal places: a coefficient of 3.5 should read
  // "3.5", not "3.5000", and one of 1664 should not lose its integer part to padding.
  return ImGui::DragFloat(label, value, speed, lowest, highest, "%.4g");
}

bool guiDragFloat3(const char* label, float* values, float speed) {
  return ImGui::DragFloat3(label, values, speed, 0.0f, 0.0f, "%.4g");
}

bool guiInputText(const char* label, char* buffer, int capacity) {
  return ImGui::InputText(label, buffer, (size_t)capacity);
}

bool guiCombo(const char* label, int* index, const char* const items[], int count) {
  return ImGui::Combo(label, index, items, count);
}

bool guiColorEdit3(const char* label, float* values) {
  return ImGui::ColorEdit3(label, values, ImGuiColorEditFlags_NoInputs);
}

void guiSeparator() { ImGui::Separator(); }

// One row of tabs, and one tab in it. Split into four calls because Nim cannot import a
// C++ scope guard, so the caller pairs begin with end exactly as it does for a window.
// `BeginTabItem` takes no open flag: every tab here is permanent, and a closable tab draws
// an X the caller has nothing to do about.
bool guiTabBarBegin(const char *name) { return ImGui::BeginTabBar(name); }

void guiTabBarEnd() { ImGui::EndTabBar(); }

// `is_forced` opens this tab whatever the reader last left open, which is how a headless
// run reaches a tab it cannot click -- see `visualiser.Options.index_help_driven`. Passed
// every frame while it is set, so nothing else can take the selection back.
bool guiTabBegin(const char *label, bool is_forced) {
  return ImGui::BeginTabItem(label, nullptr,
                             is_forced ? ImGuiTabItemFlags_SetSelected : 0);
}

void guiTabEnd() { ImGui::EndTabItem(); }

// Report how tall a bordered child region holding `count` lines of plain text has to be,
// so a caller sizing one does not have to restate Dear ImGui's own line spacing, window
// padding and border width -- three numbers it would have to guess at and then re-guess
// whenever the loaded font changes. `count` lines stack as count*line - one spacing, since
// the spacing sits between lines rather than after each.
float guiChildHeightForRows(int count) {
  const ImGuiStyle &style = ImGui::GetStyle();
  return count * ImGui::GetTextLineHeightWithSpacing() - style.ItemSpacing.y +
         2.0f * (style.WindowPadding.y + style.ChildBorderSize);
}

void guiSeparatorText(const char* label) { ImGui::SeparatorText(label); }

void guiSameLine() { ImGui::SameLine(); }

// Continue the current line at a fixed distance from its start, so a column of controls
// lines up under one another regardless of how long each one's own name is. Dear ImGui
// draws a widget's label to its right; this is what lets a caller put it on the left.
void guiSameLineAt(float offset) { ImGui::SameLine(offset); }

// Treat everything between the two as one item, so a name stacked over its own control
// still advances `guiSameLine` by the width of the pair. Dear ImGui lays widgets out one
// per line unless told otherwise, and has no notion of a labelled cell.
void guiGroupBegin() { ImGui::BeginGroup(); }

void guiGroupEnd() { ImGui::EndGroup(); }

// Width `guiButtonSmall` would draw this label at, for a caller lining a run of them up
// against the right edge rather than letting whatever precedes them decide where they sit.
// Measure text as it will be drawn, so a caller laying out a column can size it from what
//   actually goes in the column rather than from a number tuned by eye against today's
//   longest entry.
float guiTextWidth(const char *text) { return ImGui::CalcTextSize(text).x; }

float guiButtonSmallWidth(const char* label) {
  return ImGui::CalcTextSize(label).x + ImGui::GetStyle().FramePadding.x * 2.0f;
}

// Continue the current line with `width` of it reserved against the right edge, so a run
// of controls ends flush there whatever sits to its left.
void guiAlignRight(float width) {
  ImGui::SameLine(0.0f, 0.0f);
  ImGui::SetCursorPosX(ImGui::GetCursorPosX() + ImGui::GetContentRegionAvail().x - width);
}

void guiIdPush(int id) { ImGui::PushID(id); }

void guiIdPop() { ImGui::PopID(); }

// Width still free on the current line, so a caller laying widgets out with `sameLine`
// can decide for itself where to wrap -- Dear ImGui runs them off the edge otherwise.
float guiContentWidth() { return ImGui::GetContentRegionAvail().x; }

void guiWidthPush(float width) { ImGui::PushItemWidth(width); }

void guiWidthPop() { ImGui::PopItemWidth(); }

void guiDisabledPush(bool is_disabled) { ImGui::BeginDisabled(is_disabled); }

void guiDisabledPop() { ImGui::EndDisabled(); }

// Row that draws its own selected-state highlight, for a list where one entry is current.
// Sized explicitly so following widgets share the line rather than being pushed below by
// a selectable's own default full-remaining-width.
bool guiSelectable(const char* label, bool is_selected, float width) {
  return ImGui::Selectable(label, is_selected, 0, ImVec2(width, 0.0f));
}

// Scale everything drawn until the matching pop, for content that should read as present
// but out of focus. Multiplies rather than replaces, so nesting inside a disabled block
// keeps that block's own dimming too. Unlike `guiDisabledPush` this leaves widgets live:
// a hidden object's own row must stay clickable in order to unhide it.
void guiAlphaPush(float alpha) {
  ImGui::PushStyleVar(ImGuiStyleVar_Alpha, ImGui::GetStyle().Alpha * alpha);
}

void guiAlphaPop() { ImGui::PopStyleVar(); }

// Tint every widget's text until the matching pop, for a run of widgets that share one
// item's colour. `guiTextTinted` covers the single-label case; this covers a whole row.
void guiTextColorPush(float red, float green, float blue) {
  ImGui::PushStyleColor(ImGuiCol_Text, ImVec4(red, green, blue, 1.0f));
}

void guiTextColorPop() { ImGui::PopStyleColor(); }

// Attach to whatever widget was laid out immediately before this call, so a control
// gains an on-hover explanation without a separate marker glyph competing for space.
void guiTooltip(const char* text) {
  if (ImGui::IsItemHovered(ImGuiHoveredFlags_DelayNormal)) ImGui::SetTooltip("%s", text);
}

// Draw a standalone "(?)" for a concept with no single widget to hang an explanation
// off, wrapped to a readable width rather than one unbroken line.
void guiHelpMarker(const char* text) {
  ImGui::TextDisabled("(?)");
  if (ImGui::IsItemHovered(ImGuiHoveredFlags_DelayNormal)) {
    ImGui::BeginTooltip();
    ImGui::PushTextWrapPos(ImGui::GetFontSize() * 25.0f);
    ImGui::TextUnformatted(text);
    ImGui::PopTextWrapPos();
    ImGui::EndTooltip();
  }
}

// Fraction filled in one colour, remainder in another, so caller can mean "active" and
// "free" rather than accept the theme's own default progress-bar colours.
void guiProgressBar(float fraction, const char* overlay, float width, float height,
                     float r_fill, float g_fill, float b_fill,
                     float r_track, float g_track, float b_track) {
  ImGui::PushStyleColor(ImGuiCol_PlotHistogram, ImVec4(r_fill, g_fill, b_fill, 1.0f));
  ImGui::PushStyleColor(ImGuiCol_FrameBg, ImVec4(r_track, g_track, b_track, 1.0f));
  ImGui::ProgressBar(fraction, ImVec2(width, height), overlay);
  ImGui::PopStyleColor(2);
}

// Live line graph over `count` samples, read starting `offset` frames back so caller's
// own ring buffer needs no shifting to stay in chronological order on screen.
void guiPlotLines(const char* label, const float* values, int count, int offset,
                   const char* overlay, float scale_min, float scale_max,
                   float width, float height) {
  ImGui::PlotLines(label, values, count, offset, overlay, scale_min, scale_max,
                    ImVec2(width, height));
}

// One small filled cell per pool slot, wrapped to the panel's own width rather than
// assuming any fixed row length. `colours` holds three floats per cell, red then green
// then blue: the caller alone decides what a slot's colour means, so nothing here has to
// know which slots are occupied or which palette a live one is drawn in.
void guiPoolBar(const float* colours, int count, float cell_size) {
  const float spacing = 2.0f;
  const float avail = ImGui::GetContentRegionAvail().x;
  const int fitted = (int)((avail + spacing) / (cell_size + spacing));
  const int per_row = avail > cell_size ? (fitted < 1 ? 1 : fitted) : count;
  const int rows = (count + per_row - 1) / per_row;

  ImDrawList* draw_list = ImGui::GetWindowDrawList();
  const ImVec2 origin = ImGui::GetCursorScreenPos();
  for (int i = 0; i < count; ++i) {
    const int row = i / per_row;
    const int column = i % per_row;
    const ImVec2 top_left(origin.x + column * (cell_size + spacing),
                           origin.y + row * (cell_size + spacing));
    const ImVec2 bottom_right(top_left.x + cell_size, top_left.y + cell_size);
    const ImU32 colour = ImGui::ColorConvertFloat4ToU32(
        ImVec4(colours[i * 3], colours[i * 3 + 1], colours[i * 3 + 2], 1.0f));
    draw_list->AddRectFilled(top_left, bottom_right, colour, 2.0f);
  }
  ImGui::Dummy(ImVec2(avail, rows * (cell_size + spacing)));
}

// Draw directly onto the foreground layer, above every window, for cursor feedback that
// belongs to the 3D view rather than to any panel: a rubber-band line while dragging, a
// ring around whatever the cursor is over. Screen space only; caller does the projection.
void guiOverlayLine(float x1, float y1, float x2, float y2, float red, float green,
                     float blue, float alpha, float thickness) {
  ImGui::GetForegroundDrawList()->AddLine(
      ImVec2(x1, y1), ImVec2(x2, y2),
      ImGui::ColorConvertFloat4ToU32(ImVec4(red, green, blue, alpha)), thickness);
}

void guiOverlayCircle(float cx, float cy, float radius, float red, float green, float blue,
                       float alpha, float thickness) {
  ImGui::GetForegroundDrawList()->AddCircle(
      ImVec2(cx, cy), radius,
      ImGui::ColorConvertFloat4ToU32(ImVec4(red, green, blue, alpha)), 0, thickness);
}

// Draw part of a circle, clockwise from twelve o'clock, for a press filling its own marker
//   as it matures into a selection. `fraction` is how much of the turn to stroke, in 0 .. 1.
//   A whole turn is handed to AddCircle above rather than traced here, so a marker that is
//   not animating draws through exactly the call it drew through before this existed and
//   lands on exactly the same pixels.
//   Clockwise in *screen* terms, which is why the angle subtracts: y runs downward here, so
//   the sense that reads as clockwise to a viewer is the one that decreases the angle.
void guiOverlayArc(float cx, float cy, float radius, float fraction, float red, float green,
                   float blue, float alpha, float thickness) {
  if (fraction <= 0.0f) return;
  if (fraction >= 1.0f) {
    guiOverlayCircle(cx, cy, radius, red, green, blue, alpha, thickness);
    return;
  }
  const float TURN = 6.28318530717958647692f;
  const float START = -TURN * 0.25f; // Twelve o'clock, with y downward.
  ImDrawList *list = ImGui::GetForegroundDrawList();
  list->PathArcTo(ImVec2(cx, cy), radius, START, START - TURN * fraction, 0);
  list->PathStroke(ImGui::ColorConvertFloat4ToU32(ImVec4(red, green, blue, alpha)),
                   ImDrawFlags_None, thickness);
}

// Draw a marker's own polyline as one path rather than a run of separate line calls, so
//   Dear ImGui joins its corners instead of leaving a nick at each one -- visible on a
//   thin overlay stroke, and the whole reason a plane's marker is a path at all. `points`
//   addresses `count` pairs of floats, x then y.
void guiOverlayPolyline(const float *points, int count, float red, float green, float blue,
                        float alpha, float thickness, int is_closed) {
  if (count < 2) return;
  ImDrawList *list = ImGui::GetForegroundDrawList();
  for (int i = 0; i < count; ++i) {
    list->PathLineTo(ImVec2(points[2 * i], points[2 * i + 1]));
  }
  list->PathStroke(ImGui::ColorConvertFloat4ToU32(ImVec4(red, green, blue, alpha)),
                   is_closed ? ImDrawFlags_Closed : ImDrawFlags_None, thickness);
}

// Fill a marker's own closed outline, for a shape whose width varies along its length and
//   so cannot be a stroke: the orientation pulse tapering down its tail, and the drag
//   band's head. `points` addresses `count` pairs of floats, x then y, already closed --
//   the caller shapes the ribbon (`marker.ribbonAlong`), this only fills it.
//   Concave rather than convex: a ribbon following a curved outline bends away from
//   straight, and the convex fill would bridge that bend with a chord across the marker.
//   Wound to a fixed handedness here rather than by the caller, because it is Dear ImGui
//   that cares and no one else: its antialiased fill offsets each edge by the normal
//   `(dy, -dx)`, which points out of the shape for one winding and into it for the other.
//   Handed a ribbon wound the wrong way it pushes the whole transparent fringe *inward*,
//   under the fill, and the mark comes out with hard aliased edges -- measurably so: a
//   column across it steps 16 to 248 with nothing between, where every other overlay
//   stroke ramps through it. The pulse's own winding flips with the orientation it
//   reports, so this cannot be settled once at the call site.
void guiOverlayRibbon(const float *points, int count, float red, float green, float blue,
                      float alpha) {
  if (count < 3) return;
  float twice_area = 0.0f;
  for (int i = 0, j = count - 1; i < count; j = i++) {
    twice_area += points[2 * j] * points[2 * i + 1] - points[2 * i] * points[2 * j + 1];
  }
  ImDrawList *list = ImGui::GetForegroundDrawList();
  for (int n = 0; n < count; ++n) {
    const int i = twice_area >= 0.0f ? n : count - 1 - n;
    list->PathLineTo(ImVec2(points[2 * i], points[2 * i + 1]));
  }
  list->PathFillConcave(ImGui::ColorConvertFloat4ToU32(ImVec4(red, green, blue, alpha)));
}

// Fill a rounded rectangle centred on `cx`/`cy` straight onto the foreground layer, for
//   one wedge of the drag menu. Centred rather than placed from a corner because every
//   caller of it knows where the wedge's middle goes and nothing else about its size --
//   which comes from the label it has to hold.
void guiOverlayChip(float cx, float cy, float width, float height, float red, float green,
                    float blue, float alpha, float rounding) {
  ImGui::GetForegroundDrawList()->AddRectFilled(
      ImVec2(cx - 0.5f * width, cy - 0.5f * height),
      ImVec2(cx + 0.5f * width, cy + 0.5f * height),
      ImGui::ColorConvertFloat4ToU32(ImVec4(red, green, blue, alpha)), rounding);
}

// Write text centred on `cx`/`cy` onto the foreground layer, in the font already loaded.
//   Centred here rather than by the caller so the measurement and the placement use the
//   same font metrics; a caller offsetting by its own guess drifts as soon as the face
//   loaded is not the one it guessed against.
void guiOverlayText(float cx, float cy, float red, float green, float blue, float alpha,
                    const char *text) {
  const ImVec2 size = ImGui::CalcTextSize(text);
  ImGui::GetForegroundDrawList()->AddText(
      ImVec2(cx - 0.5f * size.x, cy - 0.5f * size.y),
      ImGui::ColorConvertFloat4ToU32(ImVec4(red, green, blue, alpha)), text);
}

} // extern "C"
