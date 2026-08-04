## Bind subset of SDL3 that visualiser uses.
##
## SDL3 is depended on rather than derived, as windowing and input are external concerns
## this project exists to look past, not to understand.
##   Only symbols actually called are declared, so binding stays readable in one sitting.
##   Declarations import through header, so C compiler owns every struct layout and offset.
##   Cost of that choice is that SDL3 development headers must be present to compile.
##
## Event kinds and flags are mirrored as Nim constants so `case` can bind them.
##   Mirroring risks silent drift, so every value is checked against the header's own by a
##   generated static assertion, and a stale binding fails to compile rather than to work.
##
## Desktop-only; unreachable from the browser build. See `visualiser.nim`'s own "Render
## Paths" table.

{.experimental: "strictFuncs".}



#[ Binding Configuration ]#

const HEADER = "<SDL3/SDL.h>"
  ## Name header every declaration below imports through.

# Link SDL3 here rather than in a project config, so every binary importing this module
# links it without extra flags.
{.passL: "-lSDL3".}



#[ Type Definitions ]#

type
  Window* = pointer ## Refer to opaque `SDL_Window`.
  GlContext* = pointer ## Refer to opaque `SDL_GLContext`.

  EventKind* {.pure.} = enum ## Name event kinds visualiser reacts to.
    Quit = 0x100,
    WindowResized = 0x206,
    KeyDown = 0x300,
    MouseMotion = 0x400,
    MouseButtonDown = 0x401,
    MouseButtonUp = 0x402,
    MouseWheel = 0x403,

  Scancode* {.pure.} = enum ## Name physical keys visualiser reacts to.
    Escape = 41,
    S = 22,
    Y = 28,
    Z = 29,
    Q = 20,

  MouseButton* {.pure.} = enum ## Name mouse buttons visualiser reacts to.
    Left = 1,
    Middle = 2,
    Right = 3,

  KeyboardEvent* {.importc: "SDL_KeyboardEvent", header: HEADER, bycopy.} = object
    scancode* {.importc.}: uint32 ## Physical key, independent of layout.
    is_down* {.importc: "down".}: bool ## Whether key is pressed rather than released.
    modifiers* {.importc: "mod".}: uint16 ## Modifier keys held as this one went down.

  MouseMotionEvent* {.importc: "SDL_MouseMotionEvent", header: HEADER, bycopy.} = object
    x* {.importc.}: cfloat ## Position in window, in pixels, measured from top-left.
    y* {.importc.}: cfloat ## Position in window, in pixels, measured from top-left.
    xrel* {.importc.}: cfloat ## Motion since previous event, in pixels.
    yrel* {.importc.}: cfloat ## Motion since previous event, in pixels.

  MouseButtonEvent* {.importc: "SDL_MouseButtonEvent", header: HEADER, bycopy.} = object
    button* {.importc.}: uint8 ## Which button changed state.

  MouseWheelEvent* {.importc: "SDL_MouseWheelEvent", header: HEADER, bycopy.} = object
    y* {.importc.}: cfloat ## Scroll amount, positive away from user.

  Event* {.importc: "SDL_Event", header: HEADER, union, bycopy.} = object
    kind* {.importc: "type".}: uint32 ## Discriminates union; compare against `EventKind`.
    key* {.importc.}: KeyboardEvent
    motion* {.importc.}: MouseMotionEvent
    button* {.importc.}: MouseButtonEvent
    wheel* {.importc.}: MouseWheelEvent


const
  MODIFIER_CONTROL* = 0x00C0'u16
    ## Test a key event's own modifiers for either control key.
  MODIFIER_SHIFT* = 0x0003'u16
    ## Test a key event's own modifiers for either shift key.
  MODIFIER_COMMAND* = 0x0C00'u16
    ## Test a key event's own modifiers for either command key, which is what a reader on
    ## macOS presses where everyone else presses control.
  INIT_VIDEO* = 0x20'u32
    ## Ask `init` for video and event subsystems.
  WINDOW_OPENGL* = 0x02'u64
    ## Ask `createWindow` for window an OpenGL context can be bound to.
  WINDOW_RESIZABLE* = 0x20'u64
    ## Ask `createWindow` for window user may resize.
  WINDOW_HIDDEN* = 0x08'u64
    ## Ask `createWindow` for window that is never mapped, as headless render needs no view.
  GL_CONTEXT_MAJOR_VERSION* = 17'u32
  GL_CONTEXT_MINOR_VERSION* = 18'u32
  GL_CONTEXT_PROFILE_MASK* = 20'u32
  GL_DOUBLEBUFFER* = 5'u32
  GL_DEPTH_SIZE* = 6'u32
  GL_CONTEXT_PROFILE_CORE* = 0x0001'i32



#[ Foreign Declarations ]#

# Mechanical one-to-one imports of SDL3 entry points; see SDL3 documentation for each.
proc init*(flags: uint32): bool {.importc: "SDL_Init", header: HEADER, discardable.}
proc quit*() {.importc: "SDL_Quit", header: HEADER.}
proc getError*(): cstring {.importc: "SDL_GetError", header: HEADER.}
proc setHint*(name, value: cstring): bool
  {.importc: "SDL_SetHint", header: HEADER, discardable.}
proc createWindow*(title: cstring; width, height: cint; flags: uint64): Window
  {.importc: "SDL_CreateWindow", header: HEADER.}
proc destroyWindow*(window: Window) {.importc: "SDL_DestroyWindow", header: HEADER.}
proc getWindowSizeInPixels*(window: Window; width, height: ptr cint): bool
  {.importc: "SDL_GetWindowSizeInPixels", header: HEADER, discardable.}
proc glSetAttribute*(attribute: uint32; value: cint): bool
  {.importc: "SDL_GL_SetAttribute", header: HEADER, discardable.}
proc glCreateContext*(window: Window): GlContext
  {.importc: "SDL_GL_CreateContext", header: HEADER.}
proc glDestroyContext*(context: GlContext): bool
  {.importc: "SDL_GL_DestroyContext", header: HEADER, discardable.}
proc glSetSwapInterval*(interval: cint): bool
  {.importc: "SDL_GL_SetSwapInterval", header: HEADER, discardable.}
proc glSwapWindow*(window: Window): bool
  {.importc: "SDL_GL_SwapWindow", header: HEADER, discardable.}
proc pollEvent*(event: ptr Event): bool {.importc: "SDL_PollEvent", header: HEADER.}



#[ Binding Validation ]#

const lut_mirror_to_symbol = [
  (int(EventKind.Quit), "SDL_EVENT_QUIT"),
  (int(EventKind.WindowResized), "SDL_EVENT_WINDOW_RESIZED"),
  (int(EventKind.KeyDown), "SDL_EVENT_KEY_DOWN"),
  (int(EventKind.MouseMotion), "SDL_EVENT_MOUSE_MOTION"),
  (int(EventKind.MouseButtonDown), "SDL_EVENT_MOUSE_BUTTON_DOWN"),
  (int(EventKind.MouseButtonUp), "SDL_EVENT_MOUSE_BUTTON_UP"),
  (int(EventKind.MouseWheel), "SDL_EVENT_MOUSE_WHEEL"),
  (int(Scancode.Escape), "SDL_SCANCODE_ESCAPE"),
  (int(Scancode.S), "SDL_SCANCODE_S"),
  (int(Scancode.Y), "SDL_SCANCODE_Y"),
  (int(Scancode.Z), "SDL_SCANCODE_Z"),
  (int(Scancode.Q), "SDL_SCANCODE_Q"),
  (int(MODIFIER_CONTROL), "SDL_KMOD_CTRL"),
  (int(MODIFIER_SHIFT), "SDL_KMOD_SHIFT"),
  (int(MODIFIER_COMMAND), "SDL_KMOD_GUI"),
  (int(MouseButton.Left), "SDL_BUTTON_LEFT"),
  (int(MouseButton.Middle), "SDL_BUTTON_MIDDLE"),
  (int(MouseButton.Right), "SDL_BUTTON_RIGHT"),
  (int(INIT_VIDEO), "SDL_INIT_VIDEO"),
  (int(WINDOW_OPENGL), "SDL_WINDOW_OPENGL"),
  (int(WINDOW_RESIZABLE), "SDL_WINDOW_RESIZABLE"),
  (int(WINDOW_HIDDEN), "SDL_WINDOW_HIDDEN"),
  (int(GL_CONTEXT_MAJOR_VERSION), "SDL_GL_CONTEXT_MAJOR_VERSION"),
  (int(GL_CONTEXT_MINOR_VERSION), "SDL_GL_CONTEXT_MINOR_VERSION"),
  (int(GL_CONTEXT_PROFILE_MASK), "SDL_GL_CONTEXT_PROFILE_MASK"),
  (int(GL_DOUBLEBUFFER), "SDL_GL_DOUBLEBUFFER"),
  (int(GL_DEPTH_SIZE), "SDL_GL_DEPTH_SIZE"),
  (int(GL_CONTEXT_PROFILE_CORE), "SDL_GL_CONTEXT_PROFILE_CORE"),
] ## Pair every mirrored value with header's own name for it.


const CHECKS_MIRROR = block:
  ## Generate one static assertion per mirrored value, from table above.
  ##   Table is written once, and both sides of each check are read from it, so a mirror
  ##   cannot drift from the assertion that guards it.
  ##   Assertions are C++ rather than Nim because only the C++ compiler can see the
  ##   header's own values; that is also why they cost nothing at run time.
  var text = "#include " & HEADER & "\n"
  for (mirrored, symbol) in lut_mirror_to_symbol:
    text &= "static_assert((long long)(" & symbol & ") == " & $mirrored &
      ", \"SDL3 binding is stale: " & symbol & " was renumbered.\");\n"
  text

{.emit: CHECKS_MIRROR.}
