"""The couple in world coordinates, and every way they can rotate.

A pose is where the two dancers actually are; `canonicalise` turns the world
until the lead faces up the page, which is what makes two poses that are the
same configuration seen from different angles the same picture.  A cycle is
move, come home, move back, come home, so an animation returns to its start.
"""
import math

from .geometry import bearing, turn, wrap180


SEPARATION = 56           # between the two dancers' centres

NO_WIND = {"L": 0.0, "R": 0.0}

def rest(wind=None):
    """The pose every picture is measured from: the lead facing up the page."""
    wind = wind or {}
    return {"lead": (0.0, SEPARATION / 2), "lead_facing": 0.0,
            "follow": (0.0, -SEPARATION / 2), "follow_facing": 180.0,
            "lead_wind": dict(wind.get("lead", NO_WIND)),
            "follow_wind": dict(wind.get("follow", NO_WIND)),
            "ring": None}

def moved_pose(pose, mid, spin, amount):
    def moved(p):
        p = turn(p, mid, spin)
        return (p[0] - amount * mid[0], p[1] - amount * mid[1])

    out = dict(pose)
    out.update({"lead": moved(pose["lead"]), "follow": moved(pose["follow"]),
                "lead_facing": pose["lead_facing"] + spin,
                "follow_facing": pose["follow_facing"] + spin})
    if pose["ring"] is not None:
        out["ring"] = (moved(pose["ring"][0]), pose["ring"][1])
    return out

def canonicalise(pose, amount=1.0):
    """Turn the world until the lead faces up the page.

    Not until the pair stands upright -- until the *lead* does.  Everything is
    read from them, so they are the thing that holds still, and where the follow
    has got to is then part of what the picture says rather than something the
    framing has thrown away.  At `amount` 0 it leaves the pose alone and at 1 it
    finishes the job, so the second stage of a move is animated rather than
    snapped.
    """
    mid = ((pose["lead"][0] + pose["follow"][0]) / 2,
           (pose["lead"][1] + pose["follow"][1]) / 2)
    return moved_pose(pose, mid, -amount * wrap180(pose["lead_facing"]), amount)

def spin_about(pose, who, degrees):
    """A dancer turns on their own axis: nothing travels."""
    out = dict(pose)
    out[f"{who}_facing"] = pose[f"{who}_facing"] + degrees
    out["ring"] = None
    return out

def orbit(pose, who, degrees, locked=True):
    """A dancer walks the ring round the other one, who stands still.

    `locked` keeps their face to their partner all the way round; without it
    they keep their own bearing and arrive facing the way they set off.  Those
    are two different moves and they land in two different places.
    """
    pivot = pose["follow" if who == "lead" else "lead"]
    out = dict(pose)
    out[who] = turn(pose[who], pivot, degrees)
    out[f"{who}_facing"] = pose[f"{who}_facing"] + (degrees if locked else 0)
    out["ring"] = (pivot, math.dist(pose[who], pivot))
    return out

def couple(pose, degrees):
    """Both go round each other: the pair turns rigidly about the midpoint."""
    mid = ((pose["lead"][0] + pose["follow"][0]) / 2,
           (pose["lead"][1] + pose["follow"][1]) / 2)
    out = moved_pose(pose, mid, degrees, 0.0)
    out["ring"] = (mid, math.dist(pose["lead"], mid))
    return out

def relative(pose):
    """What a canonical picture holds: where the follow is, and how they face.

    Both measured against the lead, because the lead is what the picture holds
    still.  Two poses with the same pair are the same picture.
    """
    axis = bearing(pose["follow"][0] - pose["lead"][0],
                   pose["follow"][1] - pose["lead"][1])
    return (round((axis - pose["lead_facing"]) % 360, 6),
            round((pose["follow_facing"] - pose["lead_facing"]) % 360, 6))

def ease(t):
    """Slow at both ends, so the two stages read as stages rather than as blur."""
    return (1 - math.cos(math.pi * t)) / 2

def cycle(move, samples=14):
    """Move, come home, move back, come home -- and so return to the start."""
    poses = []
    for sign in (1, -1):
        base = poses[-1] if poses else rest()
        for i in range(samples + 1):
            poses.append(move(base, sign * ease(i / samples)))
        landed = poses[-1]
        for i in range(samples + 1):
            # nothing travels in the second stage, so the ring goes out with it
            home = canonicalise(landed, ease(i / samples))
            home["ring"] = None
            poses.append(home)
    return poses

MOVES = {
    "lead axis": lambda p, s: spin_about(p, "lead", 90 * s),
    "follow orbits the lead": lambda p, s: orbit(p, "follow", 90 * s),
    "the lead orbits the follow": lambda p, s: orbit(p, "lead", 90 * s),
    "both, round each other": lambda p, s: couple(p, 90 * s),
}
