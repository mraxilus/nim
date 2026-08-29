## Collect the multivectors a frame actually computed, so they can be drawn.
##
## The picture a reader sees is no longer the algebra's own statement: a plane is drawn as
## a disc and a line as a ribbon, both stand-ins built out of ordinary arithmetic because
## neither is a geometric object (see `euclid.nim`'s header for the split). That is right
## for a picture and wrong for a reader trying to see what the library did, so the algebra
## gets its own layer to be seen in -- the same thing a game engine offers when it draws a
## physics world in wireframe over the art.
##
## What lands here is not only the scene. A frame computes geometry a reader never sees:
## the line joining eye to target, the plane the near clip really is, the ray a cursor casts
## and where it meets the level the camera works at. Each is a multivector, each is drawn by
## `algebra_view` in its true form -- and a plane drawn there is drawn *infinite*, since
## that is what a plane is.
##
## **Fixed capacity, cleared per frame, allocating nothing.** This is filled on every frame
## the layer is switched on, so a growing sequence would put the debug layer's own garbage
## into the frame times it exists to explain. A role rather than a label for the same
## reason: `$role` names an entry for a legend without building a string per frame.
##
## Shared between the desktop (`visualiser.nim`) and browser (`browser_bridge.nim`)
## render paths; see `visualiser.nim`'s own "Render Paths" table.

{.experimental: "strictFuncs".}

import ../../pga
import ./scene



#[ Trace Configuration ]#

const
  TRACED_MAX* = ITEMS_MAX + 16
    ## How many multivectors one frame may record. The scene's own items, plus the dozen
    ## or so a frame derives around them; a trace that filled would silently drop the
    ## derived ones, which are the whole reason this exists, so the headroom sits above
    ## the scene rather than inside it.



#[ Type Definitions ]#

type
  TracedRole* {.pure.} = enum ## Name what a recorded multivector is, and how to draw it.
    ## Doubles as the legend: `$role` is what the drawer shows beside the debug ink, so a
    ## reader can tell the camera's own near plane from a plane they built.
    SceneObject, ## An item the scene holds -- drawn in its true form, not its stand-in.
    Ghost, ## The staged edit or drag preview, uncommitted.
    EyePoint, ## Where the camera stands, as a unit-weight point.
    SightAxis, ## The line joining eye to target: `camera.frame`'s own first join.
    PlaneEye, ## The plane through the eye perpendicular to the sight; depth is measured
      ## against it, and its sign is "in front".
    PlaneNear, ## The same plane pushed forward to the near clip -- what the clip *is*,
      ## as the algebra states it rather than as a number in a matrix.
    GroundPlane, ## `objects.groundPlane`, the level everything is placed over.
    CursorRay, ## The sight ray the cursor casts into the world.
    CursorHit, ## Where that ray meets the level the camera is working at.

  Traced* = object ## One multivector a frame computed, and what it was.
    role*: TracedRole
    geometry*: Multivector

  AlgebraTrace* = object ## Everything one frame computed, in the order it was recorded.
    entries*: array[TRACED_MAX, Traced]
    count*: int ## How much of `entries` is meaningful; never past `TRACED_MAX`.



#[ Recording ]#

proc clear*(trace: var AlgebraTrace) =
  ## Forget the last frame's geometry.
  ##   Only the count is reset: the entries themselves are overwritten as they are
  ##   recorded, and clearing storage nobody will read costs a frame for nothing.
  trace.count = 0


proc record*(trace: var AlgebraTrace; role: TracedRole; geometry: Multivector) =
  ## Note one multivector this frame derived.
  ##   Silently drops anything past `TRACED_MAX` rather than failing: a debug layer that
  ##   crashed the frame it is meant to explain would be worse than one that shows a
  ##   little less of an over-full scene.
  if trace.count >= TRACED_MAX: return
  trace.entries[trace.count] = Traced(role: role, geometry: geometry)
  trace.count += 1


iterator items*(trace: AlgebraTrace): Traced =
  ## Walk what was recorded, in order.
  for i in 0 ..< trace.count: yield trace.entries[i]
