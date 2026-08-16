## Name the palette, and the one stroke width a connection is drawn at.
##
##   Colours come through custom properties **with fallbacks**: inside a page
##     that defines them the picture follows the page, light and dark themes
##     included, and on its own it still draws in ink somebody chose.
##     The fallback used to be left off, on the grounds that these pictures
##       only ever appeared on the workbench's own pages.  They do not: the
##       app writes each frame out as a standalone file for `doc/frames/`, to
##       be shown on grounds this module cannot see, and `tests/treview`
##       holds every colour to naming a property *and* a fallback.
##     Cost of a fallback: on its own the picture is tuned to neither ground,
##       only readable on either.  Accepted -- a standalone file cannot know
##       the ground it will be shown on.
##   The values are the ones the workbench settled on and are repeated in
##     the two places that define the properties, `design/page.nim` and
##     `app/index.html`.  Repeated on purpose: a fallback is what a reader
##     gets when nothing defines them, so it cannot itself be a reference.
##   Each side has two shades of the one hue -- plain for the follow, deep
##     for the lead -- so a connection says whose end is whose along its own
##     length without a second mark (rule 9).

{.experimental: "strictFuncs".}

import ./terms


const
  QUIET* = "var(--rule-strong, #c2bbb0)"
    ## The neutral stroke: rims, chevrons, rings.
  FAINT* = "var(--faint, #948d85)"
    ## Caption text.

const
  INK*: array[Arm, string] = [
    "var(--left, #3d7fd0)", "var(--right, #d0763d)"]
    ## The plain shade of each side's hue: the follow's.
  DEEP*: array[Arm, string] = [
    "var(--left-deep, #133a72)", "var(--right-deep, #723a13)"]
    ## The deep shade of each side's hue: the lead's.

const
  LINK_W* = 3.4          ## A connection's stroke width.
  CAP* = LINK_W / 2      ## How far a round cap reaches past an endpoint.
