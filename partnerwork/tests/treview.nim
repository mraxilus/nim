## Test that the review page still says what the model says.
##
## The page is generated, and generated files rot when nobody regenerates them.
## Rebuilding it here and comparing with the committed copy makes a model change
## that has not been written up fail the suite rather than ship quietly.

import std/[options, os, strutils, unittest]

import ../src/partnerwork
import ../tools/review


suite "the review page":
  test "the committed page is what the model renders today":
    check fileExists(PAGE_PATH)
    if renderReview() != readFile(PAGE_PATH):
      checkpoint "doc/review.html is stale; run `nimble review`"
      fail()

  test "every frame has a picture, and it is the one the model draws":
    for target in FRAMES:
      let path = FRAME_DIRECTORY / (target.slug & ".svg")
      check fileExists(path)
      check readFile(path) == renderFrame(target)

  test "the page shows every frame and every move":
    let page = readFile(PAGE_PATH)
    var edges = 0
    for source in FRAMES:
      check page.contains(">" & source.describe & "<")
      edges += moves(source).len
    # One cell per move in the matrix, plus one title per frame in each picture.
    check page.count("<td class=\"on") == edges

  test "the pictures fix no colour of their own":
    # They are shown inside two pages that theme them and as standalone files
    # that cannot be themed, so every ink is a custom property with a fallback
    # and no ink is written down on its own.
    for target in FRAMES:
      let picture = renderFrame(target)
      check picture.count('#') == picture.count("var(--")
      check picture.count('#') > 0

  test "a frame's file name survives its description":
    check fromKey("--.").get.slug == "open"
    check fromKey("l-.").get.slug == "left-to-left"
    check fromKey("lrL").get.slug == "left-to-left-over-right-to-right"
    var slugs: seq[string] = @[]
    for target in FRAMES:
      check target.slug notin slugs
      slugs.add target.slug
