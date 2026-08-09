"""The palette, and the one stroke width a connection is drawn at.

Colours come through custom properties with fallbacks: inside a page that
defines them the picture follows the page, light and dark themes included.
Each side has two shades of the one hue -- the plain one for the follow, the
deep one for the lead -- so a connection can say whose end is whose along its
own length without a second mark.
"""


QUIET = "var(--rule-strong)"

FAINT = "var(--faint)"

INK = {"L": "var(--left)", "R": "var(--right)"}

DEEP = {"L": "var(--left-deep)", "R": "var(--right-deep)"}

LINK_W = 3.4

CAP = LINK_W / 2          # a round cap reaches this far past the endpoint
