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
## `interaction.armingOf`, so rebinding a button rewrites the help with it.
##
## **Every row has to make sense with the rows above it covered up**, because that is how
## this is read: a reader opens one tab, finds the line they need, and leaves. Three ways a
## row failed that, all of them found by reading the rendered panel cold rather than by any
## test -- circular ("drag one object onto another" → "make whatever the two of them
## make"), leaning on its neighbour ("hold still over the target" → "the same choice,
## without needing the other button"), and naming internals a reader has never met ("more…
## in that choice", "the apply section", "dolly in and out"). What a row genuinely cannot
## carry -- which menu this is, what a wedge is -- goes in `descriptionOf` instead.
##
## One word, one meaning: objects are **selected**, operations are **chosen**. "Choose" used
## to do both jobs, which left it saying nothing about which was meant.
##
## **Cut by how you are working, not by what the control is.** A reader opens this in the
## middle of one thing -- dragging, or selecting, or moving the camera -- and only that
## thing's rows are of any use to them right then. So `HelpPath` is the axis, one tab per
## path, and `ENTRIES_MAX_PATH` holds each tab to what fits a phone without scrolling. The
## table as a whole is under no such bound and no longer pretends to be: it grew from 18
## entries to 39 across four rounds while its own header once still claimed everything here
## fit one popup, which is exactly the drift a compile-time cap now fails the build over.
##
## Shared between the desktop (`visualiser.nim`) and browser (`browser_bridge.nim`) render
## paths; see `visualiser.nim`'s own "Render Paths" table.

{.experimental: "strictFuncs".}

import std/[options, strutils]

import ./[interaction, scene]



#[ Type Definitions ]#

const ENTRIES_MAX_PATH_CATALOGUE* = COUNT_OPERATION
  ## Bound the `operations` path at exactly the size of the catalogue it lists.
  ##   Not a height at all, unlike the two bounds below: this tab *is* the catalogue, one
  ##   row per operation, so the only bound worth checking is that it holds every one of
  ##   them and nothing else. It scrolls on any screen and is meant to -- a reference list
  ##   read by looking something up, not by taking it in at a glance.

const ENTRIES_MAX_PATH_KEYS* = 12
  ## Bound how many entries the `keys` path may hold, checked at compile time.
  ##   Its own bound, larger than every other path's, because the measurement below already
  ##   found this the one tab not worth fitting a 320-pixel viewport: it describes a
  ##   keyboard, and a viewport that size is a phone. The bound is still here so the tab
  ##   cannot grow without anyone noticing -- it went from 8 rows to 11 when the movement
  ##   keys arrived, and that was a deliberate raise rather than a silent one.

const ENTRIES_MAX_PATH* = 8
  ## Bound how many entries any other path may hold, checked at compile time.
  ##   A proxy, and named as one: the real constraint is *rendered height*, and a count is
  ##   what compile time can check. **Measured, not estimated**: the built page is driven
  ##   at 320x568 -- an iPhone SE, the tightest phone worth supporting -- and each tab is
  ##   asked how far its own rows overflow the box they are given, with that tab's
  ##   description above them. Re-measured after every row was rewritten to stand on its
  ##   own and a `descriptionOf` line was added above each tab:
  ##
  ##   | Path | Rows | Rows box | Overflow |
  ##   |------|------|----------|----------|
  ##   | `drag` | 5 | 320 px | 4 px |
  ##   | `select` | 7 | 320 px | **48 px** |
  ##   | `menu` | 5 | 219 px | 0 |
  ##   | `panel` | 5 | 328 px | 0 |
  ##   | `camera` | 6 | 314 px | 0 |
  ##   | `keys` | 11 | 320 px | **scrolls; see below** |
  ##
  ##   **`select` now scrolls too, by one row, and that is the trade taken.** Moving the
  ##   menu onto the right button gave it two more rows to carry -- which button reveals,
  ##   and what a right click does with a selection already standing -- and each teaches a
  ##   binding a reader cannot discover any other way. Shortening was tried first: spelling
  ##   shift out per button cost 125 px, folding it into one row recovered 77 of that, and
  ##   trimming the three longest outcomes recovered nothing further, none of them having
  ##   crossed a wrap boundary. What is left is one row of height against one row of
  ##   teaching, on the tightest phone alone.
  ##   `drag`'s 4 px is new since these numbers were first taken while its rows are
  ##   untouched, so it is drift in the measuring environment rather than a change here.
  ##   **`keys` is the other tab that scrolls there, and it is left scrolling.** Its rows
  ##   came to 449 px against a 320 px box when there were eight of them, and there are
  ##   eleven now that the movement keys are bound. Fitting them means every outcome
  ##   under about 39 characters, which costs real bindings -- `enter`'s "hold shift to add
  ##   it" and `escape`'s "one step at a time" are exactly the things a reader cannot
  ##   discover any other way. Paying that on every screen to serve a 320-pixel one is the
  ##   wrong trade for a tab describing a keyboard, since a viewport that size is a phone.
  ##   The other five fit *exactly*, and two of them only after their descriptions were cut
  ##   to fewer wrapped lines: `drag`'s went from four lines to two and `panel`'s from two
  ##   to one, each worth about 17 px. **A count of rows is not a count of lines**, and a
  ##   description is worth a row or two of height -- so a path nearing this cap is a
  ##   prompt to re-run the measurement, never to trust the number.
  ##   What the cap is *not* any more is a promise that nothing scrolls; it is the bound
  ##   that forces the question to be asked again. Raising it is a decision about the
  ##   smallest screen this help still works on, and splitting the path is nearly always
  ##   the better answer -- though not here: regrouping the keyboard rows onto the tabs
  ##   whose work they do was tried and measured, and left `camera` 133 px over and
  ##   `select` 66 px over, which is worse than what it fixed.

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
    Operations, ## What every operation in the catalogue is called.

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
  of HelpPath.Operations: "operations"


func descriptionOf*(path: HelpPath): string =
  ## Say in one sentence what a tab is about, for the line above its rows.
  ##   A row can only stand on its own so far. "the … wedge" and "the apply section"
  ##   name things a reader meets *inside* one way of working, and the `menu` rows name
  ##   five buttons without ever saying which menu they are on or how one gets it -- all
  ##   answerable in a sentence, and unanswerable in a two-column row. So the context that
  ##   would otherwise have to be repeated into every row is stated once, above them.
  ##   Written for a reader who has just opened this tab and nothing else, which is the
  ##   only state this text is ever read in.
  case path
  of HelpPath.Drag:
    "Drag one object onto another to build a new one. Some pairs open a wheel of choices."
  of HelpPath.Select:
    "Say which objects to work on. Whatever is selected wears a white outline."
  of HelpPath.Menu:
    "The small menu that appears beside whatever you just selected."
  of HelpPath.Panel:
    "The panel and the buttons above it."
  of HelpPath.Camera:
    "Move your viewpoint. None of this changes the scene itself."
  of HelpPath.Keys:
    "Keyboard shortcuts. The 3D view needs focus first — press tab until it has it."
  of HelpPath.Operations:
    "Every operation the apply section and the selection menu offer, and what each is " &
    "called."



#[ The Table ]#

func nameOf(button: PointerButton): string =
  ## Name a mouse button as a reader would say it.
  toLowerAscii($button)


const lut_help_entries* = block:
  ## Every entry the two UIs render, grouped by path and in the order a reader meets them.
  ##   A fixed array rather than a `seq`, with `count` asserted against its length at
  ## compile time, so adding an entry without resizing fails the build rather than leaving
  ## a blank row at the bottom of the panel. Its size is the hand-written rows plus the
  ## catalogue, which is generated: adding an operation resizes this on its own.
  ##   Entries of one path are written together, and the assertion below insists they stay
  ## that way: both front-ends walk this once in order, so a path split across two runs
  ## would render as two tabs of the same name.
  var lut: array[39 + COUNT_OPERATION, HelpEntry]
  var count = 0
  proc add(path: HelpPath; action, outcome: string; is_touch = false) =
    lut[count] = HelpEntry(
      path: path, action: action, outcome: outcome, is_touch: is_touch
    )
    inc count

  # Which button asks and which decides is `interaction.armingOf`'s to say, so rebinding
  #   one rewrites its line here rather than leaving this text quietly wrong.
  #   Walked in reading order rather than in `PointerButton`'s own, which runs left, middle,
  #   right by physical position.
  for button in [PointerButton.Left, PointerButton.Right, PointerButton.Middle]:
    let arming = armingOf(button)
    if arming.isNone: continue
    add(
      HelpPath.Drag, nameOf(button) & "-drag one object onto another",
      case arming.get
      of MenuArming.Never: "build the one object those two define, without ever asking"
      of MenuArming.OnDwell: "build that object, or pause on the target to be asked"
      of MenuArming.Always: "open the wheel, whatever the pair would have made on its own",
    )
  add(
    HelpPath.Drag, "drag one object onto another",
    "build the one object those two define", is_touch = true,
  )
  # Touch alone, now that a mouse decides by which button went down; see `MenuArming`.
  add(
    HelpPath.Drag, "pause on the target mid-drag",
    "open the wheel without needing a second button", is_touch = true,
  )
  add(
    HelpPath.Drag, "the … wedge",
    "hand both objects to the apply picker, which lists every operation",
  )

  # Which button brings the menu with it is `interaction.revealsMenuOn`'s to say, exactly as
  #   the drag rows above read `armingOf`, so moving the menu to another button rewrites
  #   these lines rather than leaving them quietly wrong.
  #   **Shift gets one row, not one per button.** Spelling out all four combinations was
  #   measured at 125 px over the box a 320-pixel phone gives this tab -- and shift means
  #   the same thing whichever button it is held with, so four rows were saying one rule
  #   twice. See `ENTRIES_MAX_PATH` on why the answer is fewer rows, not a bigger cap.
  for button in [PointerButton.Left, PointerButton.Right]:
    add(
      HelpPath.Select, nameOf(button) & "-click an object",
      if revealsMenuOn(button): "the same, and open its menu of actions"
      else: "select just that one, dropping anything else",
    )
  add(
    HelpPath.Select, "hold shift as you click",
    "add it, or drop it again if it is already picked",
  )
  add(
    HelpPath.Select, nameOf(PointerButton.Right) & "-click with objects selected",
    "bring their menu back, changing nothing",
  )
  add(
    HelpPath.Select, "click empty space",
    "clear the selection, or pick the sky if there is one",
  )
  add(
    HelpPath.Select, "press and hold an object",
    "select it — its outline fills as you hold", is_touch = true,
  )
  add(
    HelpPath.Select, "tap another object while one is selected",
    "add it to the selection", is_touch = true,
  )
  # The menu beside the selection. Undocumented in either build until recently, on the
  #   grounds that it was obvious once you saw it -- but nothing said it was there.
  #   A tab of its own rather than the tail of `select`: ten rows on a phone wrap their
  #   outcomes onto second lines and scroll, which is what the tab split undid.
  add(HelpPath.Menu, "apply", "run any operation on what you selected")
  add(HelpPath.Menu, "edit", "change the selected object's name, colour or coordinates")
  add(HelpPath.Menu, "hide", "keep the selection but stop drawing it")
  add(HelpPath.Menu, "delete", "remove the selection from the scene")
  add(HelpPath.Menu, "✕", "clear the selection and close this menu")

  # Named by button rather than by where the button sits: `add` and the axes/grid toggles
  #   are in the desktop's top bar and the browser's chip row, so a row naming a place
  #   would be false on one of the two builds.
  add(HelpPath.Panel, "add", "create a point by typing its coordinates")
  add(
    HelpPath.Panel, "the apply section",
    "run any operation in the catalogue on what you selected",
  )
  add(
    HelpPath.Panel, "the objects section",
    "every object in the scene, each with rename, hide and delete",
  )
  add(
    HelpPath.Panel, "save scene, load scene",
    "write the whole scene to a file, or read one back",
  )
  add(
    HelpPath.Panel, "axes, grid",
    "show or hide the reference furniture, leaving the scene alone",
  )

  add(HelpPath.Camera, "drag empty space", "orbit the view around what you are looking at")
  add(HelpPath.Camera, "right-drag empty space", "slide the view sideways and up or down")
  add(HelpPath.Camera, "wheel", "move toward or away from whatever you point at")
  # "empty space", not just "with one finger": a finger that starts on an *object* builds
  #   something now, so the unqualified row would send a reader to the wrong gesture.
  add(
    HelpPath.Camera, "drag empty space with one finger",
    "orbit the view around what you are looking at", is_touch = true,
  )
  add(HelpPath.Camera, "pinch", "move closer in or further out", is_touch = true)
  add(
    HelpPath.Camera, "drag with two fingers",
    "slide the view sideways and up or down", is_touch = true,
  )

  add(
    HelpPath.Keys, "escape", "back out of whatever is part-way through, one step at a time"
  )
  add(HelpPath.Keys, "ctrl+z, ctrl+shift+z", "undo, then redo, the last change to the scene")
  add(HelpPath.Keys, "tab", "move focus between the controls and the 3D view")
  # Read out of `interaction.motionFor` and `interaction.actionFor` rather than written
  #   here, so rebinding a key rewrites its own row. Grouped by what they do because a
  #   reader looks for the job first and the key second; the names still come from
  #   `nameOf`, one per key.
  add(
    HelpPath.Keys,
    nameOf(Key.W) & ", " & nameOf(Key.A) & ", " & nameOf(Key.S) & ", " & nameOf(Key.D),
    "slide the view across the ground; hold " & nameOf(Key.Shift) & " to move faster",
  )
  add(HelpPath.Keys, nameOf(Key.Q) & ", " & nameOf(Key.E), "lower or raise the view")
  add(
    HelpPath.Keys,
    nameOf(Key.Left) & ", " & nameOf(Key.Right) & ", " &
      nameOf(Key.Up) & ", " & nameOf(Key.Down),
    "orbit the view around what you are looking at",
  )
  add(
    HelpPath.Keys, nameOf(Key.Minus) & ", " & nameOf(Key.Plus), "move further out, or closer in"
  )
  add(HelpPath.Keys, nameOf(Key.F), "bring whatever is selected back into view")

  add(
    HelpPath.Keys, nameOf(Key.BracketLeft) & ", " & nameOf(Key.BracketRight),
    "move the highlight to the previous or next object",
  )
  add(
    HelpPath.Keys, nameOf(Key.Enter),
    "select the highlighted object; hold shift to add it",
  )
  add(HelpPath.Keys, nameOf(Key.Home), "put the camera back where it started")
  # The whole catalogue, generated rather than transcribed: a row per operation, each
  #   naming it exactly as every picker in both builds offers it (`scene.notationSymbolic`
  #   and `scene.notationNamed`, the two halves of one split). A hand-written list would
  #   fall behind the catalogue the first time one was added, and nothing would say so.
  for operation in Operation:
    add(HelpPath.Operations, notationSymbolic(operation), notationNamed(operation))

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
    let entries_max =
      case path
      of HelpPath.Operations: ENTRIES_MAX_PATH_CATALOGUE
      of HelpPath.Keys: ENTRIES_MAX_PATH_KEYS
      else: ENTRIES_MAX_PATH
    doAssert countOf(path) <= entries_max,
      "Help path `" & titleOf(path) & "` outgrew what fits a phone; split it or raise " &
      "its own bound deliberately."
