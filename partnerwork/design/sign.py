"""The turn sign: a gauge of quarter turns, read like the frame pictures.

The outline holds exactly one full turn and rows pack up from the foot, so how
far a turn goes is how full the sign is.  A column is one of the lead's arms, a
pip's shape says whose quarter it is, its fill says that arm's level, and a
dashed outline says the turn travels round the couple.
"""
import math

from .body import fill_of
from .geometry import n
from .style import DEEP, INK


TAN = 0.25                                  # lean, as across per down

THETA = math.atan(TAN)
SIN, COS = math.sin(THETA), math.cos(THETA)

PIP = 11.0                                  # pip width, across the sign

GAP_X = 4.0                                 # margin, and the gutter between arms

BODY = 2 * PIP + 3 * GAP_X                  # width between the slanting edges

QUARTERS = 4                                # rows in a full turn

HEIGHT = QUARTERS * PIP + (QUARTERS + 1) * GAP_X   # so a full sign is a full turn

OVER = PIP                                  # how far an open end runs on

INSET = 0.76                                # how far a dashed pip's fill pulls in

def dashes(perimeter, count, duty=0.58):
    """A dash pattern that closes on itself, so no stub shows where it joins."""
    period = perimeter / count
    return f"{n(period * duty)} {n(period * (1 - duty))}"

def scaled(points, factor):
    """Pull a polygon in towards its own centre."""
    cx = sum(x for x, _ in points) / len(points)
    cy = sum(y for _, y in points) / len(points)
    return [(cx + (x - cx) * factor, cy + (y - cy) * factor) for x, y in points]

def poly(points, close=True):
    d = "M" + " L".join(f"{n(x)} {n(y)}" for x, y in points)
    return d + " Z" if close else d

def pip(dancer, ax, ay, dxs, dys, arm, level, about=None):
    """One quarter turn: shape says whose, column and ink which arm, fill its level.

    Given an `about` the pip carries axis-against-orbit itself, which needs the
    fill pulled in off the outline -- a low pip is filled in the arm's own ink,
    and a dashed stroke of that ink on top of it would be no stroke at all.

    A pip takes the shade of the hand it stands for, the lead's deep and the
    follow's plain, so a sign and a frame picture read the same way round.
    """
    leads = dancer == "lead"
    ink = DEEP[arm] if leads else INK[arm]
    fill = fill_of(level, arm, leads)
    cx, cy = ax + PIP / 2 + dxs / 2, ay + dys / 2
    out = []
    if leads:
        pts = [(ax, ay), (ax + PIP, ay), (ax + PIP + dxs, ay + dys),
               (ax + dxs, ay + dys)]
        edge, body = poly(pts), poly(scaled(pts, INSET))
        perimeter = 2 * PIP + 2 * math.hypot(dxs, dys)
    else:
        edge = body = None
        perimeter = 2 * math.pi * (PIP / 2)

    def shape(d, r, style):
        if d is not None:
            return f'<path d="{d}" {style}/>'
        return f'<circle cx="{n(cx)}" cy="{n(cy)}" r="{n(r)}" {style}/>'

    if about is None:
        out.append(shape(edge, PIP / 2,
                         f'fill="{fill}" stroke="{ink}" stroke-width="1.4"'
                         ' stroke-linejoin="round"'))
    else:
        if fill != "none":
            out.append(shape(body, PIP / 2 * INSET, f'fill="{fill}" stroke="none"'))
        dash = (f' stroke-dasharray="{dashes(perimeter, 8)}"'
                if about == "orbit" else "")
        out.append(shape(edge, PIP / 2,
                         f'fill="none" stroke="{ink}" stroke-width="1.4"'
                         f' stroke-linejoin="round"{dash}'))
    if level == "high":
        out.append(f'<circle cx="{n(cx)}" cy="{n(cy)}" r="2.5" fill="{ink}"/>')
    return "".join(out)

def marker(kind, ax, ay, dxs, dys, arm):
    """A row that counts nothing: it says the count does not end."""
    ink = INK[arm]
    cx, cy = ax + PIP / 2 + dxs / 2, ay + dys / 2
    if kind == "ellipsis":                  # and so on, across
        return "".join(f'<circle cx="{n(cx + d)}" cy="{n(cy)}" r="1.7"'
                       f' fill="{ink}"/>' for d in (-3.7, 0, 3.7))
    return "".join(f'<circle cx="{n(cx)}" cy="{n(cy + d)}" r="1.9"'
                   f' fill="{ink}"/>' for d in (-3.1, 3.1))

def sign_body(slots, way, arms, x0, y_foot, about, pip_about, ending,
              packed=True):
    """The sign at a place.  Returns markup and the box it fills.

    `slots` reads downwards, one entry per quarter turn, the follow's first, so
    a mixed sign has one picture rather than two.  The stack packs up from the
    foot: the outline holds a full turn, so how full it is is how far it goes,
    and the count is a check on the reading rather than the whole of it.
    """
    y_bot = y_foot + HEIGHT
    y_top = y_foot
    lean = HEIGHT * TAN
    over = OVER if ending in ("open", "spill") else 0.0

    if way == "cw":                         # leans right going up
        def left_at(y):
            return x0 + (y_bot - y) * TAN
        slant = -SIN
    else:
        def left_at(y):
            return x0 + (y - y_top) * TAN
        slant = SIN

    def slot_top(place):
        """Top of the slot `place` rows up from the foot."""
        return y_bot - GAP_X - place * (PIP + GAP_X) - PIP

    foot = [(left_at(y_bot), y_bot), (left_at(y_bot) + BODY, y_bot)]
    head = [(left_at(y_top), y_top), (left_at(y_top) + BODY, y_top)]
    perimeter = 2 * BODY + 2 * math.hypot(lean, HEIGHT)
    # The couple's centre line is dashed in every frame picture, so a turn that
    # goes round that centre is dashed too, rather than learning a new mark.
    dash = (f' stroke-dasharray="{dashes(perimeter, 20)}"'
            if about == "orbit" else "")
    style = (f'fill="none" stroke="var(--ink)" stroke-width="2"'
             f' stroke-linejoin="round" stroke-linecap="round"{dash}')

    if over:
        # No lid, and the sides run on past where one would be: a box that never
        # closes is a count that never finishes.
        tips = [(left_at(y_top - over), y_top - over),
                (left_at(y_top - over) + BODY, y_top - over)]
        outline = poly([tips[0], foot[0], foot[1], tips[1]], close=False)
    else:
        outline = poly([foot[0], head[0], head[1], foot[1]])
    out = [f'<path d="{outline}" {style}/>']

    if ending == "loop":
        # The graph's own loop edge, drawn on its label.
        ax0, ay0 = head[0]
        bx0, by0 = foot[0]
        reach = 15
        out.append(f'<path d="M{n(ax0 - 2)} {n(ay0 + 5)} C{n(ax0 - reach)}'
                   f' {n(ay0 + 6)} {n(bx0 - reach)} {n(by0 - 6)} {n(bx0 - 3)}'
                   f' {n(by0 - 5)}" fill="none" stroke="var(--ink)"'
                   ' stroke-width="1.6" stroke-linecap="round"/>')
        out.append(f'<path d="M{n(bx0 - 8)} {n(by0 - 8.5)} L{n(bx0 - 3)}'
                   f' {n(by0 - 5)} L{n(bx0 - 8.5)} {n(by0 - 2.5)}" fill="none"'
                   ' stroke="var(--ink)" stroke-width="1.6"'
                   ' stroke-linecap="round" stroke-linejoin="round"/>')

    total = len(slots)
    spread = (HEIGHT - total * PIP) / (total + 1)
    for i, what in enumerate(slots):
        top = (slot_top(total - 1 - i) if packed
               else y_top + spread + i * (PIP + spread))
        top += (PIP - PIP * COS) / 2
        for col, arm in enumerate(("L", "R")):
            if arm not in arms:
                continue
            ax = left_at(top) + GAP_X + col * (PIP + GAP_X)
            if what in ("lead", "follow"):
                out.append(pip(what, ax, top, PIP * slant, PIP * COS, arm,
                               arms[arm], pip_about[i] if pip_about else None))
            else:
                out.append(marker(what, ax, top, PIP * slant, PIP * COS, arm))

    ys = [y_bot, y_top - over]
    xs = [left_at(y) for y in ys] + [left_at(y) + BODY for y in ys]
    if ending == "loop":
        xs.append(min(foot[0][0], head[0][0]) - 16)
    return "\n        ".join(out), (min(xs), y_top - over, max(xs), y_bot)

def sign(slots, way="cw", arms=None, about=None, pip_about=None, ending=None,
         scale=1.2, packed=True):
    """One turn sign: quarter turns up from the foot, arms across, one height."""
    arms = {"L": None, "R": None} if arms is None else arms
    if ending in ("ellipsis", "repeat"):
        slots = [ending] + list(slots)
    elif ending == "spill":
        # the pip cut by the missing lid repeats whoever the top quarter is
        slots = [slots[0]] + list(slots)
    pad = 5.0
    markup, (bx0, by0, bx1, by1) = sign_body(slots, way, arms, pad, pad + OVER,
                                             about, pip_about, ending, packed)
    w, h = bx1 - bx0 + 2 * pad, by1 - by0 + 2 * pad
    return (f'<svg viewBox="{n(bx0 - pad)} {n(by0 - pad)} {n(w)} {n(h)}"'
            f' width="{n(w * scale)}" height="{n(h * scale)}">'
            f'\n        {markup}\n      </svg>')
