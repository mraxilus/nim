## Bind the windowing, input and GL entry points the desktop build calls.
##
## Hand-written rather than pulled from a binding package: the tool needs about forty entry
## points, all stable C, and a package would bring a build step and a version to track for
## nothing. Everything here is external — a window, a context, a draw call — which is exactly
## the kind of dependency this project takes.
##
## The GL entry points beyond 1.1 are resolved through the window library's own loader at
## startup, because a Linux GL driver exports only the 1.1 set from `libGL`.

{.experimental: "strictFuncs".}

{.passL: "-lglfw -lGL -lm".}
{.passC: "-DGL_GLEXT_PROTOTYPES".}



#[ Window Library ]#

const GLFW_HEADER = "<GLFW/glfw3.h>"

type
  Window* = distinct pointer
    ## Address a window and its GL context.
  Monitor* = distinct pointer
    ## Address a monitor; only ever passed as nothing here, for a windowed context.

const
  GLFW_VISIBLE* = 0x00020004
  GLFW_RESIZABLE* = 0x00020003
  GLFW_SAMPLES* = 0x0002100D
  GLFW_CONTEXT_VERSION_MAJOR* = 0x00022002
  GLFW_CONTEXT_VERSION_MINOR* = 0x00022003
  GLFW_PRESS* = 1
  GLFW_RELEASE* = 0
  GLFW_MOUSE_BUTTON_LEFT* = 0
  GLFW_MOUSE_BUTTON_RIGHT* = 1
  GLFW_MOUSE_BUTTON_MIDDLE* = 2
  GLFW_KEY_BACKSPACE* = 259
  GLFW_KEY_ENTER* = 257
  GLFW_KEY_ESCAPE* = 256
  GLFW_KEY_LEFT_SHIFT* = 340
  GLFW_KEY_RIGHT_SHIFT* = 344

proc glfwInit*(): cint {.importc, header: GLFW_HEADER.}
  ## Start the window library.
proc glfwTerminate*() {.importc, header: GLFW_HEADER.}
  ## Stop the window library.
proc glfwWindowHint*(hint, value: cint) {.importc, header: GLFW_HEADER.}
  ## Set a hint for the next window created.
proc glfwCreateWindow*(
  width, height: cint, title: cstring, monitor: Monitor, share: Window
): Window {.importc, header: GLFW_HEADER.}
  ## Create a window and its GL context.
proc glfwDestroyWindow*(window: Window) {.importc, header: GLFW_HEADER.}
  ## Destroy a window.
proc glfwMakeContextCurrent*(window: Window) {.importc, header: GLFW_HEADER.}
  ## Bind a window's GL context to this thread.
proc glfwSwapBuffers*(window: Window) {.importc, header: GLFW_HEADER.}
  ## Present the drawn frame.
proc glfwSwapInterval*(interval: cint) {.importc, header: GLFW_HEADER.}
  ## Set how many refreshes a present waits for; zero uncaps the frame rate.
proc glfwPollEvents*() {.importc, header: GLFW_HEADER.}
  ## Drain the event queue.
proc glfwWindowShouldClose*(window: Window): cint {.importc, header: GLFW_HEADER.}
  ## Report whether the window has been asked to close.
proc glfwSetWindowShouldClose*(
  window: Window, value: cint
) {.importc, header: GLFW_HEADER.}
  ## Ask the window to close.
proc glfwGetFramebufferSize*(
  window: Window, width, height: ptr cint
) {.importc, header: GLFW_HEADER.}
  ## Read the drawable size in pixels.
proc glfwGetCursorPos*(
  window: Window, x, y: ptr cdouble
) {.importc, header: GLFW_HEADER.}
  ## Read the pointer position.
proc glfwGetMouseButton*(
  window: Window, button: cint
): cint {.importc, header: GLFW_HEADER.}
  ## Read a mouse button's state.
proc glfwGetKey*(window: Window, key: cint): cint {.importc, header: GLFW_HEADER.}
  ## Read a key's state.
proc glfwGetTime*(): cdouble {.importc, header: GLFW_HEADER.}
  ## Read seconds since the library started.

type
  MouseButtonCallback* = proc (
    window: Window, button, action, modifiers: cint
  ) {.cdecl.}
  ScrollCallback* = proc (window: Window, x, y: cdouble) {.cdecl.}
  CharCallback* = proc (window: Window, codepoint: cuint) {.cdecl.}
  KeyCallback* = proc (
    window: Window, key, scancode, action, modifiers: cint
  ) {.cdecl.}

proc glfwSetMouseButtonCallback*(
  window: Window, callback: MouseButtonCallback
): MouseButtonCallback {.importc, header: GLFW_HEADER, discardable.}
  ## Receive button presses and releases.
proc glfwSetScrollCallback*(
  window: Window, callback: ScrollCallback
): ScrollCallback {.importc, header: GLFW_HEADER, discardable.}
  ## Receive wheel notches.
proc glfwSetCharCallback*(
  window: Window, callback: CharCallback
): CharCallback {.importc, header: GLFW_HEADER, discardable.}
  ## Receive typed characters.
proc glfwSetKeyCallback*(
  window: Window, callback: KeyCallback
): KeyCallback {.importc, header: GLFW_HEADER, discardable.}
  ## Receive key presses, for editing keys that produce no character.



#[ Graphics Library ]#

const GL_HEADER = "<GL/gl.h>"

type
  GLenum* = cuint
  GLbitfield* = cuint
  GLuint* = cuint
  GLint* = cint
  GLsizei* = cint
  GLfloat* = cfloat
  GLboolean* = uint8
  GLchar* = char
  GLintptr* = int
  GLsizeiptr* = int

const
  GL_COLOR_BUFFER_BIT* = 0x00004000.GLbitfield
  GL_DEPTH_BUFFER_BIT* = 0x00000100.GLbitfield
  GL_DEPTH_TEST* = 0x0B71.GLenum
  GL_BLEND* = 0x0BE2.GLenum
  GL_SRC_ALPHA* = 0x0302.GLenum
  GL_ONE_MINUS_SRC_ALPHA* = 0x0303.GLenum
  GL_TRIANGLES* = 0x0004.GLenum
  GL_LINES* = 0x0001.GLenum
  GL_POINTS* = 0x0000.GLenum
  GL_KIND_FLOAT* = 0x1406.GLenum
    ## Name GL's own `GL_FLOAT`; renamed because Nim reads that as the type alias `GLfloat`.
  GL_FALSE* = 0.GLboolean
  GL_TRUE* = 1.GLboolean
  GL_ARRAY_BUFFER* = 0x8892.GLenum
  GL_DYNAMIC_DRAW* = 0x88E8.GLenum
  GL_VERTEX_SHADER* = 0x8B31.GLenum
  GL_FRAGMENT_SHADER* = 0x8B30.GLenum
  GL_COMPILE_STATUS* = 0x8B81.GLenum
  GL_LINK_STATUS* = 0x8B82.GLenum
  GL_TEXTURE_2D* = 0x0DE1.GLenum
  GL_TEXTURE0* = 0x84C0.GLenum
  GL_TEXTURE_MIN_FILTER* = 0x2801.GLenum
  GL_TEXTURE_MAG_FILTER* = 0x2800.GLenum
  GL_TEXTURE_WRAP_S* = 0x2802.GLenum
  GL_TEXTURE_WRAP_T* = 0x2803.GLenum
  GL_LINEAR* = 0x2601.GLint
  GL_CLAMP_TO_EDGE* = 0x812F.GLint
  GL_RED* = 0x1903.GLenum
  GL_R8* = 0x8229.GLint
  GL_RGBA* = 0x1908.GLenum
  GL_UNSIGNED_BYTE* = 0x1401.GLenum
  GL_PACK_ALIGNMENT* = 0x0D05.GLenum
  GL_UNPACK_ALIGNMENT* = 0x0CF5.GLenum
  GL_PROGRAM_POINT_SIZE* = 0x8642.GLenum
  GL_VERTEX_PROGRAM_POINT_SIZE* = 0x8642.GLenum
  GL_MULTISAMPLE* = 0x809D.GLenum

proc glClear*(mask: GLbitfield) {.importc, header: GL_HEADER.}
  ## Clear the named buffers.
proc glClearColor*(r, g, b, a: GLfloat) {.importc, header: GL_HEADER.}
  ## Set the colour a clear writes.
proc glEnable*(capability: GLenum) {.importc, header: GL_HEADER.}
  ## Turn a capability on.
proc glDisable*(capability: GLenum) {.importc, header: GL_HEADER.}
  ## Turn a capability off.
proc glBlendFunc*(source, destination: GLenum) {.importc, header: GL_HEADER.}
  ## Set how a fragment blends with what is already there.
proc glViewport*(x, y: GLint, width, height: GLsizei) {.importc, header: GL_HEADER.}
  ## Set the drawable region.
proc glLineWidth*(width: GLfloat) {.importc, header: GL_HEADER.}
  ## Set the width lines draw at.
proc glDepthMask*(flag: GLboolean) {.importc, header: GL_HEADER.}
  ## Turn depth writes on or off, leaving the test alone.
proc glDrawArrays*(mode: GLenum, first: GLint, count: GLsizei) {.importc, header: GL_HEADER.}
  ## Draw from the bound buffer.
proc glGenTextures*(count: GLsizei, textures: ptr GLuint) {.importc, header: GL_HEADER.}
  ## Reserve texture names.
proc glBindTexture*(target: GLenum, texture: GLuint) {.importc, header: GL_HEADER.}
  ## Bind a texture to a target.
proc glTexParameteri*(
  target: GLenum, name: GLenum, value: GLint
) {.importc, header: GL_HEADER.}
  ## Set a texture parameter.
proc glTexImage2D*(
  target: GLenum, level: GLint, internal: GLint, width, height: GLsizei, border: GLint,
  format, kind: GLenum, pixels: pointer
) {.importc, header: GL_HEADER.}
  ## Upload a texture image.
proc glPixelStorei*(name: GLenum, value: GLint) {.importc, header: GL_HEADER.}
  ## Set how pixel rows are packed.
proc glReadPixels*(
  x, y: GLint, width, height: GLsizei, format, kind: GLenum, pixels: pointer
) {.importc, header: GL_HEADER.}
  ## Read the framebuffer back, for a screenshot or a capture frame.
proc glGetError*(): GLenum {.importc, header: GL_HEADER.}
  ## Read and clear the error flag.
proc glFinish*() {.importc, header: GL_HEADER.}
  ## Block until every issued command has completed.

# Everything below is GL 2.0 or later, so it is resolved through the loader at startup.
proc glCreateShader*(kind: GLenum): GLuint {.importc, header: GL_HEADER.}
proc glShaderSource*(
  shader: GLuint, count: GLsizei, source: ptr cstring, length: ptr GLint
) {.importc, header: GL_HEADER.}
proc glCompileShader*(shader: GLuint) {.importc, header: GL_HEADER.}
proc glGetShaderiv*(
  shader: GLuint, name: GLenum, value: ptr GLint
) {.importc, header: GL_HEADER.}
proc glGetShaderInfoLog*(
  shader: GLuint, size: GLsizei, length: ptr GLsizei, log: cstring
) {.importc, header: GL_HEADER.}
proc glCreateProgram*(): GLuint {.importc, header: GL_HEADER.}
proc glAttachShader*(program, shader: GLuint) {.importc, header: GL_HEADER.}
proc glLinkProgram*(program: GLuint) {.importc, header: GL_HEADER.}
proc glGetProgramiv*(
  program: GLuint, name: GLenum, value: ptr GLint
) {.importc, header: GL_HEADER.}
proc glGetProgramInfoLog*(
  program: GLuint, size: GLsizei, length: ptr GLsizei, log: cstring
) {.importc, header: GL_HEADER.}
proc glUseProgram*(program: GLuint) {.importc, header: GL_HEADER.}
proc glGetUniformLocation*(
  program: GLuint, name: cstring
): GLint {.importc, header: GL_HEADER.}
proc glGetAttribLocation*(
  program: GLuint, name: cstring
): GLint {.importc, header: GL_HEADER.}
proc glUniformMatrix4fv*(
  location: GLint, count: GLsizei, transpose: GLboolean, value: ptr GLfloat
) {.importc, header: GL_HEADER.}
proc glUniform1f*(location: GLint, value: GLfloat) {.importc, header: GL_HEADER.}
proc glUniform1i*(location: GLint, value: GLint) {.importc, header: GL_HEADER.}
proc glUniform2f*(location: GLint, x, y: GLfloat) {.importc, header: GL_HEADER.}
proc glUniform4f*(location: GLint, x, y, z, w: GLfloat) {.importc, header: GL_HEADER.}
proc glGenBuffers*(count: GLsizei, buffers: ptr GLuint) {.importc, header: GL_HEADER.}
proc glBindBuffer*(target: GLenum, buffer: GLuint) {.importc, header: GL_HEADER.}
proc glBufferData*(
  target: GLenum, size: GLsizeiptr, data: pointer, usage: GLenum
) {.importc, header: GL_HEADER.}
proc glEnableVertexAttribArray*(index: GLuint) {.importc, header: GL_HEADER.}
proc glDisableVertexAttribArray*(index: GLuint) {.importc, header: GL_HEADER.}
proc glVertexAttribPointer*(
  index: GLuint, size: GLint, kind: GLenum, normalized: GLboolean, stride: GLsizei,
  offset: pointer
) {.importc, header: GL_HEADER.}
proc glActiveTexture*(texture: GLenum) {.importc, header: GL_HEADER.}
proc glGenVertexArrays*(count: GLsizei, arrays: ptr GLuint) {.importc, header: GL_HEADER.}
proc glBindVertexArray*(array_name: GLuint) {.importc, header: GL_HEADER.}
