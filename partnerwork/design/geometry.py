"""Scalars and vectors, in the drawing's own conventions.

Bearings are measured clockwise from straight up the page, because that is how
the pictures are read; and a number is written with one decimal and no negative
zero, so two poses that are the same pose emit the same markup.
"""
import math


def n(v):
    """One decimal, and no negative zero -- two poses that are the same pose
    must come out as the same markup, not as `0` against `-0`."""
    if not isinstance(v, float):
        return str(v)
    v = round(v, 1)
    if v == 0:
        v = 0.0
    return f"{v:.1f}".rstrip("0").rstrip(".")

def xy(p):
    return f"{n(p[0])} {n(p[1])}"

def polar(cx, cy, radius, degrees):
    """A point at a bearing, measured clockwise from straight up the page."""
    rad = math.radians(degrees)
    return cx + radius * math.sin(rad), cy - radius * math.cos(rad)

def bearing(dx, dy):
    """The bearing of a vector, in the same clockwise-from-up convention."""
    return math.degrees(math.atan2(dx, -dy))

def wrap180(degrees):
    return (degrees + 180) % 360 - 180

def continuous(angles):
    """The same turning, said without a jump in it.

    Each angle is taken the short way from the one before, so a sequence handed
    to an animation is monotone through a half turn instead of stepping from
    179 to -179 -- which anything interpolating between two frames reads as
    most of a turn backwards, and draws as a body spinning the wrong way.
    """
    out = [wrap180(angles[0])]
    for a in angles[1:]:
        out.append(out[-1] + wrap180(a - out[-1]))
    return out

def turn(point, about, degrees):
    rad = math.radians(degrees)
    dx, dy = point[0] - about[0], point[1] - about[1]
    return (about[0] + dx * math.cos(rad) - dy * math.sin(rad),
            about[1] + dx * math.sin(rad) + dy * math.cos(rad))
