## Draw the desktop panel, immediate-mode, over the 3D scene.
##
## Immediate mode with no retained widget tree: each frame re-issues every control, and the
## only state carried between frames is which control the pointer is over, which one is being
## pressed, and which text field has the keyboard. That state is keyed by an identifier the
## caller supplies, so a control keeps its identity across frames without owning an object.
##
## Two rules the browser's own styling makes easy and a panel drawn straight onto the scene
## does not:
##
## - **An unselected segmented-toggle option is filled and bordered, not transparent.** The
##   browser's pill has a track to sit in; here a transparent segment disappears into the
##   scene entirely and the word reads as a caption rather than an option.
## - **Names recede and values read**: a control's own name draws in the faint ink, and a
##   section header carries the raised-surface tone rather than a saturated accent — five
##   accent bars stacked were the loudest thing in a panel whose job is to sit over the scene
##   without burying it.
##
## Nothing here holds a domain rule: every label, colour, number and list comes from the core.

{.experimental: "strictFuncs".}

import std/[math, tables, unicode]

import ../core/[format, palette]
import ./[font, renderer]



#[ Type Definitions ]#

type
  Panel* = object
    ## Hold the panel's layout cursor and the little state immediate mode still needs.
    x*, y*: float
    width*: float
    line_height*: float
    hot*: int
    active*: int
    focused*: int
    editing*: string
    open_sections*: Table[string, bool]
    pointer_x*, pointer_y*: float
    is_pointer_down*: bool
    was_pointer_down*: bool
    typed*: seq[Rune]
    is_backspace*, is_enter*, is_escape*: bool
    same_line_x*: float
    alpha*: float

  Tone* = object
    ## Name the panel's surfaces, borrowed from the browser's token set.
    surface*, surface_raised*, border*, ink*, ink_muted*, ink_faint*, accent*, danger*: Color



#[ Constants ]#

const
  PANEL_WIDTH* = 440.0
    ## Size the panel, close to the browser drawer's 400.
    ##   Nothing inside carries a hardcoded width: every field, plot and bar sizes itself from
    ##   the content width this leaves.
  PANEL_MARGIN* = 12.0
    ## Inset the panel from the window edge.
  PADDING* = 8.0
    ## Space controls from their surfaces.
  ROW_GAP* = 4.0
    ## Space rows from each other.
  CONTROL_HEIGHT* = 24.0
    ## Size a button, a field or a toggle.

func tones*(): Tone =
  ## Read the panel's surfaces, the same tokens the browser's stylesheet names.
  Tone(
    surface: Color(r: 0.086, g: 0.106, b: 0.133, a: 0.82),
    surface_raised: Color(r: 0.106, g: 0.129, b: 0.169, a: 0.95),
    border: Color(r: 0.165, g: 0.196, b: 0.239, a: 1.0),
    ink: Color(r: 0.906, g: 0.925, b: 0.945, a: 1.0),
    ink_muted: Color(r: 0.545, g: 0.588, b: 0.639, a: 1.0),
    ink_faint: Color(r: 0.357, g: 0.400, b: 0.451, a: 1.0),
    accent: Color(r: 0.0, g: 0.655, b: 0.647, a: 1.0),
    danger: Color(r: 0.878, g: 0.341, b: 0.478, a: 1.0),
  )



#[ Frame ]#

proc begin*(panel: var Panel, draw: var Renderer, height: float) =
  ## Start the panel: place it, draw its surface, and reset the layout cursor.
  panel.width = PANEL_WIDTH
  panel.x = PANEL_MARGIN
  panel.y = PANEL_MARGIN
  panel.alpha = 1.0
  panel.line_height = max(draw.atlas.line_height, TEXT_SIZE)
  panel.hot = 0
  draw.quad(
    PANEL_MARGIN - PADDING, PANEL_MARGIN - PADDING,
    PANEL_WIDTH + PADDING*2, height - (PANEL_MARGIN - PADDING)*2,
    tones().surface,
  )


proc finish*(panel: var Panel) =
  ## End the panel: forget this frame's typing and remember the pointer's state.
  panel.was_pointer_down = panel.is_pointer_down
  panel.typed.setLen(0)
  panel.is_backspace = false
  panel.is_enter = false
  panel.is_escape = false


func contentWidth*(panel: Panel): float {.inline.} = panel.width
  ## Read the width a control has to size itself from.


proc newLine*(panel: var Panel, height: float) =
  ## Advance the layout cursor past a row.
  panel.y += height + ROW_GAP
  panel.same_line_x = 0.0


proc sameLine*(panel: var Panel, x: float) =
  ## Place the next control on the current row, at an offset.
  panel.same_line_x = x



#[ Interaction ]#

func isOver(panel: Panel, x, y, width, height: float): bool {.inline.} =
  ## Report whether the pointer is over a rectangle.
  panel.pointer_x >= x and panel.pointer_x <= x + width and
    panel.pointer_y >= y and panel.pointer_y <= y + height


proc pressed(panel: var Panel, id: int, x, y, width, height: float): bool =
  ## Report whether a control was clicked this frame, and track hot and active.
  let over = panel.isOver(x, y, width, height)
  if over: panel.hot = id
  if over and panel.is_pointer_down and not panel.was_pointer_down:
    panel.active = id
  if not panel.is_pointer_down and panel.was_pointer_down and panel.active == id:
    panel.active = 0
    return over
  false


func isBusy*(panel: Panel): bool {.inline.} = panel.hot != 0 or panel.active != 0
  ## Report whether the pointer is over the panel, so the scene ignores it.



#[ Controls ]#

proc label*(
  panel: var Panel, draw: var Renderer, text: string, is_faint = false,
  family = Family.Text,
) =
  ## Draw one line of text: a name recedes, a value reads.
  let color = if is_faint: tones().ink_muted else: tones().ink
  discard draw.text(
    panel.x + panel.same_line_x, panel.y, text, color.withAlpha(panel.alpha), family
  )
  panel.newLine(panel.line_height)


proc button*(
  panel: var Panel, draw: var Renderer, id: int, text: string,
  width = 0.0, is_enabled = true,
): bool =
  ## Draw a momentary control, and report whether it was pressed.
  let
    tone = tones()
    measured = draw.atlas.width(text) + PADDING*2
    box_width = if width > 0: width else: measured
    x = panel.x + panel.same_line_x
    y = panel.y
  let is_hot = panel.isOver(x, y, box_width, CONTROL_HEIGHT) and is_enabled
  draw.quad(
    x, y, box_width, CONTROL_HEIGHT,
    (if is_hot: tone.surface_raised else: tone.surface).withAlpha(panel.alpha),
  )
  draw.strokeRect(x, y, box_width, CONTROL_HEIGHT, 1.0, tone.border.withAlpha(panel.alpha))
  let ink = (if is_enabled: tone.ink else: tone.ink_faint).withAlpha(panel.alpha)
  discard draw.text(
    x + (box_width - draw.atlas.width(text))*0.5, y + (CONTROL_HEIGHT - panel.line_height)*0.5,
    text, ink,
  )
  if not is_enabled:
    discard panel.pressed(id, x, y, box_width, CONTROL_HEIGHT)
    return false
  panel.pressed(id, x, y, box_width, CONTROL_HEIGHT)


proc checkbox*(
  panel: var Panel, draw: var Renderer, id: int, is_checked: bool
): bool =
  ## Draw a checkbox, and report whether it was toggled.
  let
    tone = tones()
    size = 16.0
    x = panel.x + panel.same_line_x
    y = panel.y + (CONTROL_HEIGHT - size)*0.5
  draw.quad(x, y, size, size, tone.surface.withAlpha(panel.alpha))
  draw.strokeRect(x, y, size, size, 1.0, tone.border.withAlpha(panel.alpha))
  if is_checked:
    draw.quad(x + 4, y + 4, size - 8, size - 8, tone.accent.withAlpha(panel.alpha))
  panel.pressed(id, x, y, size, size)


proc segmented*(
  panel: var Panel, draw: var Renderer, id: int, options: openArray[string], chosen: int
): int =
  ## Draw a segmented toggle, and report which option is chosen after this frame.
  ##   An unselected segment is filled and bordered rather than transparent: there is no track
  ##   behind this panel, and a transparent segment vanishes into the scene.
  result = chosen
  let
    tone = tones()
    segment_width = panel.contentWidth/options.len.float
  for index, option in options:
    let
      x = panel.x + segment_width*index.float
      y = panel.y
      is_chosen = index == chosen
    draw.quad(
      x, y, segment_width - 2.0, CONTROL_HEIGHT,
      (if is_chosen: tone.surface_raised else: tone.surface).withAlpha(panel.alpha),
    )
    draw.strokeRect(
      x, y, segment_width - 2.0, CONTROL_HEIGHT, 1.0, tone.border.withAlpha(panel.alpha)
    )
    discard draw.text(
      x + (segment_width - draw.atlas.width(option))*0.5,
      y + (CONTROL_HEIGHT - panel.line_height)*0.5,
      option,
      (if is_chosen: tone.accent else: tone.ink_muted).withAlpha(panel.alpha),
    )
    if panel.pressed(id + index, x, y, segment_width, CONTROL_HEIGHT): result = index
  panel.newLine(CONTROL_HEIGHT)


proc field*(
  panel: var Panel, draw: var Renderer, id: int, value: string, width = 0.0
): (string, bool) =
  ## Draw an editable text field, and report its text and whether editing finished.
  ##   The field shows the caller's value until it takes focus, then its own buffer, so a
  ##   number being retyped is not reformatted underneath the typist.
  let
    tone = tones()
    box_width = if width > 0: width else: panel.contentWidth
    x = panel.x + panel.same_line_x
    y = panel.y
    is_focused = panel.focused == id
  var text = if is_focused: panel.editing else: value
  var is_committed = false

  if is_focused:
    for rune in panel.typed:
      text.add($rune)
    if panel.is_backspace and text.len > 0:
      # Step back a whole character: this UI's own text is full of multi-byte operators.
      var cut = text.len - 1
      while cut > 0 and (uint8(text[cut]) and 0xC0'u8) == 0x80'u8: cut -= 1
      text.setLen(cut)
    panel.editing = text
    if panel.is_enter or panel.is_escape:
      panel.focused = 0
      is_committed = panel.is_enter

  draw.quad(x, y, box_width, CONTROL_HEIGHT, tone.surface.withAlpha(panel.alpha))
  draw.strokeRect(
    x, y, box_width, CONTROL_HEIGHT, 1.0,
    (if is_focused: tone.accent else: tone.border).withAlpha(panel.alpha),
  )
  discard draw.text(
    x + PADDING*0.5, y + (CONTROL_HEIGHT - panel.line_height)*0.5, text,
    tone.ink.withAlpha(panel.alpha), Family.Mono,
  )
  if panel.pressed(id, x, y, box_width, CONTROL_HEIGHT):
    panel.focused = id
    panel.editing = value
  # Clicking away commits, as every immediate-mode field must or a value is lost silently.
  elif is_focused and panel.is_pointer_down and not panel.was_pointer_down and
      not panel.isOver(x, y, box_width, CONTROL_HEIGHT):
    panel.focused = 0
    is_committed = true
  (text, is_committed)


proc section*(
  panel: var Panel, draw: var Renderer, id: int, name: string
): bool =
  ## Draw a collapsing section header, and report whether its body should draw.
  ##   Only `objects` opens by default, as in the browser's drawer. A build defining
  ##   `rgaOpenAllSections` opens every one, which is how a headless render looks at the
  ##   sections a pointer would otherwise have to open.
  let tone = tones()
  if not panel.open_sections.hasKey(name):
    panel.open_sections[name] = name == "objects" or defined(rgaOpenAllSections)
  let
    x = panel.x
    y = panel.y
    is_open = panel.open_sections[name]
  draw.quad(x, y, panel.contentWidth, CONTROL_HEIGHT, tone.surface_raised)
  draw.strokeRect(x, y, panel.contentWidth, CONTROL_HEIGHT, 1.0, tone.border)
  discard draw.text(
    x + PADDING, y + (CONTROL_HEIGHT - panel.line_height)*0.5,
    (if is_open: "− " else: "+ ") & name, tone.ink,
  )
  if panel.pressed(id, x, y, panel.contentWidth, CONTROL_HEIGHT):
    panel.open_sections[name] = not is_open
  panel.newLine(CONTROL_HEIGHT)
  panel.open_sections[name]


proc graph*(
  panel: var Panel, draw: var Renderer, samples: openArray[float], count: int, peak: float
) =
  ## Plot a raw, unsmoothed reading across the content width.
  ##   Smoothing hides exactly the rare slow frame this graph exists for.
  let
    tone = tones()
    width = panel.contentWidth
    height = 54.0
    x = panel.x
    y = panel.y
  draw.quad(x, y, width, height, tone.surface)
  draw.strokeRect(x, y, width, height, 1.0, tone.border)
  if count > 1 and peak > 0:
    for index in 0 ..< count - 1:
      let
        x0 = x + width*index.float/(count - 1).float
        x1 = x + width*(index + 1).float/(count - 1).float
        y0 = y + height - height*min(samples[index]/peak, 1.0)
        y1 = y + height - height*min(samples[index + 1]/peak, 1.0)
      # Draw the step as a thin segment rather than as a filled rectangle: a rectangle between
      #   two samples fills everything under a spike, and a graph of spikes reads as a block.
      draw.segment(x0, y0, x1, y1, 1.5, tone.accent)
  panel.newLine(height)


proc bar*(panel: var Panel, draw: var Renderer, fraction: float, reading: string) =
  ## Draw a fill bar across the content width, with its reading beside it.
  let
    tone = tones()
    width = panel.contentWidth
    height = 14.0
    x = panel.x
    y = panel.y
  draw.quad(x, y, width, height, tone.surface)
  draw.quad(x, y, width*clamp(fraction, 0.0, 1.0), height, tone.accent.withAlpha(0.7))
  draw.strokeRect(x, y, width, height, 1.0, tone.border)
  # Read the bar under it rather than over it: white ink over the accent fill is unreadable
  #   exactly where the bar is full, which is when the reading matters most.
  discard draw.text(x, y + height + 1.0, reading, tone.ink_muted, Family.Mono)
  panel.newLine(height + panel.line_height)


proc strip*(panel: var Panel, draw: var Renderer, colors: openArray[float], slots: int) =
  ## Draw one cell per pool slot, in the scene's own colours.
  ##   The strip arrives as one buffer of colour triples, so no palette rule lives here.
  let
    width = panel.contentWidth
    height = 12.0
    cell = width/slots.float
  for index in 0 ..< slots:
    draw.quad(
      panel.x + cell*index.float, panel.y, max(cell - 1.0, 1.0), height,
      Color(r: colors[index*3], g: colors[index*3 + 1], b: colors[index*3 + 2], a: 1.0),
    )
  panel.newLine(height)


proc swatch*(panel: var Panel, draw: var Renderer, color: Color) =
  ## Draw a small colour cell, for an object's row.
  let size = 12.0
  draw.quad(
    panel.x + panel.same_line_x, panel.y + (CONTROL_HEIGHT - size)*0.5, size, size,
    color.withAlpha(panel.alpha),
  )


proc rightAligned*(panel: Panel, draw: Renderer, widths: openArray[float]): float =
  ## Measure where a run of controls must start to end flush against the right edge.
  ##   Measured before any of the run is placed: names vary in length, so left-packed buttons
  ##   form a ragged column that moves under the pointer from row to row.
  var total = 0.0
  for width in widths: total += width + ROW_GAP
  panel.contentWidth - total + ROW_GAP


proc measureButton*(draw: Renderer, text: string): float {.inline.} =
  ## Measure how wide a button will be, before placing it.
  draw.atlas.width(text) + PADDING*2
