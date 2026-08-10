"""A whole picture: two dancers, their connections, and how it moves.

A static figure is drawn from a canonical pose.  An animated one samples a
cycle of poses on one clock -- the bodies carried rigidly by transforms, the
reach re-routed each frame with the previous frame's way round a body kept
unless a new one is decisively shorter -- so everything stays in one piece.
"""
import math

from .body import (BODY_R, CAPTION_R, R, border, caption, chevron, hand,
                   hand_point, hands_of, other, ring_of, round_of,
                   settled_wind, side_of, slot_of)
from .geometry import continuous, n, xy
from .pose import NO_WIND, canonicalise, cycle, rest, spin_about
from .route import (cut_gap, one_way_round, reach_markup, routed, split_at,
                    straight_reach, way_for, wraps_enough)
from .style import DEEP, INK, LINK_W, QUIET


WIDE = 160                # the box a picture with captions needs

SIZE = 116                # and the box it needs without them

def two_tone(runs, mid, lead_side, foll_side):
    """One reach in its two hands' own colours, meeting at its middle point.

    Each half is exactly the mark it ends on: the lead's in their arm's ink and
    the deep shade, the follow's in theirs and the plain one.  So a line draws
    the pair of colours that names which hands are joined, instead of leaving
    it to two marks that go too small to read; and the shade still says which
    end is whose when both hands share a hue.
    """
    near, far = split_at(runs, mid)
    return [reach_markup(near, DEEP[lead_side]), reach_markup(far, INK[foll_side])]

def ghosts(holds, levels, ways):
    """Every hand that is not where its arm hangs, as `(who, side)`."""
    out = []
    for side, where in holds.items():
        level, way = levels.get(side), ways.get(side)
        for who, own in (("lead", side), ("follow", side_of(where))):
            if slot_of(own, level, way) != (own, "default"):
                out.append((who, own))
    return out

def danceable(pose, holds, levels=None, ways=None):
    """Whether every lock and wrap in this hold really is one.

    A lock or wrap position may only be used when the line goes round no less
    than just under half the circumference -- it does not mean anything to have
    a wrap without the line actually going round the body.  So whether a state
    exists at all depends on the orientation, and this is what says so.
    """
    levels, ways = levels or {}, ways or {}
    pose = settled(pose, holds, levels, ways)
    p = hands_of(pose)
    bodies = ((pose["lead"], pose["lead_facing"]),
              (pose["follow"], pose["follow_facing"]))
    for side, where in holds.items():
        level, way = levels.get(side), ways.get(side)
        if round_of(level, way) is None:
            continue                      # nothing claimed, nothing to hold up
        ends = (p["lead"][side], p["follow"][side_of(where)])
        if not wraps_enough(ends, bodies, level, way):
            return False
    return True

def settled(pose, holds, levels, ways):
    """The same pose with every hand put in the slot its hold settles it in.

    There is nothing to solve: a settled hand is in one of six places, and
    which one is decided by its own side and by the level and way of the hold
    it is part of.  A hand that is free, or held by a hold that has not said
    both, stays where the arm hangs.  Hands still move smoothly between slots
    when a picture moves; it is the settled state that is discrete.
    """
    wind = {who: dict(NO_WIND) for who in ("lead", "follow")}
    for side, where in holds.items():
        level, way = levels.get(side), ways.get(side)
        wind["lead"][side] = settled_wind(side, level, way)
        own = side_of(where)
        wind["follow"][own] = settled_wind(own, level, way)
    return dict(pose, lead_wind=wind["lead"], follow_wind=wind["follow"])

def parts_of(pose, holds, levels=None, over=None, free="fade", captions=True,
             ways=None):
    """Every element of one pose, in the order the picture is read from."""
    levels, ways = levels or {}, ways or {}
    # A lock or wrap that does not go round the body is not one, and a state
    # that cannot be danced is an edge that is not drawn -- so this refuses
    # rather than drawing something the rules say does not exist.
    assert danceable(pose, holds, levels, ways), (holds, levels, ways)
    # Every drawing path comes through here, so this is where the hands are
    # put: a pose handed in ready-made is settled exactly like one built below.
    pose = settled(pose, holds, levels, ways)
    p = hands_of(pose)

    def foll(where):
        return p["follow"][side_of(where)]

    out = [ring_of(pose), border(pose, "lead"), border(pose, "follow")]
    for who in ("lead", "follow"):
        out.append(chevron(pose[who], pose[f"{who}_facing"]))
    # Where each displaced hand came from, as a grey outline of its own mark.
    # `behind` carries locks and wraps alike, so a hand no longer says by where
    # it sits how far it has been taken -- the ghost of the place it left says
    # it instead, and a hand still at home has no ghost to confuse it with.
    for who, side in ghosts(holds, levels, ways):
        x, y = hand_point(pose[who], pose[f"{who}_facing"], side)
        out.append(hand(x, y, who == "lead", side, held=False, free="grey"))
    bodies = ((pose["lead"], pose["lead_facing"]),
              (pose["follow"], pose["follow_facing"]))
    routes = {}
    for side in holds:
        where = holds[side]
        ends = (p["lead"][side], foll(where))
        if levels.get(side) == "above":
            routes[side] = straight_reach(*ends)     # over the head, over all
        else:
            # what the hold says, if it says anything; the short way if not
            routes[side], _ = routed(*ends, *bodies, way=way_for(
                ends, bodies, levels.get(side), ways.get(side)))
    order = ["L", "R"] if over != "L" else ["R", "L"]
    for side in order:
        if side in holds:
            pts = routes[side]
            runs = [pts]
            if over == other(side):
                runs = cut_gap(pts, routes[other(side)])
            out += two_tone(runs, pts[len(pts) // 2], side,
                            side_of(holds[side]))
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
          free="fade", captions=True, pose=None, half=None, ways=None):
    """One picture, canonical unless a pose is handed in already turned."""
    if pose is None:
        pose = canonicalise(spin_about(spin_about(rest(), "lead", lead_turn),
                                       "follow", follow_turn))
    if half is None:
        half = (WIDE if captions else SIZE) / 2
    bits = parts_of(pose, holds, levels, over, free, captions, ways)
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

def animated(cls, holds, move, half=None, levels=None, ways=None, dur=9.6,
             samples=14):
    """The same picture, moving: stage one travels, stage two comes home."""
    levels, ways = levels or {}, ways or {}
    poses = [settled(p, holds, levels, ways) for p in cycle(move, samples)]
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
    # One reach per frame, every frame the same number of points, and -- this
    # is the whole of it -- **one way round both bodies for the entire move**.
    # What a browser draws between two sample frames is the two reaches blended
    # point by point, so two neighbouring frames that disagree about which side
    # of a body the line passes are drawn, in between, as a line sweeping
    # straight through that body.  Only an `above` connection may ever do that.
    # Settling the way round once, before any frame is routed, makes the
    # disagreement impossible rather than unlikely.  The halves are split at a
    # fixed index, which the even resampling makes the middle of the line, so
    # both shades morph as one shape.
    frames = [(h["lead"][side], foll(h, site),
               (q["lead"], q["lead_facing"]), (q["follow"], q["follow_facing"]))
              for h, q in zip(hands, poses)]
    if levels.get(side) == "above":
        routes = [straight_reach(a, b) for a, b, _, _ in frames]
    else:
        # A hold that says which way round says it for every frame at once: a
        # slot is fixed relative to its facing, so the direction is too.  Where
        # it says nothing, one way is picked for the whole move instead.
        said = way_for(frames[0][:2], frames[0][2:],
                       levels.get(side), ways.get(side))
        way = said or one_way_round(frames)
        routes = [routed(*f, way=way)[0] for f in frames]
    middle = len(routes[0]) // 2
    for ink, cut in ((DEEP[side], slice(None, middle + 1)),
                     (INK[side_of(site)], slice(middle, None))):
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
