## Bind subset of OpenGL 3.3 core that visualiser uses.
##
## Driver is depended on rather than derived, for same reason as windowing: it is external.
##   Only entry points actually called are declared, so binding stays readable in one sitting.
##   Declarations import through header, so C compiler resolves every prototype and enum.
##
## Prototypes come from `GL_GLEXT_PROTOTYPES`, which links entry points directly.
##   Holds on Linux, where libGL exports every core symbol.
##   TODO: Elsewhere, entry points must be fetched one at a time through
##           `SDL_GL_GetProcAddress`, which would turn each declaration below into
##           a loaded function pointer. Deferred until visualiser needs to leave Linux;
##           doing it early would cost a loader nobody has asked to read yet.
##
## Enumerants are written as literals rather than imported, since their values are fixed
## by OpenGL specification and never renumbered.
##
## Desktop-only; unreachable from the browser build. See `visualiser.nim`'s own "Render
## Paths" table.

{.experimental: "strictFuncs".}



#[ Binding Configuration ]#

const HEADER = "<GL/gl.h>"
  ## Name header every declaration below imports through.

# Ask header for prototypes above OpenGL 1.1, and link the loader, here rather than in a
# project config, so every binary importing this module builds without extra flags.
{.passC: "-DGL_GLEXT_PROTOTYPES".}
{.passL: "-lGL".}



#[ Type Definitions ]#

type
  Bitfield* = uint32 ## Mirror `GLbitfield`.
  Boolean* = uint8 ## Mirror `GLboolean`.
  Char* = char ## Mirror `GLchar`.
  Enum* = uint32 ## Mirror `GLenum`.
  Float* = float32 ## Mirror `GLfloat`.
  Int* = int32 ## Mirror `GLint`.
  Sizei* = int32 ## Mirror `GLsizei`.
  Sizeiptr* = int ## Mirror `GLsizeiptr`.
  Uint* = uint32 ## Mirror `GLuint`.


const
  COLOR_BUFFER_BIT* = 0x00004000'u32
  DEPTH_BUFFER_BIT* = 0x00000100'u32
  DEPTH_TEST* = 0x0B71'u32
  BLEND* = 0x0BE2'u32
  MULTISAMPLE* = 0x809D'u32
  PROGRAM_POINT_SIZE* = 0x8642'u32
  SRC_ALPHA* = 0x0302'u32
  ONE_MINUS_SRC_ALPHA* = 0x0303'u32
  LESS* = 0x0201'u32
  ARRAY_BUFFER* = 0x8892'u32
  DYNAMIC_DRAW* = 0x88E8'u32
  FLOAT_TYPE* = 0x1406'u32
  UNSIGNED_BYTE* = 0x1401'u32
  RGB* = 0x1907'u32
  PACK_ALIGNMENT* = 0x0D05'u32
  TRIANGLES* = 0x0004'u32
  LINES* = 0x0001'u32
  POINTS* = 0x0000'u32
  VERTEX_SHADER* = 0x8B31'u32
  FRAGMENT_SHADER* = 0x8B30'u32
  COMPILE_STATUS* = 0x8B81'u32
  LINK_STATUS* = 0x8B82'u32
  VERSION* = 0x1F02'u32
  FALSE* = 0'u8
  TRUE* = 1'u8



#[ Foreign Declarations ]#

# Mechanical one-to-one imports of OpenGL entry points; see OpenGL reference for each.
proc clearColor*(red, green, blue, alpha: Float) {.importc: "glClearColor", header: HEADER.}
proc clear*(mask: Bitfield) {.importc: "glClear", header: HEADER.}
proc viewport*(x, y: Int; width, height: Sizei) {.importc: "glViewport", header: HEADER.}
proc enable*(capability: Enum) {.importc: "glEnable", header: HEADER.}
proc disable*(capability: Enum) {.importc: "glDisable", header: HEADER.}
proc blendFunc*(source, destination: Enum) {.importc: "glBlendFunc", header: HEADER.}
proc depthFunc*(function: Enum) {.importc: "glDepthFunc", header: HEADER.}
proc depthMask*(flag: Boolean) {.importc: "glDepthMask", header: HEADER.}
proc lineWidth*(width: Float) {.importc: "glLineWidth", header: HEADER.}
proc getString*(name: Enum): cstring {.importc: "glGetString", header: HEADER.}
proc pixelStorei*(name: Enum; parameter: Int) {.importc: "glPixelStorei", header: HEADER.}
proc readPixels*(
  x, y: Int; width, height: Sizei; format, kind: Enum; pixels: pointer
) {.importc: "glReadPixels", header: HEADER.}

proc genVertexArrays*(count: Sizei; arrays: ptr Uint)
  {.importc: "glGenVertexArrays", header: HEADER.}
proc bindVertexArray*(array_object: Uint) {.importc: "glBindVertexArray", header: HEADER.}
proc genBuffers*(count: Sizei; buffers: ptr Uint) {.importc: "glGenBuffers", header: HEADER.}
proc bindBuffer*(target: Enum; buffer: Uint) {.importc: "glBindBuffer", header: HEADER.}
proc bufferData*(target: Enum; size: Sizeiptr; data: pointer; usage: Enum)
  {.importc: "glBufferData", header: HEADER.}
proc vertexAttribPointer*(
  index: Uint; size: Int; kind: Enum; normalized: Boolean; stride: Sizei; offset: pointer
) {.importc: "glVertexAttribPointer", header: HEADER.}
proc enableVertexAttribArray*(index: Uint)
  {.importc: "glEnableVertexAttribArray", header: HEADER.}
proc drawArrays*(mode: Enum; first: Int; count: Sizei)
  {.importc: "glDrawArrays", header: HEADER.}

proc createShader*(kind: Enum): Uint {.importc: "glCreateShader", header: HEADER.}
proc shaderSource*(shader: Uint; count: Sizei; sources: ptr cstring; lengths: ptr Int)
  {.importc: "glShaderSource", header: HEADER.}
proc compileShader*(shader: Uint) {.importc: "glCompileShader", header: HEADER.}
proc getShaderiv*(shader: Uint; name: Enum; parameters: ptr Int)
  {.importc: "glGetShaderiv", header: HEADER.}
proc getShaderInfoLog*(shader: Uint; capacity: Sizei; length: ptr Sizei; log: ptr Char)
  {.importc: "glGetShaderInfoLog", header: HEADER.}
proc deleteShader*(shader: Uint) {.importc: "glDeleteShader", header: HEADER.}

proc createProgram*(): Uint {.importc: "glCreateProgram", header: HEADER.}
proc attachShader*(program, shader: Uint) {.importc: "glAttachShader", header: HEADER.}
proc linkProgram*(program: Uint) {.importc: "glLinkProgram", header: HEADER.}
proc getProgramiv*(program: Uint; name: Enum; parameters: ptr Int)
  {.importc: "glGetProgramiv", header: HEADER.}
proc getProgramInfoLog*(program: Uint; capacity: Sizei; length: ptr Sizei; log: ptr Char)
  {.importc: "glGetProgramInfoLog", header: HEADER.}
proc useProgram*(program: Uint) {.importc: "glUseProgram", header: HEADER.}
proc getUniformLocation*(program: Uint; name: cstring): Int
  {.importc: "glGetUniformLocation", header: HEADER.}
proc uniformMatrix4fv*(location: Int; count: Sizei; transpose: Boolean; value: ptr Float)
  {.importc: "glUniformMatrix4fv", header: HEADER.}
proc uniform1f*(location: Int; value: Float) {.importc: "glUniform1f", header: HEADER.}
proc uniform1i*(location: Int; value: Int) {.importc: "glUniform1i", header: HEADER.}
proc uniform3f*(location: Int; x, y, z: Float) {.importc: "glUniform3f", header: HEADER.}
