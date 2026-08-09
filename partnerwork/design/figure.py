"""A whole picture: two dancers, their connections, and how it moves.

A static figure is drawn from a canonical pose.  An animated one samples a
cycle of poses on one clock -- the bodies carried rigidly by transforms, the
reach re-routed each frame with the previous frame's way round a body kept
unless a new one is decisively shorter -- so everything stays in one piece.
"""
import math

from .body import (BODY_R, CAPTION_R, R, border, caption, chevron, hand,
                   hands_of, other, ring_of, side_of)
from .geometry import continuous, n, xy
from .pose import canonicalise, cycle, rest, spin_about
from .route import cut_gap, reach_markup, routed, split_at
from .style import DEEP, INK, LINK_W, QUIET


WIDE = 160                # the box a picture with captions needs

SIZE = 116                # and the box it needs without them

def two_tone(runs, mid, side):
    """One reach in two shades of its arm's hue, meeting at its middle point.

    The lead's end is deep and the follow's plain, so a line says which end is
    whose along its own length -- and the pair of hands it joins is then read
    from the line as well as from the marks.
    """
    near, far = split_at(runs, mid)
    return [reach_markup(near, DEEP[side]), reach_markup(far, INK[side])]

def parts_of(pose, holds, levels=None, over=None, free="fade", captions=True,
             back_bias=None):
    """Every element of one pose, in the order the picture is read from."""
    levels = levels or {}
    p = hands_of(pose)

    def foll(where):
        return p["follow"][side_of(where)]

    out = [ring_of(pose), border(pose, "lead"), border(pose, "follow")]
    for who in ("lead", "follow"):
        out.append(chevron(pose[who], pose[f"{who}_facing"]))
    routes = {}
    for side in holds:
        where = holds[side]
        extra = {} if back_bias is None else {"back_bias": back_bias}
        routes[side], _ = routed(
            p["lead"][side], foll(where),
            (pose["lead"], pose["lead_facing"]),
            (pose["follow"], pose["follow_facing"]), **extra)
    order = ["L", "R"] if over != "L" else ["R", "L"]
    for side in order:
        if side in holds:
            pts = routes[side]
            runs = [pts]
            if over == other(side):
                runs = cut_gap(pts, routes[other(side)])
            out += two_tone(runs, pts[len(pts) // 2], side)
    for side in ("L", "R"):
        x, y = p["lead"][side]
        out.append(hand(x, y, True, side, side in holds, levels.get(side), free))
    for where in ("right", "left"):
        x, y = foll(where)
        by = next((s for s in holds if holds[s] == where), None)
        own = side_of(where)
        out.append(hand(x, y, False, own, by is not None,
                        levels.get(by) if by else None, free))
    if captions:
        for side in ("L", "R"):
            out.append(caption(pose["lead"], pose["lead_facing"], side,
                               "Left" if side == "L" else "Right",
                               pose["lead_wind"][side]))
        for where in ("right", "left"):
            own = "L" if where == "left" else "R"
            out.append(caption(pose["follow"], pose["follow_facing"], own,
                               where, pose["follow_wind"][own]))
    return [bit for bit in out if bit]

def extent(pose, captions=True):
    """How far this pose reaches from the origin, ring and captions included."""
    far = 0.0
    edge = (CAPTION_R + 20) if captions else (BODY_R + R + 2)
    for who in ("lead", "follow"):
        far = max(far, math.hypot(*pose[who]) + edge)
    if pose["ring"] is not None:
        (cx, cy), radius = pose["ring"]
        far = max(far, math.hypot(cx, cy) + radius + 4)
    return far

def view(half):
    return f'viewBox="{n(-half)} {n(-half)} {n(2 * half)} {n(2 * half)}"'

def frame(cls, holds, levels=None, over=None, lead_turn=0.0, follow_turn=0.0,
          free="fade", captions=True, pose=None, half=None, wind=None,
          back_bias=None):
    """One picture, canonical unless a pose is handed in already turned."""
    if pose is None:
        pose = canonicalise(spin_about(spin_about(rest(wind), "lead",
                                                  lead_turn),
                                       "follow", follow_turn))
    if half is None:
        half = (WIDE if captions else SIZE) / 2
    bits = parts_of(pose, holds, levels, over, free, captions, back_bias)
    return (f'<svg class="{cls}" {view(half)}>\n        '
            + "\n        ".join(bits) + "\n      </svg>")

def series(steps):
    """One clock for every moving part, so the figure stays in one piece."""
    return ";".join(v if isinstance(v, str) else n(v) for v in steps)

def animate(attr, steps, dur):
    return (f'<animate attributeName="{attr}" values="{series(steps)}"'
            f' dur="{dur}s" repeatCount="indefinite"/>')

def paired(markup, inner):
    """Reopen a self-closing element so it can carry its own animations."""
    tag = markup[1:markup.index(" ")]
    return markup[:-2] + ">" + inner + f"</{tag}>"

def facings(poses, who):
    """A dancer's facing through a cycle, continuous so it turns the way it
    turned.  Wrapped angles step from 179 to -179 at a half turn and are read
    as most of a turn the other way -- which is a body spinning backwards while
    its own hands, placed absolutely, travel the right way."""
    return continuous([p[f"{who}_facing"] for p in poses])

def animated(cls, holds, move, half=None, dur=9.6, samples=14):
    """The same picture, moving: stage one travels, stage two comes home."""
    poses = cycle(move, samples)
    if half is None:
        half = max(extent(p, captions=False) for p in poses)
    hands = [hands_of(p) for p in poses]
    side, site = next(iter(holds.items()))

    def foll(h, where):
        return h["follow"][side_of(where)]

    def ring_at(p):
        if p["ring"] is None:
            return (0.0, 0.0, 0.0)
        return (p["ring"][0][0], p["ring"][0][1], p["ring"][1])

    rings = [ring_at(p) for p in poses]
    out = [paired(
        f'<circle cx="0" cy="0" r="0" fill="none" stroke="{QUIET}"'
        ' stroke-width="1" stroke-dasharray="3 4"/>',
        animate("cx", [r[0] for r in rings], dur) +
        animate("cy", [r[1] for r in rings], dur) +
        animate("r", [r[2] for r in rings], dur))]
    # A body is rigid: only where it is and which way it faces ever change.  So
    # it is drawn once, at the origin facing up, and carried about by a pair of
    # transforms -- which is exact, and spares the markup a boundary per frame.
    for who in ("lead", "follow"):
        still = dict(rest())
        still.update({who: (0.0, 0.0), f"{who}_facing": 0.0,
                      f"{who}_wind": poses[0][f"{who}_wind"]})
        out.append(
            "<g>"
            + f'<animateTransform attributeName="transform" type="translate"'
            f' values="{series([f"{n(p[who][0])} {n(p[who][1])}" for p in poses])}"'
            f' dur="{dur}s" repeatCount="indefinite"/>'
            + f'<animateTransform attributeName="transform" type="rotate"'
            f' additive="sum" values="{series(facings(poses, who))}"'
            f' dur="{dur}s" repeatCount="indefinite"/>'
            + border(still, who)
            + chevron(still[who], still[f"{who}_facing"]) + "</g>")
    # One reach per frame, every frame the same number of points, and the way
    # round a body carried over from the frame before -- so the line wraps and
    # unwraps rather than flicking to the other side through the middle.  The
    # halves are split at a fixed index, which the even resampling makes the
    # middle of the line, so both shades morph as one shape.
    combo = None
    routes = []
    for h, q in zip(hands, poses):
        pts, combo = routed(h["lead"][side], foll(h, site),
                            (q["lead"], q["lead_facing"]),
                            (q["follow"], q["follow_facing"]), prefer=combo)
        routes.append(pts)
    middle = len(routes[0]) // 2
    for ink, cut in ((DEEP[side], slice(None, middle + 1)),
                     (INK[side], slice(middle, None))):
        paths = ["M" + " L".join(xy(pt) for pt in pts[cut]) for pts in routes]
        out.append(paired(
            f'<path d="{paths[0]}" fill="none" stroke="{ink}"'
            f' stroke-width="{LINK_W}" stroke-linecap="round"'
            ' stroke-linejoin="round"/>',
            animate("d", paths, dur)))
    for sd in ("L", "R"):
        pts = [h["lead"][sd] for h in hands]
        out.append(paired(
            hand(pts[0][0], pts[0][1], True, sd, sd in holds),
            animate("x", [q[0] - R for q in pts], dur) +
            animate("y", [q[1] - R for q in pts], dur)))
    for where in ("right", "left"):
        pts = [foll(h, where) for h in hands]
        out.append(paired(
            hand(pts[0][0], pts[0][1], False,
                 side_of(where), holds.get(side) == where),
            animate("cx", [q[0] for q in pts], dur) +
            animate("cy", [q[1] for q in pts], dur)))
    return (f'<svg class="{cls}" {view(half)}>\n        '
            + "\n        ".join(out) + "\n      </svg>")
