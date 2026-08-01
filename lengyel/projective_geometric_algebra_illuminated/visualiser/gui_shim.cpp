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

void guiTextTinted(const char* text, float red, float green, float blue) {
  ImGui::PushStyleColor(ImGuiCol_Text, ImVec4(red, green, blue, 1.0f));
  ImGui::TextUnformatted(text);
  ImGui::PopStyleColor();
}

bool guiHeader(const char* label, bool is_open_first) {
  return ImGui::CollapsingHeader(
      label, is_open_first ? ImGuiTreeNodeFlags_DefaultOpen : 0);
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
    ImGui::PushStyleColor(ImGuiCol_Button, ImVec4(0.0f, 0.0f, 0.0f, 0.0f));
    ImGui::PushStyleColor(ImGuiCol_ButtonHovered, ImVec4(1.0f, 1.0f, 1.0f, 0.06f));
    ImGui::PushStyleColor(ImGuiCol_ButtonActive, ImVec4(1.0f, 1.0f, 1.0f, 0.12f));
    ImGui::PushStyleColor(ImGuiCol_Text, ImVec4(0.545f, 0.588f, 0.639f, 1.0f));
    ImGui::PushStyleColor(ImGuiCol_Border, ImVec4(0.0f, 0.0f, 0.0f, 0.0f));
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

void guiSeparatorText(const char* label) { ImGui::SeparatorText(label); }

void guiSameLine() { ImGui::SameLine(); }

// Continue the current line at a fixed distance from its start, so a column of controls
// lines up under one another regardless of how long each one's own name is. Dear ImGui
// draws a widget's label to its right; this is what lets a caller put it on the left.
void guiSameLineAt(float offset) { ImGui::SameLine(offset); }

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

} // extern "C"
