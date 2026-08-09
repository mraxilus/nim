"""A connection, routed as a taut string around the two bodies.

Each end pays out along its own outline until the straight stretch between the
free ends clears both bodies, so a reach hugs a rim exactly as far as it must
and no further.  Every route is resampled to one fixed number of points, which
is what lets an animation morph a reach instead of jumping it.
"""
import math

from .body import BODY_R, R, RIM_STEP, outline_point, outline_r
from .geometry import bearing, wrap180, xy
from .style import CAP, LINK_W


ROUTE_N = 33              # points in every emitted reach, so frames can morph

HYSTERESIS = 9.0          # how much shorter a new route must be to displace one

BACK_BIAS = 25.0          # what setting off round a dancer's back costs.  An arm
                          # in a crossed hold crosses the front, so the front way
                          # wins unless the back way is this much shorter -- a
                          # preference rather than a rule, and the one number to
                          # change if the choice lands the other way (it is still
                          # an open question; the page draws both)

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

def front_of(hand, body):
    """The way round the rim that heads for this dancer's front, from here.

    Zero when the hand is dead ahead or dead behind, where neither way is
    more frontward than the other.
    """
    (c, f) = body
    off = wrap180(bearing(hand[0] - c[0], hand[1] - c[1]) - f)
    if abs(off) < 1e-9 or abs(abs(off) - 180) < 1e-9:
        return 0
    return -1 if off > 0 else 1


def routed(a, b, A, B, prefer=None, back_bias=BACK_BIAS):
    """One reach: hand border to hand border, wrapping wherever it must.

    A way that sets off round a dancer's back pays `back_bias` against one that
    crosses their front, and `prefer` keeps the previous frame's way round
    unless a new one is clearly shorter -- so a moving reach wraps and unwraps
    rather than flicking to the other side of a body through the middle of it.
    """
    fa, fb = front_of(a, A), front_of(b, B)
    best = None
    for combo in ((1, 1), (1, -1), (-1, 1), (-1, -1)):
        pts, length = taut(a, b, A, B, *combo)
        if pts is None:
            continue
        if fa and combo[0] != fa:
            length += back_bias
        if fb and combo[1] != fb:
            length += back_bias
        if prefer is not None and combo == prefer:
            length -= HYSTERESIS
        if best is None or length < best[1]:
            best = (pts, length, combo)
    pts, _, combo = best
    reach = min(R + CAP, polyline_len(pts) / 3)
    pts = _trim_end(pts, a, reach)
    pts = _trim_end(pts[::-1], b, reach)[::-1]
    return resample(pts, ROUTE_N), combo

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
