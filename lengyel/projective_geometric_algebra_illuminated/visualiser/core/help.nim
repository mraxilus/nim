## Say what every gesture, button and key in this visualiser does, once, for both UIs.
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
## **Cut by how you are working, not by what the control is.** A reader opens this in the
## middle of one thing -- dragging, or choosing, or moving the camera -- and only that
## thing's rows are of any use to them right then. So `HelpPath` is the axis, one tab per
## path, and `ENTRIES_MAX_PATH` holds each tab to what fits a phone without scrolling. The
## table as a whole is under no such bound and no longer pretends to be: it grew from 18
## entries to 26 across three rounds while its own header still claimed everything here fit
## one popup, which is exactly the drift a compile-time cap now fails the build over.
##
## Shared between the desktop (`visualiser.nim`) and browser (`browser_bridge.nim`) render
## paths; see `visualiser.nim`'s own "Render Paths" table.

{.experimental: "strictFuncs".}

import std/[options, strutils]

import ./interaction



#[ Type Definitions ]#

const ENTRIES_MAX_PATH* = 8
  ## Bound how many entries one path may hold, checked at compile time.
  ##   A proxy, and named as one: the real constraint is *rendered height*, and a count is
  ##   what compile time can check. **Measured, not estimated**: the built page is driven
  ##   at 320x568 -- an iPhone SE, the tightest phone worth supporting -- with each tab's
  ##   own rows cloned into it until `scrollHeight` passes `clientHeight`, so the added
  ##   rows wrap exactly as that tab's real ones do. In a 384-pixel-tall rows box:
  ##
  ##   | Path | Rows | Of its own kind that fit |
  ##   |------|------|--------------------------|
  ##   | `drag` | 5 | 7 |
  ##   | `select` | 5 | 10 |
  ##   | `menu` | 5 | 8 |
  ##   | `panel` | 2 | 6 |
  ##   | `camera` | 6 | 10 |
  ##   | `keys` | 8 | 9 |
  ##
  ##   Read the spread, not just the minimum: **a count of rows is not a count of lines.**
  ##   `panel`'s actions are long enough to wrap onto three lines at that width and
  ##   `drag`'s onto two, so eight of *those* would scroll while eight of `keys`' fit with
  ##   a row to spare. Eight is therefore right for the table as it stands and would be
  ##   wrong for a table shaped differently -- a path nearing the cap is a prompt to
  ##   re-run this measurement, not to trust the number.
  ##   Re-measured after the browser panel's columns became a grid sized from the widest
  ##   action rather than a flat 44% (`shell.html`, `.help-rows`). That change is worth
  ##   real width on a 558-pixel panel -- outcomes wrapping went from seven rows to one --
  ##   but bought almost nothing here, where the panel is 262 pixels wide and the long
  ##   actions wrap whatever the column rule is. Hence the cap stays at 8 rather than
  ##   rising: it was the wrapping that improved, not the height at the size that binds.
  ##   It sits exactly at what the largest path holds, deliberately: the next row added to
  ##   a full path fails the build, and the answer is nearly always to split that path
  ##   rather than to raise this. Raising it is a decision about the smallest screen this
  ##   help still works on.

type
  HelpPath* {.pure.} = enum ## Group entries by which way of working they belong to.
    ## What a reader is in the middle of when they open the help, rather than what kind of
    ## control it is. Ordered as a reader meets them: the drag is what the visualiser is
    ## for, and the keys are the accelerator rather than the way in.
    Drag, ## Building one object out of two by dragging between them.
    Select, ## Saying which objects to work on.
    Menu, ## What the menu beside the selection offers.
    Panel, ## The panel and the buttons above it.
    Camera, ## Moving the view.
    Keys, ## Keyboard.

  HelpEntry* = object ## Hold one thing a reader can do and what it does.
    path*: HelpPath ## Way of working it belongs to, and so the tab it appears under.
    action*: string ## What the reader does.
    outcome*: string ## What happens when they do it.
    is_touch*: bool ## Whether this is the touch way of doing it rather than the pointer
      ## way. Both are always listed: a laptop with a touchscreen is one device, and
      ## hiding either set behind a guess about the hardware is how a reader ends up
      ## believing a gesture does not exist.


func titleOf*(path: HelpPath): string =
  ## Name one tab as a reader would say what they are doing.
  case path
  of HelpPath.Drag: "drag"
  of HelpPath.Select: "select"
  of HelpPath.Menu: "menu"
  of HelpPath.Panel: "panel"
  of HelpPath.Camera: "camera"
  of HelpPath.Keys: "keys"



#[ The Table ]#

func nameOf(button: PointerButton): string =
  ## Name a mouse button as a reader would say it.
  toLowerAscii($button)


const lut_help_entries* = block:
  ## Every entry the two UIs render, grouped by path and in the order a reader meets them.
  ##   A fixed array rather than a `seq`, with `count` asserted against its length at
  ## compile time, so adding an entry without resizing fails the build rather than leaving
  ## a blank row at the bottom of the panel.
  ##   Entries of one path are written together, and the assertion below insists they stay
  ## that way: both front-ends walk this once in order, so a path split across two runs
  ## would render as two tabs of the same name.
  var lut: array[31, HelpEntry]
  var count = 0
  proc add(path: HelpPath; action, outcome: string; is_touch = false) =
    lut[count] = HelpEntry(
      path: path, action: action, outcome: outcome, is_touch: is_touch
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
      HelpPath.Drag, nameOf(button) & "-drag one object onto another",
      if is_forced.get: "choose what to make of them"
      else: "make whatever the two of them make",
    )
  add(
    HelpPath.Drag, "drag one object onto another",
    "make whatever the two of them make", is_touch = true,
  )
  add(
    HelpPath.Drag, "hold still over the target",
    "the same choice, without needing the other button",
  )
  add(HelpPath.Drag, "more… in that choice", "hand both objects to the apply section")

  add(HelpPath.Select, "click an object", "choose it alone")
  add(HelpPath.Select, "shift-click an object", "add it to what you have chosen")
  add(HelpPath.Select, "click empty space", "choose nothing, or the sky if one is built")
  add(
    HelpPath.Select, "press and hold an object",
    "choose it; its own outline fills while you hold", is_touch = true,
  )
  add(HelpPath.Select, "tap another object", "add it, once you have chosen one", true)
  # The menu that follows whatever is chosen. Undocumented in either build until now, on
  #   the grounds that it was obvious once you saw it -- but nothing said it was there.
  #   A tab of its own rather than the tail of `select`: ten rows on a phone wrap their
  #   outcomes onto second lines and scroll, which is what this whole round is undoing.
  add(HelpPath.Menu, "apply", "any operation, on the one or two you chose")
  add(HelpPath.Menu, "edit", "rename, recolour or reshape the one you chose")
  add(HelpPath.Menu, "hide", "take everything you chose out of the view")
  add(HelpPath.Menu, "delete", "remove everything you chose")
  add(HelpPath.Menu, "✕", "choose nothing, and put the menu away")

  add(HelpPath.Panel, "add", "a new point you type the coordinates of")
  add(
    HelpPath.Panel, "the apply section",
    "any operation in the catalogue, on the objects you have chosen",
  )

  add(HelpPath.Camera, "drag empty space", "orbit around what you are looking at")
  add(HelpPath.Camera, "right-drag empty space", "pan across")
  add(HelpPath.Camera, "wheel", "dolly in and out")
  # "empty space", not just "with one finger": a finger that starts on an *object* builds
  #   something now, so the unqualified row would send a reader to the wrong gesture.
  add(HelpPath.Camera, "drag empty space with one finger", "orbit", is_touch = true)
  add(HelpPath.Camera, "pinch", "dolly in and out", is_touch = true)
  add(HelpPath.Camera, "drag with two fingers", "pan across", is_touch = true)

  add(HelpPath.Keys, "escape", "abandon whatever is in progress")
  add(HelpPath.Keys, "ctrl+z, ctrl+shift+z", "undo, redo")
  add(HelpPath.Keys, "tab", "step through every control, and through the view itself")
  # Read out of `interaction.actionFor` rather than written here, so rebinding a key
  #   rewrites its own row. Grouped by what they do because a reader looks for the job
  #   first and the key second; the names still come from `nameOf`, one per key.
  add(
    HelpPath.Keys,
    nameOf(Key.Left) & ", " & nameOf(Key.Right) & ", " &
      nameOf(Key.Up) & ", " & nameOf(Key.Down),
    "orbit; hold shift to pan instead",
  )
  add(
    HelpPath.Keys, nameOf(Key.Minus) & ", " & nameOf(Key.Plus), "dolly out and in"
  )
  add(
    HelpPath.Keys, nameOf(Key.BracketLeft) & ", " & nameOf(Key.BracketRight),
    "step to the previous or next object",
  )
  add(
    HelpPath.Keys, nameOf(Key.Enter),
    "choose the object you stepped to; hold shift to add it",
  )
  add(HelpPath.Keys, nameOf(Key.Home), "put the camera back where it started")

  doAssert count == len(lut), "Every help slot must be filled; adjust the array's size."
  lut


func countOf*(path: HelpPath): int =
  ## Count the entries one tab holds, for a caller sizing or checking one.
  for entry in lut_help_entries:
    if entry.path == path: inc result


static:
  # Two properties the front-ends rely on and neither can check for itself.
  var seen: set[HelpPath]
  var path_last = none(HelpPath)
  for entry in lut_help_entries:
    if path_last != some(entry.path):
      doAssert entry.path notin seen,
        "Entries of one help path must be written together, or it renders as two tabs."
      seen.incl(entry.path)
      path_last = some(entry.path)
  for path in HelpPath:
    doAssert path in seen, "Every help path must hold at least one entry: " & titleOf(path)
    doAssert countOf(path) <= ENTRIES_MAX_PATH,
      "Help path `" & titleOf(path) & "` outgrew what fits a phone; split it or raise " &
      "`ENTRIES_MAX_PATH` deliberately."
