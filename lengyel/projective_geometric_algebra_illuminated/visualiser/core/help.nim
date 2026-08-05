## Say what every gesture, button and key in this workbench does, once, for both UIs.
##
## The desktop wrote this out in its panel and the browser wrote it out in a hint that
## disappeared after four seconds; the two had already drifted, and only one of them could
## be got back. Both now render this table, so a control that gains a binding is described
## in one place or in neither.
##
## Entries name the *user's* action and its outcome, in the words a reader would use, not
## the handler that implements it -- "drag one object onto another", not "pointerdown then
## pointermove". Where a binding is derived from a rule stated elsewhere, it is read from
## there rather than transcribed: `lut_help_entries` builds its construct rows out of
## `interaction.isMenuForcedBy`, so rebinding a button rewrites the help with it.
##
## Kept deliberately short. A reference a reader has to scroll is one they stop opening,
## and everything here has to fit a popup on a phone.
##
## Shared between the desktop (`visualiser.nim`) and browser (`browser_bridge.nim`) render
## paths; see `visualiser.nim`'s own "Render Paths" table.

{.experimental: "strictFuncs".}

import std/[options, strutils]

import ./interaction



#[ Type Definitions ]#

type
  HelpTopic* {.pure.} = enum ## Group entries under the heading a reader looks for them by.
    Build, ## Deriving new objects from the ones already there.
    Look, ## Moving the camera.
    Choose, ## Selecting, and what a selection is for.
    Keys, ## Keyboard.

  HelpEntry* = object ## Hold one thing a reader can do and what it does.
    topic*: HelpTopic ## Heading it sits under.
    action*: string ## What the reader does.
    outcome*: string ## What happens when they do it.
    is_touch*: bool ## Whether this is the touch way of doing it rather than the pointer
      ## way. Both are always listed: a laptop with a touchscreen is one device, and
      ## hiding either set behind a guess about the hardware is how a reader ends up
      ## believing a gesture does not exist.


func titleOf*(topic: HelpTopic): string =
  ## Head one group as a reader would name it.
  case topic
  of HelpTopic.Build: "build"
  of HelpTopic.Look: "look around"
  of HelpTopic.Choose: "choose"
  of HelpTopic.Keys: "keys"



#[ The Table ]#

func nameOf(button: PointerButton): string =
  ## Name a mouse button as a reader would say it.
  toLowerAscii($button)


const lut_help_entries* = block:
  ## Every entry the two UIs render, in the order a reader meets them: build first,
  ## because that is what the workbench is for; keys last, because they are the
  ## accelerator rather than the way in.
  ##   A fixed array rather than a `seq`, with `count` asserted against its length at
  ## compile time, so adding an entry without resizing fails the build rather than leaving
  ## a blank row at the bottom of the panel.
  var lut: array[26, HelpEntry]
  var count = 0
  proc add(topic: HelpTopic; action, outcome: string; is_touch = false) =
    lut[count] = HelpEntry(
      topic: topic, action: action, outcome: outcome, is_touch: is_touch
    )
    inc count

  # Which button asks and which decides is `interaction.isMenuForcedBy`'s to say, so
  #   rebinding one rewrites its line here rather than leaving this text quietly wrong.
  #   Walked in reading order rather than in `PointerButton`'s own, which runs left, middle,
  #   right by physical position.
  for button in [PointerButton.Left, PointerButton.Right, PointerButton.Middle]:
    let is_forced = isMenuForcedBy(button)
    if is_forced.isNone: continue
    add(
      HelpTopic.Build, nameOf(button) & "-drag one object onto another",
      if is_forced.get: "choose what to make of them"
      else: "make whatever the two of them make",
    )
  add(
    HelpTopic.Build, "drag one object onto another",
    "make whatever the two of them make", is_touch = true,
  )
  add(
    HelpTopic.Build, "hold still over the target",
    "the same choice, without needing the other button",
  )
  add(HelpTopic.Build, "more… in that choice", "hand both objects to the apply section")
  add(
    HelpTopic.Build, "the apply section",
    "any operation in the catalogue, on the objects you have chosen",
  )
  add(HelpTopic.Build, "add", "a new point you type the coordinates of")

  add(HelpTopic.Look, "drag empty space", "orbit around what you are looking at")
  add(HelpTopic.Look, "right-drag empty space", "pan across")
  add(HelpTopic.Look, "wheel", "dolly in and out")
  # "empty space", not just "with one finger": a finger that starts on an *object* builds
  #   something now, so the unqualified row would send a reader to the wrong gesture.
  add(HelpTopic.Look, "drag empty space with one finger", "orbit", is_touch = true)
  add(HelpTopic.Look, "pinch", "dolly in and out", is_touch = true)
  add(HelpTopic.Look, "drag with two fingers", "pan across", is_touch = true)

  add(HelpTopic.Choose, "click an object", "choose it alone")
  add(HelpTopic.Choose, "shift-click an object", "add it to what you have chosen")
  add(HelpTopic.Choose, "click empty space", "choose nothing")
  add(
    HelpTopic.Choose, "press and hold an object",
    "choose it; its own outline fills while you hold", is_touch = true,
  )
  add(HelpTopic.Choose, "tap another object", "add it, once you have chosen one", true)

  add(HelpTopic.Keys, "escape", "abandon whatever is in progress")
  add(HelpTopic.Keys, "ctrl+z, ctrl+shift+z", "undo, redo")
  add(HelpTopic.Keys, "tab", "step through every control, and through the view itself")
  # Read out of `interaction.actionFor` rather than written here, so rebinding a key
  #   rewrites its own row. Grouped by what they do because a reader looks for the job
  #   first and the key second; the names still come from `nameOf`, one per key.
  add(
    HelpTopic.Keys,
    nameOf(Key.Left) & ", " & nameOf(Key.Right) & ", " &
      nameOf(Key.Up) & ", " & nameOf(Key.Down),
    "orbit; hold shift to pan instead",
  )
  add(
    HelpTopic.Keys, nameOf(Key.Minus) & ", " & nameOf(Key.Plus), "dolly out and in"
  )
  add(
    HelpTopic.Keys, nameOf(Key.BracketLeft) & ", " & nameOf(Key.BracketRight),
    "step to the previous or next object",
  )
  add(
    HelpTopic.Keys, nameOf(Key.Enter),
    "choose the object you stepped to; hold shift to add it",
  )
  add(HelpTopic.Keys, nameOf(Key.Home), "put the camera back where it started")

  doAssert count == len(lut), "Every help slot must be filled; adjust the array's size."
  lut
