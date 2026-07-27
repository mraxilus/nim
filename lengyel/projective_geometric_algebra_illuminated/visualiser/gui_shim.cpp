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

} // extern "C"
