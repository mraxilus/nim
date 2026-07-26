## Visualise geometric objects of RGA by drawing them into SVG document.
##
## Prototype covers 4D rigid PGA only, i.e. 3D Euclidean space, where grade names object:
## grade 1 is point, grade 2 is line, grade 3 is plane.
##   Conformal metric is out of scope until library's round objects settle.
##   Run as `nim c -r visualiser.nim out.svg`; defaults suit 4D RGA with no extra flags.
##
## Every quantity drawn is asked of library rather than derived beside it:
##
##   |-------------------|-------------------|--------------------------------------------|
##   | Identifier        | Lengyel           | Meaning                                    |
##   |-------------------|-------------------|--------------------------------------------|
##   | 𝐩 ∧ 𝐪             | join              | Line through two points.                   |
##   | 𝐩 ∧ 𝐪 ∧ 𝐫         | join              | Plane through three points.                |
##   | 𝐠 ∨ 𝐡             | meet              | Line where two planes cross.               |
##   | 𝐋 ∨ 𝐠             | meet              | Point where line pierces plane.            |
##   | ∩𝐦                | sup(𝐦)            | Point of object nearest origin.            |
##   | ⊖𝐦                | att(𝐦)            | Direction of object, standing at horizon.  |
##   | (𝐞 ∧ 𝐩) ∨ 𝐠̂       | join, then meet   | Pinhole projection of point onto image.    |
##   |-------------------|-------------------|--------------------------------------------|
##
## Bootstrap order, left to right:
##
##   pga -> objects -> camera -> scene -> visualiser
##   canvas ----------^  ^--------^
##
##   objects reads drawable quantities out of multivectors.
##   canvas owns image space and SVG serialisation, and knows nothing of RGA.
##   camera turns world points into image points, using nothing but joins and meets.
##   scene holds objects to draw and turns each into strokes.
##
## Prototype's shortcuts, each cheap to lift later:
##   Nothing is depth sorted; painting runs by descending grade instead.
##   Segments straddling image plane are dropped rather than clipped against it.
##   Camera is fixed at setup; there is no interaction, and no animation loop.

{.experimental: "strictFuncs".}

when compileOption("profiler"):
  import std/nimprof

import std/[os, strformat]

import ./pga
import ./visualiser/[camera, canvas, objects, scene]



#[ Demonstration Scene ]#

proc constructScene(): Scene =
  ## Construct scene whose every object but three seeds is derived by RGA operator.
  let
    point_a = toMultivector(Position(x: 3.0, y: -2.0, z: 0.5))
    point_b = toMultivector(Position(x: -2.5, y: 2.0, z: 3.5))
    point_c = toMultivector(Position(x: 1.0, y: 4.0, z: 1.0))

  # Join seeds, so every derived object below is built out of them alone.
  let
    ground = (
      toMultivector(Position(x: 0, y: 0, z: 0)) ∧
      toMultivector(Position(x: 1, y: 0, z: 0)) ∧
      toMultivector(Position(x: 0, y: 1, z: 0))
    )
    line_ab = point_a ∧ point_b
    plane_abc = point_a ∧ point_b ∧ point_c

  # Meet derived objects, to recover objects they share.
  let
    line_crease = ground ∨ plane_abc
    point_pierce = line_ab ∨ ground

  result.addItem(ground, "ground = 𝐨 ∧ 𝐱 ∧ 𝐲", Ink.Lime)
  result.addItem(plane_abc, "𝐆 = 𝐚 ∧ 𝐛 ∧ 𝐜", Ink.Teal)
  result.addItem(line_ab, "𝐋 = 𝐚 ∧ 𝐛", Ink.Cyan)
  result.addItem(line_crease, "𝐋′ = ground ∨ 𝐆", Ink.Violet)
  result.addItem(point_a, "𝐚", Ink.Amber)
  result.addItem(point_b, "𝐛", Ink.Amber)
  result.addItem(point_c, "𝐜", Ink.Amber)
  result.addItem(point_pierce, "𝐩 = 𝐋 ∨ ground", Ink.Coral)
  result.addItem(∩ line_ab, "sup(𝐋) = 𝐋∩", Ink.Coral)
  result.addItem(⊖ line_ab, "att(𝐋) = ⊖𝐋", Ink.Rose)



#[ Entry Point ]#

proc main() =
  ## Render demonstration scene to SVG document named by first argument.
  const PATH_DEFAULT = "rga_visualisation.svg"
  let
    path = if paramCount() >= 1: paramStr(1) else: PATH_DEFAULT
    camera = initCamera(
      eye = Position(x: 15.0, y: 12.0, z: 9.0),
      target = Position(x: 0.0, y: 0.0, z: 1.0),
      up = Direction(x: 0.0, y: 0.0, z: 1.0),
    )
    scene = constructScene()

  var canvas = openCanvas(path)
  let tally = canvas.drawScene(camera, scene)
  canvas.closeCanvas

  echo &"Wrote `{path}`: {tally[Placement.Finite]} objects drawn, " &
    &"{tally[Placement.Horizon]} at horizon, {tally[Placement.Hidden]} out of view."

main()
