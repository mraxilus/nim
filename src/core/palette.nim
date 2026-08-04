## Hold every colour the tool draws with, structural first and assignable last.
##
## The order of `Paint` is written to scene files as an ordinal, so no entry may be removed or
## reordered once a scene has been saved: shifting them silently recolours saved work. New
## entries append, and a structural one appended after the last hue fails the build below.
##
## The five assignable hues were chosen against a colour-vision validator, not by eye. What
## they satisfy, and why there are five rather than eight, is recorded in `PROVENANCE.md`
## beside the measurements.

{.experimental: "strictFuncs".}

import std/math



#[ Type Definitions ]#

type
  Paint* {.pure.} = enum
    ## Name every colour slot, structural first, categorical last as one contiguous block.
    Backdrop, ## Framebuffer clear.
    AxisX,    ## World x axis.
    AxisY,    ## World y axis.
    AxisZ,    ## World z axis.
    Grid,     ## Ground reference grid.
    Guide,    ## Construction helper, plane normal, edit ghost.
    Outline,  ## Selection ring.
    Invalid,  ## Reserved: an object that is wrong. Nothing draws in it.
    Rose,     ## Assignable.
    Copper,   ## Assignable.
    Olive,    ## Assignable.
    Jade,     ## Assignable.
    Cobalt,   ## Assignable.

  Color* = object
    ## Carry a linear colour with coverage.
    r*, g*, b*, a*: float



#[ Palette ]#

const LUT_PAINT_TO_COLOR: array[Paint, Color] = [
  ## Hold the measured colour of every slot.
  ##   Axis rows already carry their permanent 22% blend toward their own luminance: it is
  ##   baked here rather than computed, so a bright RGB trio never competes with an object.
  Paint.Backdrop: Color(r: 0.063, g: 0.075, b: 0.102, a: 1.0),
  Paint.AxisX:    Color(r: 0.757, g: 0.279, b: 0.279, a: 1.0),
  Paint.AxisY:    Color(r: 0.360, g: 0.736, b: 0.360, a: 1.0),
  Paint.AxisZ:    Color(r: 0.338, g: 0.481, b: 0.830, a: 1.0),
  Paint.Grid:     Color(r: 0.180, g: 0.204, b: 0.259, a: 1.0),
  Paint.Guide:    Color(r: 0.286, g: 0.322, b: 0.400, a: 1.0),
  Paint.Outline:  Color(r: 1.000, g: 1.000, b: 1.000, a: 1.0),
  Paint.Invalid:  Color(r: 0.612, g: 0.000, b: 0.722, a: 1.0),
  Paint.Rose:     Color(r: 0.690, g: 0.090, b: 0.373, a: 1.0),
  Paint.Copper:   Color(r: 0.812, g: 0.451, b: 0.275, a: 1.0),
  Paint.Olive:    Color(r: 0.341, g: 0.431, b: 0.000, a: 1.0),
  Paint.Jade:     Color(r: 0.133, g: 0.655, b: 0.478, a: 1.0),
  Paint.Cobalt:   Color(r: 0.357, g: 0.565, b: 0.780, a: 1.0),
]

const
  CATEGORICAL_FIRST* = Paint.Rose
    ## Name the boundary between structural and assignable slots, once.
  CATEGORICAL_COUNT* = 5
    ## Count assignable hues, the number both pickers and the cycler are derived from.

# Assert the categorical block really is the tail of the enumeration, so appending a
#   structural slot after the last hue fails the build rather than leaking into a picker.
static:
  doAssert ord(Paint.high) - ord(CATEGORICAL_FIRST) + 1 == CATEGORICAL_COUNT,
    "Categorical slots must be the last " & $CATEGORICAL_COUNT & " entries of `Paint`; " &
    "append new structural slots before `" & $CATEGORICAL_FIRST & "`."



#[ Palette Queries ]#

func color*(p: Paint): Color {.inline.} = LUT_PAINT_TO_COLOR[p]
  ## Read the colour of a slot.


func isAssignable*(p: Paint): bool {.inline.} = ord(p) >= ord(CATEGORICAL_FIRST)
  ## Report whether a slot may be worn by an object.
  ##   Structural slots never are: an object wearing the backdrop, an axis or the selection
  ##   outline is invisible or reads as something else.


func categorical*(index: int): Paint {.inline.} =
  ## Pick an assignable hue by position, cycling the categorical run.
  Paint(ord(CATEGORICAL_FIRST) + (index mod CATEGORICAL_COUNT))


iterator assignable*(): Paint =
  ## Walk the assignable hues in declaration order, for a picker.
  for i in 0 ..< CATEGORICAL_COUNT:
    yield categorical(i)



#[ Colour Derivation ]#

func luminance*(c: Color): float {.inline.} = 0.2126*c.r + 0.7152*c.g + 0.0722*c.b
  ## Measure perceived brightness, in the Rec. 709 weights.


func blendToLuminance*(c: Color, amount: float): Color =
  ## Blend colour toward its own grey, keeping its alpha.
  let grey = c.luminance
  Color(
    r: c.r + (grey - c.r)*amount,
    g: c.g + (grey - c.g)*amount,
    b: c.b + (grey - c.b)*amount,
    a: c.a,
  )


const
  MUTE_BLEND* = 0.6
    ## Blend a muted colour this far toward its own luminance.
  MUTE_ALPHA* = 0.55
    ## Drop a muted colour to this coverage.


func muted*(c: Color): Color =
  ## Mute colour for a hidden, out-of-focus or ghosted object.
  ##   Blends toward its own luminance rather than toward the grid colour, which made muted
  ##   objects indistinguishable from the ground.
  result = c.blendToLuminance(MUTE_BLEND)
  result.a = MUTE_ALPHA


func muted*(p: Paint): Color {.inline.} = p.color.muted
  ## Mute the colour of a slot.


func withAlpha*(c: Color, alpha: float): Color =
  ## Rebuild colour at a given coverage.
  Color(r: c.r, g: c.g, b: c.b, a: alpha)


func toHex*(c: Color): string =
  ## Write colour as a CSS hex triple, for the browser's own styling.
  const DIGITS = "0123456789abcdef"
  result = "#"
  for channel in [c.r, c.g, c.b]:
    let byte_value = clamp((channel*255.0).round.int, 0, 255)
    result.add(DIGITS[byte_value shr 4])
    result.add(DIGITS[byte_value and 0x0F])
