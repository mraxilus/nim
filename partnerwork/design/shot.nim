## Screenshot one marks page, light and dark, full length.
##
##   The animations only exist in a browser, so a still build passing says
##     nothing about them; this is the cheap half of checking they run (take
##     two shots a moment apart and diff them for the expensive half).
##   Compiled to javascript and run under node, so the workbench stays one
##     language:
##       nim js --hints:off -d:nodejs -o:design/shot.js design/shot.nim
##       node design/shot.js design/frames.html /tmp/frames
##     Cost of the port: a page of foreign-function glue for thirty lines of
##       work.  Accepted -- one language in the repo is worth a page.
##   Chromium and playwright are pre-installed in the remote environment at
##     the paths below; elsewhere, point the two constants at your own.

{.experimental: "strictFuncs".}

import std/[asyncjs, jsffi]


const
  PLAYWRIGHT = "/opt/node22/lib/node_modules/playwright"
  CHROMIUM = "/opt/pw-browsers/chromium-1194/chrome-linux/chrome"


proc require(module: cstring): JsObject {.importjs: "require(#)".}
  ## Load a node module; the compiler has no reason to know what is inside.

var process {.importjs: "process", nodecl.}: JsObject
  ## The node process, for its command line.

proc resolve(path: cstring): cstring {.importjs: "require('path').resolve(#)".}
  ## Make a path absolute, as a file url needs.

proc jsString(s: JsObject): cstring {.importjs: "String(#)".}
  ## Read a javascript value as the string it already is.

proc gotoUrl(page: JsObject; url: cstring): JsObject {.importjs: "#.goto(#)".}
  ## Navigate a page; `goto` is a reserved word the bridge would mangle.


proc shoot() {.async.} =
  ## Open the page in each theme and write one full-length screenshot.
  let
    page_file = jsString(process.argv[2])
    prefix = jsString(process.argv[3])
    url = cstring("file://" & $resolve(page_file))
    chromium = require(PLAYWRIGHT).chromium
    browser = await chromium.launch(
      JsObject{executablePath: cstring(CHROMIUM)}).to(Future[JsObject])
  for theme in ["light", "dark"]:
    let page = await browser.newPage(JsObject{
      viewport: JsObject{width: 1000, height: 900},
      colorScheme: cstring(theme),
    }).to(Future[JsObject])
    discard await gotoUrl(page, url).to(Future[JsObject])
    discard await page.waitForTimeout(300).to(Future[JsObject])
    discard await page.screenshot(JsObject{
      path: cstring($prefix & "-" & theme & ".png"),
      fullPage: true,
    }).to(Future[JsObject])
    discard await page.close().to(Future[JsObject])
  discard await browser.close().to(Future[JsObject])


discard shoot()
