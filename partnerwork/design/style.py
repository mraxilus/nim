"""The palette, and the one stroke width a connection is drawn at.

Colours come through custom properties with fallbacks: inside a page that
defines them the picture follows the page, light and dark themes included.
"""


QUIET = "var(--rule-strong)"

FAINT = "var(--faint)"

BLOCK = "var(--block, #c0392b)"

INK = {"L": "var(--left)", "R": "var(--right)"}

LINK_W = 3.4

CAP = LINK_W / 2          # a round cap reaches this far past the endpoint
