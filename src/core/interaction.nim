## Name every gesture rule both front-ends obey.
##
## The button→operation mapping is one rule, called by both: they number their buttons
## differently, and that translation is the only part either front-end may hold.

{.experimental: "strictFuncs".}

import ./catalogue



#[ Type Definitions ]#

type PointerButton* {.pure.} = enum
  ## Name the buttons a drag can be made with, in the tool's own terms.
  Left,   ## Join.
  Right,  ## Meet.
  Middle, ## Orthogonal projection.



#[ Gesture Constants ]#

const
  CLICK_DURATION_MS* = 350.0
    ## Treat a press shorter than this, and barely moved, as a click rather than a drag.
  CLICK_MOVEMENT_PX* = 6.0
    ## Allow a click this much movement before it becomes a drag.
  LONG_PRESS_MS* = 500.0
    ## Select an object under a touch held this long.
  TAP_DURATION_MS* = 350.0
    ## Treat a touch shorter than this as a tap.
  TAP_MOVEMENT_PX* = 12.0
    ## Allow a tap this much movement, a fingertip's own wobble.



#[ Gesture Rules ]#

func operationFor*(button: PointerButton): Operation =
  ## Name the operation a drag with this button derives.
  case button
  of PointerButton.Left: Operation.Wedge
  of PointerButton.Right: Operation.Antiwedge
  of PointerButton.Middle: Operation.ProjectOrthogonal


func isClick*(duration_ms, movement_px: float): bool {.inline.} =
  ## Report whether a press was a click rather than a drag.
  duration_ms < CLICK_DURATION_MS and movement_px < CLICK_MOVEMENT_PX


func isTap*(duration_ms, movement_px: float): bool {.inline.} =
  ## Report whether a touch was a tap rather than a drag or a long press.
  duration_ms < TAP_DURATION_MS and movement_px < TAP_MOVEMENT_PX
