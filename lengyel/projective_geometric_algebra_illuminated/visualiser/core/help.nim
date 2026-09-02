## Say what every gesture, button and key in this visualiser does, once, for both UIs.
##
## Desktop wrote this in its panel and browser in hint that vanished after four seconds;
## two had drifted. Both render this table, so control gaining binding is described in one
## place or in neither.
##
## Entries name *user's* action and its outcome, in reader's words, not handler: "drag one
## object onto another", not "pointerdown then pointermove". Binding derived from rule
## stated elsewhere is read from there: `lut_help_entries` builds construct rows out of
## `interaction.armingOf`, so rebinding button rewrites help.
##
## **Every row has to make sense with rows above it covered up**: reader opens one tab,
## finds line they need, leaves. Three failures, found by reading rendered panel cold:
## circular ("drag one object onto another" → "make whatever the two of them make"),
## leaning on neighbour ("the same choice, without needing the other button"), naming
## internals reader never met ("the apply section", "dolly"). What row cannot carry (which
## menu, what wedge is) goes in `descriptionOf`.
##
## One word, one meaning: objects are **selected**, operations are **chosen**.
##
## **Cut by how reader is working, not by what control is.** Reader opens this mid-task,
## and only that task's rows are of use. `HelpPath` is axis, one tab per path, and
## `ENTRIES_MAX_PATH` holds each tab to what fits phone without scrolling. Table grew from
## 18 entries to 39 while its header claimed everything fit one popup; compile-time cap now
## fails build over that drift.
##
## Shared between desktop (`visualiser.nim`) and browser (`browser_bridge.nim`) render
## paths; see `visualiser.nim`'s "Render Paths" table.

{.experimental: "strictFuncs".}

import std/[options, strutils]

import ./[interaction, scene]



#[ Type Definitions ]#

const ENTRIES_MAX_PATH_CATALOGUE* = COUNT_OPERATION
  ## Bound `operations` path at exactly size of catalogue it lists.
  ##   Not height: this tab *is* catalogue, one row per operation, and only bound worth
  ## checking is that it holds every one. It scrolls on any screen; reference list read by
  ## lookup.

const ENTRIES_MAX_PATH_KEYS* = 12
  ## Bound how many entries `keys` path may hold, checked at compile time.
  ##   Larger than other paths': measurement below found this one tab not worth fitting
  ## 320-pixel viewport, since it describes keyboard and viewport that size is phone.
  ## Bound stays so tab cannot grow unnoticed; 8 rows to 11 with movement keys was
  ## deliberate raise.

const ENTRIES_MAX_PATH* = 8
  ## Bound how many entries any other path may hold, checked at compile time.
  ##   Proxy: real constraint is *rendered height*, and count is what compile time checks.
  ## **Measured**: built page driven at 320x568 (iPhone SE), each tab asked how far its
  ## rows overflow box given, with description above them:
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
  ##   **`select` scrolls by one row; trade taken.** Menu on right button gave it two rows
  ## teaching bindings reader cannot discover otherwise. Shortening tried first: shift per
  ## button cost 125 px, folding into one row recovered 77, trimming outcomes recovered
  ## nothing.
  ##   `drag`'s 4 px is drift in measuring environment; rows untouched.
  ##   **`keys` scrolls and is left scrolling.** Fitting eleven rows means every outcome
  ## under ~39 characters, which costs real bindings (`enter`'s "hold shift to add it").
  ## Wrong trade for keyboard tab serving phone.
  ##   Other five fit *exactly*, two only after descriptions were cut (`drag` four lines to
  ## two, `panel` two to one, ~17 px each). **Count of rows is not count of lines**; path
  ## nearing cap prompts re-measurement, never trust in number.
  ##   Cap is bound that forces question to be asked again, not promise nothing scrolls.
  ## Splitting path is nearly always better than raising; not here: regrouping keyboard
  ## rows onto tabs whose work they do left `camera` 133 px over and `select` 66 px over.

type
  HelpPath* {.pure.} = enum ## Group entries by which way of working they belong to.
    ## What reader is in middle of when opening help. Ordered as reader meets them: drag is
    ## what visualiser is for, keys are accelerator.
    Drag, ## Building one object out of two by dragging between them.
    Select, ## Saying which objects to work on.
    Menu, ## What menu beside selection offers.
    Panel, ## Panel and buttons above it.
    Camera, ## Moving view.
    Keys, ## Keyboard.
    Operations, ## What every operation in catalogue is called.

  HelpEntry* = object ## Hold one thing reader can do and what it does.
    path*: HelpPath ## Way of working it belongs to, and so tab it appears under.
    action*: string ## What reader does.
    outcome*: string ## What happens when they do it.
    is_touch*: bool ## Whether this is touch way rather than pointer way. Both always
      ## listed: laptop with touchscreen is one device, and hiding either behind guess
      ## about hardware leaves reader believing gesture does not exist.


func titleOf*(path: HelpPath): string =
  ## Name one tab as reader would say what they are doing.
  case path
  of HelpPath.Drag: "drag"
  of HelpPath.Select: "select"
  of HelpPath.Menu: "menu"
  of HelpPath.Panel: "panel"
  of HelpPath.Camera: "camera"
  of HelpPath.Keys: "keys"
  of HelpPath.Operations: "operations"


func descriptionOf*(path: HelpPath): string =
  ## Say in one sentence what tab is about, for line above its rows.
  ##   Row stands on its own only so far: "the … wedge" and "the apply section" name things
  ## met *inside* one way of working, and `menu` rows name five buttons without saying
  ## which menu. Context stated once, above rows, for reader who has just opened this tab.
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



#[ Entry Table ]#

func nameOf(button: PointerButton): string =
  ## Name mouse button as reader would say it.
  toLowerAscii($button)


const lut_help_entries* = block:
  ## Every entry two UIs render, grouped by path and in order reader meets them.
  ##   Fixed array with `count` asserted against length at compile time, so adding entry
  ## without resizing fails build rather than leaving blank row. Size is hand-written rows
  ## plus catalogue, which is generated.
  ##   Entries of one path are written together, asserted below: both front-ends walk this
  ## once in order, so split path renders as two tabs of same name.
  var lut: array[39 + COUNT_OPERATION, HelpEntry]
  var count = 0
  proc add(path: HelpPath; action, outcome: string; is_touch = false) =
    lut[count] = HelpEntry(
      path: path, action: action, outcome: outcome, is_touch: is_touch
    )
    inc count

  # Which button asks and which decides is `interaction.armingOf`'s to say. Walked in
  #   reading order rather than `PointerButton`'s physical left, middle, right.
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
  # Touch alone, now that mouse decides by button; see `MenuArming`.
  add(
    HelpPath.Drag, "pause on the target mid-drag",
    "open the wheel without needing a second button", is_touch = true,
  )
  add(
    HelpPath.Drag, "the … wedge",
    "hand both objects to the apply picker, which lists every operation",
  )

  # Which button brings menu is `interaction.revealsMenuOn`'s to say, as drag rows read
  #   `armingOf`.
  #   **Shift gets one row, not one per button.** All four combinations measured 125 px
  #   over box 320-pixel phone gives this tab, and shift means same thing whichever button.
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
  # Menu beside selection. Own tab rather than tail of `select`: ten rows on phone wrap
  #   and scroll.
  add(HelpPath.Menu, "apply", "run any operation on what you selected")
  add(HelpPath.Menu, "edit", "change the selected object's name, colour or coordinates")
  add(HelpPath.Menu, "hide", "keep the selection but stop drawing it")
  add(HelpPath.Menu, "delete", "remove the selection from the scene")
  add(HelpPath.Menu, "✕", "clear the selection and close this menu")

  # Named by button rather than by where it sits: `add` and toggles are in desktop's top
  #   bar and browser's chip row, so row naming place is false on one build.
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
  # "empty space", not just "with one finger": finger starting on *object* builds now.
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
  # Read out of `interaction.motionFor` and `interaction.actionFor`, so rebinding key
  #   rewrites its row. Grouped by job, since reader looks for job first; names come from
  #   `nameOf`.
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
  # Whole catalogue, generated: row per operation, named as every picker offers it
  #   (`scene.notationSymbolic`, `scene.notationNamed`). Hand-written list falls behind.
  for operation in Operation:
    add(HelpPath.Operations, notationSymbolic(operation), notationNamed(operation))

  doAssert count == len(lut), "Every help slot must be filled; adjust the array's size."
  lut


func countOf*(path: HelpPath): int =
  ## Count entries one tab holds, for caller sizing or checking one.
  for entry in lut_help_entries:
    if entry.path == path: inc result


static:
  # Two properties front-ends rely on and neither can check for itself.
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
