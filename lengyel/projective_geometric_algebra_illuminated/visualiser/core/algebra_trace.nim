## Collect multivectors frame computed, so debug layer can draw them.
##
## Ordinary picture draws stand-ins built from plain arithmetic: disc for plane, ribbon for
## line (see `euclid.nim` header).
##   Right for picture, wrong for reader trying to see what library did.
##   Algebra gets own layer, as game engine draws physics world in wireframe over art.
## Frame also computes geometry reader never sees: line joining eye to target, plane near
## clip really is, ray cursor casts and where it meets camera's level.
##   Each is multivector; `algebra_view` draws each in true form, plane *infinite*.
## Fixed capacity, cleared per frame, allocating nothing.
##   Filled every frame layer is on; growing sequence would put layer's own garbage into
##   frame times it explains.
##   Role rather than label, so `$role` names entry without building string per frame.
##
## Shared by desktop (`visualiser.nim`) and browser (`browser_bridge.nim`) render paths.

{.experimental: "strictFuncs".}

import ../../pga
import ./scene



#[ Trace Configuration ]#

const
  TRACED_MAX* = ITEMS_MAX + 16
    ## Limit how many multivectors one frame may record.
    ##   Scene's items plus dozen or so derived around them.
    ##   Full trace silently drops derived ones, whole reason layer exists, so headroom
    ##   sits above scene.



#[ Type Definitions ]#

type
  TracedRole* {.pure.} = enum ## Define what recorded multivector is, and how to draw it.
    ## Doubles as legend: `$role` is shown beside debug ink.
    SceneObject, ## Item scene holds, in true form.
    Ghost, ## Staged edit or drag preview, uncommitted.
    EyePoint, ## Where camera stands, as unit-weight point.
    SightAxis, ## Line joining eye to target: `camera.frame`'s first join.
    PlaneEye, ## Plane through eye perpendicular to sight; depth is measured against it.
    PlaneNear, ## Same plane pushed to near clip: what clip *is*, as algebra states it.
    GroundPlane, ## `objects.groundPlane`, level everything is placed over.
    CursorRay, ## Sight ray cursor casts into world.
    CursorHit, ## Where that ray meets level camera works at.

  Traced* = object ## Define one multivector frame computed, and what it was.
    role*: TracedRole
    geometry*: Multivector

  AlgebraTrace* = object ## Define everything one frame computed, in recording order.
    entries*: array[TRACED_MAX, Traced]
    count*: int ## Meaningful prefix of `entries`; never past `TRACED_MAX`.



#[ Recording ]#

proc clear*(trace: var AlgebraTrace) =
  ## Clear last frame's geometry.
  ##   Count alone resets; entries are overwritten as recorded.
  trace.count = 0


proc record*(trace: var AlgebraTrace; role: TracedRole; geometry: Multivector) =
  ## Record one multivector this frame derived.
  ##   Silently drops anything past `TRACED_MAX`.
  ##     Debug layer crashing frame it explains would be worse than showing less.
  if trace.count >= TRACED_MAX: return
  trace.entries[trace.count] = Traced(role: role, geometry: geometry)
  trace.count += 1


iterator items*(trace: AlgebraTrace): Traced =
  ## Walk what was recorded, in order.
  for i in 0 ..< trace.count: yield trace.entries[i]
