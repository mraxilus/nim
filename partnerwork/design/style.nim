## Name the palette, and the one stroke width a connection is drawn at.
##
##   Colours come through custom properties with fallbacks: inside a page
##     that defines them the picture follows the page, light and dark themes
##     included.
##     Cost of custom properties: the bare SVG, opened alone, falls back to
##       nothing and draws in the browser's defaults.  Accepted -- these
##       pictures live on the two pages, nowhere else.
##   Each side has two shades of the one hue -- plain for the follow, deep
##     for the lead -- so a connection says whose end is whose along its own
##     length without a second mark (rule 9).

{.experimental: "strictFuncs".}

import ./rules


const
  QUIET* = "var(--rule-strong)"  ## The neutral stroke: rims, chevrons, rings.
  FAINT* = "var(--faint)"        ## Caption text.

const
  INK*: array[Arm, string] = ["var(--left)", "var(--right)"]
    ## The plain shade of each side's hue: the follow's.
  DEEP*: array[Arm, string] = ["var(--left-deep)", "var(--right-deep)"]
    ## The deep shade of each side's hue: the lead's.

const
  LINK_W* = 3.4          ## A connection's stroke width.
  CAP* = LINK_W / 2      ## How far a round cap reaches past an endpoint.
