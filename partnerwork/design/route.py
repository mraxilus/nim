"""A connection, routed as a taut string around the two bodies.

Each end pays out along its own outline until the straight stretch between the
free ends clears both bodies, so a reach hugs a rim exactly as far as it must
and no further.  Every route is resampled to one fixed number of points, which
is what lets an animation morph a reach instead of jumping it.
"""
import math

from .body import BODY_R, R, RIM_STEP, outline_point, outline_r
from .geometry import bearing, xy
from .style import CAP, LINK_W


ROUTE_N = 33              # points in every emitted reach, so frames can morph

WAYS = ((1, 1), (1, -1), (-1, 1), (-1, -1))
    # the four ways a reach can set off: round one side of each body or the
    # other.  Which one a whole move uses is settled once, before any of it is
    # drawn -- see `one_way_round`

BREAK = 11.0

def seg_hits(p, q, body):
    """Whether this straight stretch passes inside a body's outline."""
    (c, f) = body
    steps = 32
    for i in range(steps + 1):
        t = i / steps
        pt = (p[0] + (q[0] - p[0]) * t, p[1] + (q[1] - p[1]) * t)
        if math.dist(pt, c) < outline_r(bearing(pt[0] - c[0],
                                                pt[1] - c[1]) - f) - 0.05:
            return True
    return False

def taut(a, b, A, B, d1, d2, cap=90):
    """A string pulled tight from hand to hand around the two bodies.

    Each end pays out along its own outline, one sample at a time, until the
    straight stretch between the two free ends clears both bodies -- so the
    reach hugs a rim exactly as far as it has to and no further, and where the
    straight way is already clear it never hugs at all.
    """
    (ca, fa), (cb, fb) = A, B
    ta = bearing(a[0] - ca[0], a[1] - ca[1])
    tb = bearing(b[0] - cb[0], b[1] - cb[1])
    arc_a, arc_b = [a], [b]
    for _ in range(cap):
        pa, pb = arc_a[-1], arc_b[-1]
        ha, hb = seg_hits(pa, pb, A), seg_hits(pa, pb, B)
        if not ha and not hb:
            step = math.radians(RIM_STEP) * BODY_R
            length = step * (len(arc_a) + len(arc_b) - 2) + math.dist(pa, pb)
            return arc_a + arc_b[::-1], length
        if ha:
            ta += d1 * RIM_STEP
            arc_a.append(outline_point(ca, fa, ta))
        if hb:
            tb += d2 * RIM_STEP
            arc_b.append(outline_point(cb, fb, tb))
    return None, math.inf

def polyline_len(pts):
    return sum(math.dist(p, q) for p, q in zip(pts, pts[1:]))

def _trim_end(pts, centre, reach):
    """Cut the path where it leaves the hand's own mark, so ink starts on the
    mark's border rather than under its middle."""
    for i, q in enumerate(pts):
        d = math.dist(q, centre)
        if d >= reach:
            if i == 0:
                return pts
            prev = pts[i - 1]
            pd = math.dist(prev, centre)
            t = (reach - pd) / (d - pd) if d > pd else 0.0
            return [(prev[0] + (q[0] - prev[0]) * t,
                     prev[1] + (q[1] - prev[1]) * t)] + pts[i:]
    return pts[-1:]

def resample(pts, count):
    """The same path, as `count` evenly spaced points -- one shape for every
    frame of an animation, so a route can morph instead of jumping."""
    cum = [0.0]
    for p, q in zip(pts, pts[1:]):
        cum.append(cum[-1] + math.dist(p, q))
    total = cum[-1] or 1.0
    out, j = [], 0
    for k in range(count):
        target = total * k / (count - 1)
        while j < len(pts) - 2 and cum[j + 1] < target:
            j += 1
        span = cum[j + 1] - cum[j] or 1.0
        t = (target - cum[j]) / span
        p, q = pts[j], pts[j + 1]
        out.append((p[0] + (q[0] - p[0]) * t, p[1] + (q[1] - p[1]) * t))
    return out

def straight_reach(a, b):
    """A reach that goes over everything instead of round it.

    An `above` connection passes over the head, so from overhead there is
    nothing in its way -- no head, no torso -- and it is drawn straight across
    whatever it crosses.  Trimmed and resampled like any other reach, so it has
    the same shape and an animation can morph between it and a wrapping one.
    """
    pts = [a, b]
    reach = min(R + CAP, math.dist(a, b) / 3)
    pts = _trim_end(pts, a, reach)
    pts = _trim_end(pts[::-1], b, reach)[::-1]
    return resample(pts, ROUTE_N)


def routed(a, b, A, B, way=None):
    """One reach: hand border to hand border, wrapping wherever it must.

    With nothing said it takes the short way round.  Hand `way` one of `WAYS`
    and it takes that one instead, whatever the length -- which is how a whole
    move keeps to one side of a body from its first frame to its last.
    """
    best = None
    for combo in (WAYS if way is None else (way,)):
        pts, length = taut(a, b, A, B, *combo)
        if pts is not None and (best is None or length < best[1]):
            best = (pts, length, combo)
    if best is None:
        return None, None
    pts, _, combo = best
    reach = min(R + CAP, polyline_len(pts) / 3)
    pts = _trim_end(pts, a, reach)
    pts = _trim_end(pts[::-1], b, reach)[::-1]
    return resample(pts, ROUTE_N), combo

def one_way_round(frames):
    """The single way round a whole move is drawn with.

    A moving reach is interpolated between the frames it is sampled at, so two
    neighbouring frames that disagree about which side of a body the line
    passes are drawn, in between, as a line sweeping straight through that
    body.  Choosing one way for the whole move is what makes that impossible:
    no two frames can disagree if there is only one answer.  It has to be a way
    every frame can actually be routed, so the ones that fail anywhere are
    dropped and the shortest of the rest wins.

    Each frame is `(a, b, A, B)`, as `routed` takes them.
    """
    best = None
    for combo in WAYS:
        total = 0.0
        for a, b, A, B in frames:
            pts, _ = taut(a, b, A, B, *combo)
            if pts is None:
                break
            total += polyline_len(pts)
        else:
            if best is None or total < best[1]:
                best = (combo, total)
    assert best is not None, "no way round serves every frame of this move"
    return best[0]

def split_at(runs, mid):
    """Cut a reach in two at the point nearest `mid`, so it can be drawn in two
    shades that meet there.

    The two halves share that point, so the join is a join and not a gap; and
    any break an over-and-under crossing has already cut stays cut, because the
    runs are split rather than rebuilt.
    """
    best = None
    for i, run in enumerate(runs):
        for j, q in enumerate(run):
            d = math.dist(q, mid)
            if best is None or d < best[0]:
                best = (d, i, j)
    _, i, j = best
    near = list(runs[:i]) + [runs[i][:j + 1]]
    far = [runs[i][j:]] + list(runs[i + 1:])
    return ([run for run in near if len(run) > 1],
            [run for run in far if len(run) > 1])

def reach_markup(runs, ink):
    d = " ".join("M" + " L".join(xy(q) for q in run)
                 for run in runs if len(run) > 1)
    return (f'<path d="{d}" fill="none" stroke="{ink}"'
            f' stroke-width="{LINK_W}" stroke-linecap="round"'
            ' stroke-linejoin="round"/>')

def cut_gap(pts, over):
    """Break the under reach where the over one crosses it."""
    cum = [0.0]
    for p, q in zip(pts, pts[1:]):
        cum.append(cum[-1] + math.dist(p, q))
    i0 = min(range(len(pts)),
             key=lambda i: min(math.dist(pts[i], q) for q in over))
    here = cum[i0]
    first = [q for q, c in zip(pts, cum) if c <= here - BREAK / 2]
    second = [q for q, c in zip(pts, cum) if c >= here + BREAK / 2]
    return [first, second]
