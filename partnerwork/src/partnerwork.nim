## Model the frames a couple can hold in partner dance and the moves between them.
##
## The ontology has one state, the `Frame`, and one relation, the primitive
## transition between two frames.
##   Everything else is derived from those: the names, the routes, the audit of
##     the workbook the model came from, and the unfinished rotation axis.
##
## The notation gate was evaluated and closed: partner dance has no canonical
## symbolic notation, so plain names are the only spelling used.
##
## The umbrella indexes and re-exports the model's modules rather than
## forwarding
## each symbol through a documented one-liner.
##   Cost of re-exporting instead of forwarding: per-symbol docs live at the
##     definitions, one hop away.  Accepted -- the index comments below name
##     the hop, and a forwarder layer would restate every signature to say it.
##
## Order of module bootstrapping, each stage importing only earlier ones:
##   [frame, motion]
##   frame -> [transition, rotation]
##   [frame, transition] -> workbook
##   draw/geometry -> draw/terms -> draw/style -> draw/[body, pose]
##   draw/[body, pose] -> draw/route -> draw/figure -> draw/scene
##   [draw/scene, frame, rotation] -> diagram
##   [diagram, draw/[style, terms], frame, motion, transition] -> map
##   [diagram, frame, map, motion, transition] -> spokes
##   [diagram, map, motion, rotation] -> axle
##   The draw/ chain is indexed by its own umbrella-less imports: it serves
##     the pages and the app directly and is not re-exported here.

{.experimental: "strictFuncs".}

## Draw the rotation axis as one line, with the couple's postures along it.
import ./partnerwork/axle
## Draw one frame from above, for every place that shows one.
import ./partnerwork/diagram
## The state: `Frame`, its laws, the enumeration `FRAMES`, and its names.
import ./partnerwork/frame
## Draw the whole ontology as one picture: frames as places, moves as ways.
import ./partnerwork/map
## Say when a drawing moves, so the picture and the page agree about it.
import ./partnerwork/motion
## Model the unfinished rotation axis: twist, capacity, wraps and locks.
import ./partnerwork/rotation
## Draw only where the couple are and where they can go next.
import ./partnerwork/spokes
## The relation: primitives, compounds, moves between frames, and routes.
import ./partnerwork/transition
## The `base` sheet held as data, and its audit against the derived model.
import ./partnerwork/workbook

## Re-export the whole surface, so one import serves a caller.
export axle, diagram, frame, map, motion, rotation, spokes, transition, workbook
