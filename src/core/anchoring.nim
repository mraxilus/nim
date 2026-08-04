## Choose where a constructed plane's disc is centred, at the moment it is constructed.
##
## A plane's rim and fill centre on an anchor chosen from the operation and the operand
## shapes, not always on the plane's own closest-to-origin support, which reads wrong for
## operands that do not straddle the origin symmetrically.
##
## **This must be stored, because it is not recoverable afterwards**: many different operand
## sets produce an identical plane multivector, which carries no memory of what built it. It is
## a rendering hint, and it is excluded from save and load for the same reason.

{.experimental: "strictFuncs".}

import std/options

import ./[algebra, catalogue]



#[ Anchor Derivation ]#

func creationAnchor*(
  operation: Operation, m, n, derived: Multivector
): Option[Position] =
  ## Choose the drawing anchor of a plane just constructed, where its construction implies one.
  ##   Reports nothing where it does not, and the drawing falls back to the plane's support.
  if derived.shape != Shape.Plane or derived.locus != Locus.Finite: return

  case operation
  of Operation.Wedge:
    # Join of a line and a point: centre between the point and its foot on the line, so the
    #   disc sits over the pair that built it rather than over the origin.
    let (point, line) =
      if m.shape == Shape.Point and n.shape == Shape.Line: (m, n)
      elif m.shape == Shape.Line and n.shape == Shape.Point: (n, m)
      else: (Multivector(), Multivector())
    if point.shape != Shape.Point or line.shape != Shape.Line: return
    if point.locus != Locus.Finite or line.locus != Locus.Finite: return
    midpoint(point, point.projectOrthogonal(line))
  of Operation.ExpandWeight:
    # Weight expansion of a point with a line: centre where that line meets the new plane.
    if m.shape != Shape.Point or n.shape != Shape.Line: return
    (n ∨ derived).position
  else:
    none(Position)
