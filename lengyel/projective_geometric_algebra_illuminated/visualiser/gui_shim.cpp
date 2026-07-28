// Expose the slice of Dear ImGui that the visualiser calls, as flat C entry points.
//
// Dear ImGui's own interface is C++ with default arguments, overloads and namespaces,
// none of which Nim can import. A facade is cheaper than a generated binding: it declares
// exactly the widgets used, and every default the visualiser relies on is written here
// once rather than repeated at each call site.
//
// Backends are Dear ImGui's own for SDL3 and OpenGL 3, used unmodified.

#include "imgui.h"
#include "backends/imgui_impl_sdl3.h"
#include "backends/imgui_impl_opengl3.h"

#include <SDL3/SDL.h>

// Cover Latin, the mathematical operators the PGA library writes its notation with,
// and subscript digits used by basis element names.
static const ImWchar RANGES_GLYPH[] = {
  0x0020, 0x00FF, // Latin and supplement.
  0x2010, 0x22FF, // Punctuation, subscripts, arrows, mathematical operators.
  0x2300, 0x23FF, // Miscellaneous technical.
  0x25A0, 0x26FF, // Geometric shapes and miscellaneous symbols.
  0x27C0, 0x27FF, // Supplemental mathematical operators.
  0,
};

// Remember whether the requested face was accepted, since Dear ImGui reports that only
// at the moment of loading and the caller wants to say so once, at startup.
static bool is_font_loaded = false;

extern "C" {

bool guiInit(SDL_Window* window, SDL_GLContext context, const char* path_font,
             float size_font) {
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
    is_font_loaded = ImGui::GetIO().Fonts->AddFontFromFileTTF(
                         path_font, size_font, nullptr, RANGES_GLYPH) != nullptr;
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

bool guiCheckbox(const char* label, bool* value) { return ImGui::Checkbox(label, value); }

bool guiDragFloat(const char* label, float* value, float speed, float lowest,
                  float highest) {
  return ImGui::DragFloat(label, value, speed, lowest, highest, "%.4f");
}

bool guiDragFloat3(const char* label, float* values, float speed) {
  return ImGui::DragFloat3(label, values, speed, 0.0f, 0.0f, "%.3f");
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

void guiIdPush(int id) { ImGui::PushID(id); }

void guiIdPop() { ImGui::PopID(); }

void guiWidthPush(float width) { ImGui::PushItemWidth(width); }

void guiWidthPop() { ImGui::PopItemWidth(); }

void guiDisabledPush(bool is_disabled) { ImGui::BeginDisabled(is_disabled); }

void guiDisabledPop() { ImGui::EndDisabled(); }

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

// One small filled cell per pool slot, coloured by whether it currently holds an object,
// wrapped to the panel's own width rather than assuming any fixed row length.
void guiPoolBar(const bool* are_alive, int count, float cell_size,
                 float r_alive, float g_alive, float b_alive,
                 float r_free, float g_free, float b_free) {
  const float spacing = 2.0f;
  const float avail = ImGui::GetContentRegionAvail().x;
  const int fitted = (int)((avail + spacing) / (cell_size + spacing));
  const int per_row = avail > cell_size ? (fitted < 1 ? 1 : fitted) : count;
  const int rows = (count + per_row - 1) / per_row;
  const ImU32 colour_alive =
      ImGui::ColorConvertFloat4ToU32(ImVec4(r_alive, g_alive, b_alive, 1.0f));
  const ImU32 colour_free =
      ImGui::ColorConvertFloat4ToU32(ImVec4(r_free, g_free, b_free, 1.0f));

  ImDrawList* draw_list = ImGui::GetWindowDrawList();
  const ImVec2 origin = ImGui::GetCursorScreenPos();
  for (int i = 0; i < count; ++i) {
    const int row = i / per_row;
    const int column = i % per_row;
    const ImVec2 top_left(origin.x + column * (cell_size + spacing),
                           origin.y + row * (cell_size + spacing));
    const ImVec2 bottom_right(top_left.x + cell_size, top_left.y + cell_size);
    draw_list->AddRectFilled(top_left, bottom_right,
                              are_alive[i] ? colour_alive : colour_free, 2.0f);
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
