"""One dancer: a circle, with a small chevron at its centre for the facing.

The boundary is one polar function, `outline_r`, shared by the drawing, the
hands and the routing -- so "on the border" is true by construction rather than
by two pieces of code agreeing.  It is drawn quiet and whole, broken only where
a hand mark sits on it, because how far an arm has been carried round is said
by the connection wrapping the body, not by a second arc filling up around it.
Hands sit on the rim, each in its own side's colour, the lead's a shade deeper
than the follow's.
"""
import math

from .geometry import n, polar, xy
from .style import CAP, DEEP, FAINT, INK, QUIET


BODY_R = 20               # a dancer, seen from above; their hands sit on it

RIM_W = 2.2               # one width for the whole boundary

CHEV_OUT = 7              # how far the centred chevron reaches forward
CHEV_BACK = 1             # and how little it reaches back
CHEV_HALF = 5             # half its width, well inside the rim

RIM_STEP = 3              # degrees between samples when a route walks the rim

ARM_REST = 90             # a hand at rest is a quarter of the rim from the front

R = 6                     # a hand

CAPTION_R = BODY_R + R + 2   # just past the hand it names

FREE = 0.5                # how far a hand nobody holds fades, keeping its hue

SLOT_OFFSET = 44          # how far round the rim `behind` sits from a side.
                          # Wide enough that a mark and the grey ghost of the
                          # place it left never touch, narrow enough that the
                          # spot still reads as belonging to its own side

SLOTS = ("default", "behind")

def slot_bearing(side, slot):
    """Where one of the four spots sits, as a bearing off the body's facing.

    Two sides, and on each of them the place where the arm hangs and one a
    little further round towards the back.  Off the *facing*, not off the page:
    turn a dancer and their spots turn with them.
    """
    base = -ARM_REST if side == "L" else ARM_REST
    back = -SLOT_OFFSET if side == "L" else SLOT_OFFSET
    return base + (back if slot == "behind" else 0.0)

# Where a hand settles.  `behind` carries both locks and wraps -- what tells
# them apart is which *side* the hand is behind, and what tells high from low
# is the fill the level already draws.  Nothing is invented to distinguish
# them.  A hold that names no level, or names one without saying whether it
# locks or wraps, leaves the hand where the arm hangs: there is no knowing.
SETTLE = {
    "lock": ("own", "behind"),
    "wrap": ("other", "behind"),
}

def slot_of(side, level=None, way=None):
    """The one of four spots this hand settles in: whose side, and how far
    round.  The level is not consulted -- it is a fill, not a place."""
    where, slot = (SETTLE[way] if level is not None and way in SETTLE
                   else ("own", "default"))
    return (side if where == "own" else other(side)), slot

def hand_bearing(facing, side, wind=0.0):
    return facing + (-1 if side == "L" else 1) * (ARM_REST + wind)

def settled_wind(side, level=None, way=None):
    """The winding that puts this hand in its slot.

    Winding is measured off the hand's own side and runs towards the back for
    either hand, so this is the one place the two conventions are reconciled.
    """
    aim = slot_bearing(*slot_of(side, level, way))
    return (-ARM_REST - aim) if side == "L" else (aim - ARM_REST)

def hand_point(centre, facing, side, wind=0.0):
    """Where one hand is: round the rim from the front, by however far the arm
    has carried it."""
    return polar(centre[0], centre[1], BODY_R,
                 hand_bearing(facing, side, wind))

HAND_GAP = math.degrees(math.asin((R + CAP) / BODY_R))
    # the rim's clearance around a hand mark: the same reach the connection
    # keeps, turned into arc, so the boundary and the reach stop at one border


def outline_r(delta):
    """How far the boundary is from the centre, at this bearing off the front.

    One function, used by the drawing and by anything that has to stay outside
    a body -- so `on the border` is true by construction instead of by two
    pieces of code agreeing.  A body is a plain circle now; the function stays
    because the routing reads the boundary through it.
    """
    return BODY_R

def outline_point(centre, facing, theta):
    return polar(centre[0], centre[1], outline_r(theta - facing), theta)

def rim(centre, facing, a, b, width=RIM_W):
    """One stretch of the boundary, drawn once and by one owner."""
    span = b - a
    start = outline_point(centre, facing, a)
    end = outline_point(centre, facing, b)
    large = 1 if abs(span) > 180 else 0
    sweep = 1 if span > 0 else 0
    d = f"M{xy(start)} A{BODY_R} {BODY_R} 0 {large} {sweep} {xy(end)}"
    return (f'<path d="{d}" fill="none" stroke="{QUIET}" stroke-width="{width}"'
            ' stroke-linecap="round" stroke-linejoin="round"/>')


def chevron(centre, facing):
    """The facing, said small and at the centre of the body.

    In the middle rather than on the rim, because the rim breaks for the hands
    and carries nothing else.  The centre is the one part of a dancer nothing
    else uses.
    """
    rad = math.radians(facing)
    fwd = (math.sin(rad), -math.cos(rad))
    across = (math.cos(rad), math.sin(rad))
    apex = (centre[0] + fwd[0] * CHEV_OUT, centre[1] + fwd[1] * CHEV_OUT)
    a = (centre[0] - fwd[0] * CHEV_BACK - across[0] * CHEV_HALF,
         centre[1] - fwd[1] * CHEV_BACK - across[1] * CHEV_HALF)
    b = (centre[0] - fwd[0] * CHEV_BACK + across[0] * CHEV_HALF,
         centre[1] - fwd[1] * CHEV_BACK + across[1] * CHEV_HALF)
    return (f'<polyline points="{n(a[0])},{n(a[1])} {n(apex[0])},{n(apex[1])}'
            f' {n(b[0])},{n(b[1])}" fill="none" stroke="{QUIET}"'
            ' stroke-width="1.6" stroke-linecap="round"'
            ' stroke-linejoin="round"/>')

def border(pose, who):
    """A dancer's whole boundary: one quiet outline, broken at the hands.

    It says nothing but *here is a body*.  The rim used to fill up in an arm's
    colour as that arm wound round, which was a second progress ring saying
    what the connection already says by wrapping -- so the ring is gone and the
    line keeps the job.
    """
    centre, facing = pose[who], pose[f"{who}_facing"]
    wind = pose[f"{who}_wind"]

    # Every stretch stops a hand-gap short of a hand, so the boundary never
    # runs through a mark -- and a stretch that extreme winding has squeezed
    # away is simply not drawn.
    right, left = ARM_REST + wind["R"], ARM_REST + wind["L"]
    stretches = [
        (right + HAND_GAP, 360 - left - HAND_GAP),        # behind
        (360 - left + HAND_GAP, 360 + right - HAND_GAP),  # across the front
    ]
    return "".join(rim(centre, facing, facing + a, facing + b)
                   for a, b in stretches if b - a > 0.01)

def fill_of(level, arm, deep=False):
    """The one place a level becomes a fill, so hands and pips cannot drift."""
    if level == "low":
        return DEEP[arm] if deep else INK[arm]
    if level == "above":
        return f"url(#h{arm}{'d' if deep else ''})"
    return "none"

def hand(cx, cy, leads, side, held=True, level=None, free="fade"):
    """One hand, in its own side's ink: the lead's deep, the follow's plain."""
    ink = DEEP[side] if leads else INK[side]
    stroke = ink if (held or free == "fade") else QUIET
    fill = fill_of(level, side, leads) if held else "none"
    faded = "" if held or free != "fade" else f' opacity="{FREE}"'
    dot = ""
    if level == "high":
        dot = f'<circle cx="{n(cx)}" cy="{n(cy)}" r="2.7" fill="{stroke}"/>'
    style = f"fill: {fill}; stroke: {stroke}; stroke-width: 1.5"
    if leads:
        shape = (f'<rect x="{n(cx - R)}" y="{n(cy - R)}" width="{2 * R}"'
                 f' height="{2 * R}" rx="1.5" style="{style}"{faded}/>')
    else:
        shape = (f'<circle cx="{n(cx)}" cy="{n(cy)}" r="{R}" style="{style}"'
                 f'{faded}/>')
    return shape + dot

def ring_of(pose):
    """The orbit, drawn only while one is happening.

    Nothing else in the picture is dashed, so a dashed circle says one thing:
    somebody is going round somebody.  It is centred on whoever is standing
    still -- a partner, or the midpoint when both of them travel.
    """
    if pose["ring"] is None:
        return ""
    (cx, cy), radius = pose["ring"]
    return (f'<circle cx="{n(cx)}" cy="{n(cy)}" r="{n(radius)}" fill="none"'
            f' stroke="{QUIET}" stroke-width="1" stroke-dasharray="3 4"/>')

def caption(centre, facing, side, text, wind=0.0):
    """A hand's name, set just past it and growing outwards."""
    x, y = polar(centre[0], centre[1], CAPTION_R,
                 hand_bearing(facing, side, wind))
    dx = x - centre[0]
    if dx < -2:
        anchor, dy = "end", 3
    elif dx > 2:
        anchor, dy = "start", 3
    else:
        anchor, dy = "middle", (-3 if y < centre[1] else 8)
    return (f'<text x="{n(x)}" y="{n(y + dy)}" text-anchor="{anchor}"'
            ' style="font: 8px ui-sans-serif, system-ui, sans-serif;'
            f' fill: {FAINT}">{text}</text>')

def other(side):
    return "R" if side == "L" else "L"


def side_of(where):
    """The follow's own side, from the name a hold stores their hand under."""
    return "L" if where == "left" else "R"

def hands_of(pose):
    return {who: {s: hand_point(pose[who], pose[f"{who}_facing"], s,
                                pose[f"{who}_wind"][s])
                  for s in ("L", "R")}
            for who in ("lead", "follow")}
