## Pin the algebra this workbench is built against and size every fixed reservation it makes.
##
## Everything here is a compile-time constant. A whole module specialises on each of them —
## the scene on its capacity, the meshes on their vertex budget — so none is a runtime option.

{.experimental: "strictFuncs".}

import ../../vendor/pga/pga



#[ Algebra ]#

# Assert the vendored algebra was configured for the metric and dimension this build assumes.
#   Both are the library's own compile-time defines, so a wrong build fails here rather than
#   drawing a plausible-looking scene out of a different algebra.
static:
  doAssert DIMENSIONS == 4,
    "RGA Workbench is a 4D rigid PGA testbed; compile with `--define:pga.dimensions:4` " &
    "(got " & $DIMENSIONS & ")."
  doAssert IS_RIGID,
    "RGA Workbench is a rigid (degenerate) PGA testbed; compile with " &
    "`--define:pga.is_conformal:false`."

const BASIS_COUNT* = ord(Basis.high) + 1
  ## Count basis elements of the configured algebra, i.e. 16 for 4D.



#[ Scene Capacity ]#

const
  ITEM_CAPACITY* {.intdefine: "rga.item_capacity".} = 64
    ## Cap objects a scene holds; slots are fixed, never moved, never grown.
  LABEL_CAPACITY* {.intdefine: "rga.label_capacity".} = 40
    ## Cap characters a label holds, counted in bytes of UTF-8.
  SELECTION_CAPACITY* = ITEM_CAPACITY
    ## Cap picked slots, which cannot exceed the objects there are to pick.
  HISTORY_CAPACITY* {.intdefine: "rga.history_capacity".} = 32
    ## Cap recorded scene snapshots; recording past it drops the oldest.

static:
  doAssert ITEM_CAPACITY > 0, "Scene capacity must be positive."
  doAssert LABEL_CAPACITY >= 8, "Labels must hold at least a derived operation name."



#[ Vertex Budgets ]#

const VERTEX_CAPACITY* {.intdefine: "rga.vertex_capacity".} = 16384
  ## Cap vertices per primitive kind, fixed and asserted rather than grown on demand.



#[ Animation ]#

const
  ANIMATION_DURATION_MS* = 350.0
    ## Time every eased motion in the tool takes, in milliseconds.
  ANIMATION_CURVE_CSS* = "cubic-bezier(0.215, 0.61, 0.355, 1)"
    ## Name the ease-out cubic curve in the browser's own notation, read across the boundary.
