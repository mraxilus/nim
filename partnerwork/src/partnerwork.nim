## Model the frames a couple can hold in partner dance and the moves between them.
##
## The ontology has one state, the `Frame`, and one relation, the primitive
## transition between two frames.  Everything else is derived from those: the
## names, the routes, the audit of the workbook the model came from, and the
## unfinished rotation axis.

{.experimental: "strictFuncs".}

import ./partnerwork/diagram
import ./partnerwork/frame
import ./partnerwork/map
import ./partnerwork/rotation
import ./partnerwork/transition
import ./partnerwork/workbook

export diagram, frame, map, rotation, transition, workbook
