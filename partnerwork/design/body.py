"""One dancer: a circle whose rim swells into a point on the side they face.

The boundary is one polar function, `outline_r`, shared by the drawing, the
arms and the routing -- so "on the border" is true by construction rather than
by two pieces of code agreeing.  An arm is not a line laid on the rim: it *is*
the rim, over the stretch it covers, and it is inked only while its hand is
part of a connection.  Hands sit on the rim, each in its own side's colour,
so a body read across its facing is that dancer's orientation.
"""
import math

from .geometry import n, polar, wrap180, xy
from .style import BLOCK, FAINT, INK, QUIET


BODY_R = 20               # a dancer, seen from above; their hands sit on it

BULGE = 6                 # how far the point stands proud of the rim, short
                          # enough that two facing points do not touch

NOSE_HALF = 34            # how much rim the point grows out of, either side

RIM_W = 2.2               # one width for the whole boundary, arms included

RIM_STEP = 3              # degrees between samples where the boundary curves

ARM_REST = 90             # a hand at rest is a quarter of the rim from the point

ARM_BLOCK = 180           # an arm past half the rim has nowhere left to go

R = 6                     # a hand

CAPTION_R = BODY_R + R + 2   # just past the hand it names

FREE = 0.5                # how far a hand nobody holds fades, keeping its hue

def hand_bearing(facing, side, wind=0.0):
    return facing + (-1 if side == "L" else 1) * (ARM_REST + wind)

def hand_point(centre, facing, side, wind=0.0):
    """Where one hand is: round the rim from the point, by however far the arm
    has gone."""
    return polar(centre[0], centre[1], BODY_R,
                 hand_bearing(facing, side, wind))

def outline_r(delta):
    """How far the boundary is from the centre, at this bearing off the front.

    One function, used by the drawing, by the arms and by anything that has to
    stay outside a body -- so `on the border` is true by construction instead of
    by two pieces of code agreeing.  The swell reaches the rim with slope zero,
    so the point grows out of it with no corner; the only corner is the tip.
    """
    off = abs(wrap180(delta))
    if off >= NOSE_HALF:
        return BODY_R
    return BODY_R + BULGE * (1 - off / NOSE_HALF) ** 2

def outline_point(centre, facing, theta):
    return polar(centre[0], centre[1], outline_r(theta - facing), theta)

def rim(centre, facing, a, b, ink, width=RIM_W):
    """One stretch of the boundary, drawn once and by one owner.

    Outside the point the boundary is exactly the circle, so a stretch there is
    a circular arc; across the point it is sampled, finely enough that the
    sagitta is under a hundredth of a unit.
    """
    span = b - a
    plain = all(abs(wrap180(a + span * i / 12 - facing)) >= NOSE_HALF - 1e-9
                for i in range(13))
    if plain:
        start, end = outline_point(centre, facing, a), outline_point(centre, facing, b)
        large = 1 if abs(span) > 180 else 0
        sweep = 1 if span > 0 else 0
        d = f"M{xy(start)} A{BODY_R} {BODY_R} 0 {large} {sweep} {xy(end)}"
    else:
        steps = max(2, int(math.ceil(abs(span) / RIM_STEP)))
        pts = [outline_point(centre, facing, a + span * i / steps)
               for i in range(steps + 1)]
        d = "M" + " L".join(xy(q) for q in pts)
    return (f'<path d="{d}" fill="none" stroke="{ink}" stroke-width="{width}"'
            ' stroke-linecap="round" stroke-linejoin="round"/>')

def border(pose, who, engaged=frozenset()):
    """A dancer's whole boundary, drawn once, each stretch in its owner's ink.

    The arms are not lines laid on the rim -- they *are* the rim, over the
    stretch each one covers.  And only an arm that is part of a connection is
    inked: no connection, no line, so a free hand sits on a quiet border.
    """
    centre, facing = pose[who], pose[f"{who}_facing"]
    wind = pose[f"{who}_wind"]

    def ink(side):
        if side not in engaged:
            return QUIET
        return BLOCK if blocked(wind[side]) else INK[side]

    right, left = ARM_REST + wind["R"], ARM_REST + wind["L"]
    stretches = [
        (-NOSE_HALF, NOSE_HALF, QUIET),                       # the point
        (NOSE_HALF, right, ink("R")),
        (right, 360 - left, QUIET),                           # the back
        (360 - left, 360 - NOSE_HALF, ink("L")),
    ]
    return "".join(rim(centre, facing, facing + a, facing + b, colour)
                   for a, b, colour in stretches if abs(b - a) > 0.01)

def blocked(wind):
    """An arm past half the rim has run out of body to go round."""
    return ARM_REST + wind > ARM_BLOCK

def fill_of(level, arm):
    """The one place a level becomes a fill, so hands and pips cannot drift."""
    if level == "low":
        return INK[arm]
    if level == "above":
        return f"url(#h{arm})"
    return "none"

def hand(cx, cy, leads, side, held=True, level=None, free="fade"):
    """One hand, in its own side's ink whoever it belongs to."""
    stroke = INK[side] if (held or free == "fade") else QUIET
    fill = fill_of(level, side) if held else "none"
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
