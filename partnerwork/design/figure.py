"""A whole picture: two dancers, their connections, and how it moves.

A static figure is drawn from a canonical pose.  An animated one samples a
cycle of poses on one clock -- the bodies carried rigidly by transforms, the
reach re-routed each frame with the previous frame's way round a body kept
unless a new one is decisively shorter -- so everything stays in one piece.
"""
import math

from .body import (BODY_R, CAPTION_R, CARRY, HAND_GAP, MEET, R, border,
                   caption, chevron, hand, hand_bearing, hand_point,
                   hands_of, other, ring_of, side_of)
from .geometry import continuous, n, wrap180, xy
from .pose import NO_WIND, canonicalise, cycle, rest, spin_about
from .route import cut_gap, reach_markup, routed, split_at, straight_reach
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

STEP = 1.0                # how far a sliding hand moves before looking again

ROUNDS = 400              # steps before the hands are taken as settled

def freed_by(holds, levels):
    """Which hands a level has let go of.

    A hand leaves the side of its body only when the hold it is part of names a
    level: a level is what lets an arm pass over or under, and passing is what
    carries a hand round.  No level, no wrap -- so a free hand, and a held hand
    at no level, stay where the arm hangs.
    """
    out = []
    for side, where in holds.items():
        if levels.get(side) is not None:
            out.append((side, side_of(where)))
    return out

def settled(pose, holds, levels, seed=None):
    """The same pose with every hand's winding solved rather than asked for.

    A freed hand slides along the rim in whichever direction shortens its
    connection, and goes as far as it can.  Three things stop it: `CARRY`, the
    furthest a hand is carried from its own side; a dancer's own two hands,
    which may not pass through each other, which is what keeps a crossed hold
    crossed; and `MEET`, the closest two joined marks may come, so the line
    between them still has room to say whose ends it has.

    All three hold where it starts, so there is always an answer and it only
    ever improves on one.  A still picture starts from rest and *scans* the rim,
    which makes it a function of its pose alone.  A moving one starts from the
    frame before (`seed`) and *steps*, so a hand travels round a body rather
    than being found on the far side of it a frame later.
    """
    wind = {who: dict(seed[who] if seed else NO_WIND)
            for who in ("lead", "follow")}
    pairs = freed_by(holds, levels)

    def at(who, side, w=None):
        return hand_point(pose[who], pose[f"{who}_facing"], side,
                          wind[who][side] if w is None else w)

    def allowed(who, side, w, joined):
        """Whether this hand may sit here: clear of its own partner hand on the
        same body, and no nearer than `MEET` to the hand it is joined to."""
        apart = wrap180(hand_bearing(0, side, w)
                        - hand_bearing(0, other(side), wind[who][other(side)]))
        return (abs(w) <= CARRY + 1e-9
                and abs(apart) >= 2 * HAND_GAP - 1e-9
                and math.dist(at(who, side, w), joined) >= MEET - 1e-9)

    def place(who, side, joined):
        """The best legal place on this rim, holding everything else still.

        Scanned rather than walked: a hand near the point *opposite* its
        partner sits on a ridge, and a walker can set off down the steeper side
        rather than the shorter way round -- then chase a partner that is
        moving too, and settle half a body away from the best place there was.
        Looking at the whole rim cannot do that.
        """
        best, near = wind[who][side], math.dist(at(who, side), joined)
        w = -CARRY
        while w <= CARRY:
            if allowed(who, side, w, joined):
                far = math.dist(at(who, side, w), joined)
                if far < near - 1e-9:
                    best, near = w, far
            w += STEP
        moved = best != wind[who][side]
        wind[who][side] = best
        return moved

    def nudge(who, side, joined):
        """One step towards the hand this one is joined to, if there is a step
        that shortens the arm and nothing forbids it.

        What a moving picture uses instead of `place`: from the frame before,
        one step at a time, so a hand travels round a body rather than being
        found on the other side of it a frame later.
        """
        near = math.dist(at(who, side), joined)
        for way in (STEP, -STEP):
            w = wind[who][side] + way
            if (math.dist(at(who, side, w), joined) < near
                    and allowed(who, side, w, joined)):
                wind[who][side] = w
                return True
        return False

    settle = nudge if seed else place

    # One step each per round, rather than one hand walking as far as it can
    # and then the next: the arm is shortened by both its ends at once, so two
    # hands meet in the middle instead of whichever moved first spending all
    # the room there was and pinning the other where it stood.  Within a round
    # the second hand still sees where the first has just got to, or both could
    # step to a place that is legal apart and illegal together.
    for _ in range(ROUNDS):
        moved = False
        for lead_side, own in pairs:
            ends = (("lead", lead_side), ("follow", own))
            for mine, theirs in (ends, ends[::-1]):
                moved |= settle(*mine, at(*theirs))
        if not moved:
            break
    return dict(pose, lead_wind=wind["lead"], follow_wind=wind["follow"])

def settle_cycle(poses, holds, levels, laps=2):
    """Settle a whole cycle so that it closes on itself.

    Each frame is solved from the one before, so a hand tracks its partner
    round instead of jumping -- but that makes the first frame, which has no
    frame before it, start from rest and land somewhere the last frame does
    not.  An orbit that winds an arm out never unwinds it, so the loop would
    snap.  Running the cycle once as a warm-up and keeping the second lap fixes
    that: the walk is periodic from the first lap on, so the lap that is drawn
    begins where it ends.
    """
    seed, out = None, []
    for lap in range(laps):
        out = []
        for pose in poses:
            pose = settled(pose, holds, levels, seed)
            seed = {who: pose[f"{who}_wind"] for who in ("lead", "follow")}
            out.append(pose)
    return out

def parts_of(pose, holds, levels=None, over=None, free="fade", captions=True,
             want=None):
    """Every element of one pose, in the order the picture is read from."""
    levels = levels or {}
    # Every drawing path comes through here, so this is where the hands are
    # put: a pose handed in ready-made is settled exactly like one built below.
    pose = settled(pose, holds, levels)
    p = hands_of(pose)

    def foll(where):
        return p["follow"][side_of(where)]

    out = [ring_of(pose), border(pose, "lead"), border(pose, "follow")]
    for who in ("lead", "follow"):
        out.append(chevron(pose[who], pose[f"{who}_facing"]))
    bodies = ((pose["lead"], pose["lead_facing"]),
              (pose["follow"], pose["follow_facing"]))
    routes = {}
    for side in holds:
        where = holds[side]
        ends = (p["lead"][side], foll(where))
        if levels.get(side) == "above":
            routes[side] = straight_reach(*ends)     # over the head, over all
        else:
            # Nothing has an opinion about a still picture, so it takes the
            # short way round; `want` is what a turning body says.
            routes[side], _ = routed(*ends, *bodies, want=want or (0, 0))
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
          free="fade", captions=True, pose=None, half=None, want=None):
    """One picture, canonical unless a pose is handed in already turned."""
    if pose is None:
        pose = canonicalise(spin_about(spin_about(rest(), "lead", lead_turn),
                                       "follow", follow_turn))
    if half is None:
        half = (WIDE if captions else SIZE) / 2
    bits = parts_of(pose, holds, levels, over, free, captions, want)
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

def trailing(poses, who, still=0.5):
    """The way round this dancer their line should pay out, frame by frame.

    Counter to their own turning: a body turning clockwise carries its hand
    clockwise with it, so the way back towards where the line left last frame
    is anticlockwise.  Paying out that way keeps the departure point still
    while the body turns under it, which is what keeps a line on the same side
    of a body through a rotation instead of flicking to the other.  A dancer
    who is not turning has no opinion, and the previous frame's way round is
    left to hold it.
    """
    steps = facings(poses, who)
    out = []
    for k in range(len(steps)):
        turn = steps[(k + 1) % len(steps)] - steps[k]
        out.append(0 if abs(turn) < still else (-1 if turn > 0 else 1))
    return out

def animated(cls, holds, move, half=None, levels=None, dur=9.6, samples=14):
    """The same picture, moving: stage one travels, stage two comes home."""
    levels = levels or {}
    poses = settle_cycle(cycle(move, samples), holds, levels)
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
    trail = list(zip(trailing(poses, "lead"), trailing(poses, "follow")))
    for h, q, want in zip(hands, poses, trail):
        ends = (h["lead"][side], foll(h, site))
        if levels.get(side) == "above":
            routes.append(straight_reach(*ends))
            continue
        pts, combo = routed(*ends, (q["lead"], q["lead_facing"]),
                            (q["follow"], q["follow_facing"]),
                            prefer=combo, want=want)
        routes.append(pts)
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
