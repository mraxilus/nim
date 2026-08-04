// Browser-only layer of the RGA Workbench: buffer upload and draw calls, DOM construction,
// event wiring, binary packing through the platform's own facilities, and file download.
//
// Every value shown here comes from the compiled core through an `rga*` call. Nothing in this
// file decides a colour, a label, a grade, an operation, a gesture's meaning or a number's
// formatting; where a rule looks like it lives here, it is reading one that does not.

"use strict";

(function () {
  const canvas = document.getElementById("scene");
  const gl = canvas.getContext("webgl", { antialias: true, alpha: false });
  if (!gl) {
    document.body.innerHTML = "<p style='padding:24px'>WebGL is unavailable in this browser.</p>";
    return;
  }

  // ---- Constants read across the boundary -------------------------------------------------

  const VERTEX_STRIDE = 7;           // position xyz, colour rgba
  const VERTEX_CAPACITY = 16384;     // matches the core's own fixed budget
  const RING_SEGMENTS = 32;
  const SLOT_NONE = -1;

  const duration = rgaAnimationDuration();
  document.documentElement.style.setProperty("--duration", duration + "ms");
  document.documentElement.style.setProperty("--curve", rgaAnimationCurve());

  // ---- GL programs ------------------------------------------------------------------------

  function compile(type, source) {
    const shader = gl.createShader(type);
    gl.shaderSource(shader, source);
    gl.compileShader(shader);
    if (!gl.getShaderParameter(shader, gl.COMPILE_STATUS)) {
      throw new Error(gl.getShaderInfoLog(shader));
    }
    return shader;
  }

  function link(vertexSource, fragmentSource) {
    const program = gl.createProgram();
    gl.attachShader(program, compile(gl.VERTEX_SHADER, vertexSource));
    gl.attachShader(program, compile(gl.FRAGMENT_SHADER, fragmentSource));
    gl.linkProgram(program);
    if (!gl.getProgramParameter(program, gl.LINK_STATUS)) {
      throw new Error(gl.getProgramInfoLog(program));
    }
    return program;
  }

  const sceneProgram = link(
    `attribute vec3 a_position; attribute vec4 a_color; uniform mat4 u_mvp;
     uniform float u_pointSize; varying vec4 v_color;
     void main() {
       gl_Position = u_mvp * vec4(a_position, 1.0);
       gl_PointSize = u_pointSize;
       v_color = a_color;
     }`,
    `precision mediump float; uniform float u_isPoint; varying vec4 v_color;
     void main() {
       // A point is round: the platform draws a square sprite, so the corners are cut. The
       // cut is gated on drawing points, because gl_PointCoord is undefined for any other
       // primitive — a driver that reads it as zero discards every line and triangle.
       if (u_isPoint > 0.5) {
         vec2 offset = gl_PointCoord - vec2(0.5);
         if (dot(offset, offset) > 0.25) discard;
       }
       gl_FragColor = v_color;
     }`
  );
  const overlayProgram = link(
    `attribute vec2 a_position; uniform vec2 u_viewport;
     void main() {
       vec2 ndc = vec2(a_position.x / u_viewport.x * 2.0 - 1.0,
                       1.0 - a_position.y / u_viewport.y * 2.0);
       gl_Position = vec4(ndc, 0.0, 1.0);
     }`,
    `precision mediump float; uniform vec4 u_color;
     void main() { gl_FragColor = u_color; }`
  );

  const sceneUniforms = {
    mvp: gl.getUniformLocation(sceneProgram, "u_mvp"),
    pointSize: gl.getUniformLocation(sceneProgram, "u_pointSize"),
    isPoint: gl.getUniformLocation(sceneProgram, "u_isPoint"),
    position: gl.getAttribLocation(sceneProgram, "a_position"),
    color: gl.getAttribLocation(sceneProgram, "a_color"),
  };
  const overlayUniforms = {
    viewport: gl.getUniformLocation(overlayProgram, "u_viewport"),
    color: gl.getUniformLocation(overlayProgram, "u_color"),
    position: gl.getAttribLocation(overlayProgram, "a_position"),
  };

  // ---- Fixed buffers, allocated once ------------------------------------------------------

  const scratch = {
    points: new Float32Array(VERTEX_CAPACITY * VERTEX_STRIDE),
    lines: new Float32Array(VERTEX_CAPACITY * VERTEX_STRIDE),
    furniture: new Float32Array(VERTEX_CAPACITY * VERTEX_STRIDE),
    triangles: new Float32Array(VERTEX_CAPACITY * VERTEX_STRIDE),
    rings: new Float32Array(256 * 4),
    ringVertices: new Float32Array(RING_SEGMENTS * 2),
    matrix: new Float32Array(16),
    backdrop: new Float32Array(4),
    strip: new Float32Array(rgaPoolCapacity() * 3),
    screen: new Float32Array(2),
  };
  const buffers = {
    points: gl.createBuffer(),
    lines: gl.createBuffer(),
    furniture: gl.createBuffer(),
    triangles: gl.createBuffer(),
    overlay: gl.createBuffer(),
  };

  function upload(buffer, data, count) {
    gl.bindBuffer(gl.ARRAY_BUFFER, buffer);
    gl.bufferData(gl.ARRAY_BUFFER, data.subarray(0, count * VERTEX_STRIDE), gl.DYNAMIC_DRAW);
    gl.enableVertexAttribArray(sceneUniforms.position);
    gl.vertexAttribPointer(sceneUniforms.position, 3, gl.FLOAT, false, VERTEX_STRIDE * 4, 0);
    gl.enableVertexAttribArray(sceneUniforms.color);
    gl.vertexAttribPointer(sceneUniforms.color, 4, gl.FLOAT, false, VERTEX_STRIDE * 4, 12);
  }

  // ---- Rendering --------------------------------------------------------------------------

  rgaBackdropColor(scratch.backdrop);

  function render(nowMs) {
    const ratio = window.devicePixelRatio || 1;
    const width = Math.max(1, Math.floor(canvas.clientWidth * ratio));
    const height = Math.max(1, Math.floor(canvas.clientHeight * ratio));
    if (canvas.width !== width || canvas.height !== height) {
      canvas.width = width;
      canvas.height = height;
    }
    rgaFrame(nowMs, canvas.clientWidth, canvas.clientHeight);

    gl.viewport(0, 0, width, height);
    gl.clearColor(scratch.backdrop[0], scratch.backdrop[1], scratch.backdrop[2], 1);
    gl.enable(gl.DEPTH_TEST);
    gl.depthMask(true);
    gl.clear(gl.COLOR_BUFFER_BIT | gl.DEPTH_BUFFER_BIT);
    gl.enable(gl.BLEND);
    gl.blendFunc(gl.SRC_ALPHA, gl.ONE_MINUS_SRC_ALPHA);

    rgaViewProjection(scratch.matrix);
    gl.useProgram(sceneProgram);
    gl.uniformMatrix4fv(sceneUniforms.mvp, false, scratch.matrix);

    // Mirrors the native renderer's order by hand: furniture, then lines and points, then
    // translucent triangles with depth writes off.
    const furnitureCount = rgaPackFurniture(scratch.furniture);
    gl.lineWidth(rgaLineWidthFurniture());
    gl.uniform1f(sceneUniforms.pointSize, rgaPointSize());
    upload(buffers.furniture, scratch.furniture, furnitureCount);
    gl.drawArrays(gl.LINES, 0, furnitureCount);

    const lineCount = rgaPackLines(scratch.lines);
    gl.lineWidth(rgaLineWidthObject());
    upload(buffers.lines, scratch.lines, lineCount);
    gl.drawArrays(gl.LINES, 0, lineCount);

    const pointCount = rgaPackPoints(scratch.points);
    gl.uniform1f(sceneUniforms.isPoint, 1);
    upload(buffers.points, scratch.points, pointCount);
    gl.drawArrays(gl.POINTS, 0, pointCount);
    gl.uniform1f(sceneUniforms.isPoint, 0);

    const triangleCount = rgaPackTriangles(scratch.triangles);
    gl.depthMask(false);
    upload(buffers.triangles, scratch.triangles, triangleCount);
    gl.drawArrays(gl.TRIANGLES, 0, triangleCount);
    gl.depthMask(true);

    drawRings();
    positionSelectionMenu();
    if (diagnosticsOpen()) refreshDiagnostics();
    requestAnimationFrame(render);
  }

  function drawRings() {
    const count = rgaPackRings(scratch.rings);
    if (count === 0) return;
    const outline = hexToRgb(rgaOutlineHex());
    gl.disable(gl.DEPTH_TEST);
    gl.useProgram(overlayProgram);
    gl.uniform2f(overlayUniforms.viewport, canvas.clientWidth, canvas.clientHeight);
    gl.lineWidth(rgaRingWidth());
    gl.bindBuffer(gl.ARRAY_BUFFER, buffers.overlay);
    gl.enableVertexAttribArray(overlayUniforms.position);
    for (let index = 0; index < count; index += 1) {
      const x = scratch.rings[index * 4];
      const y = scratch.rings[index * 4 + 1];
      const radius = scratch.rings[index * 4 + 2];
      const alpha = scratch.rings[index * 4 + 3];
      for (let step = 0; step < RING_SEGMENTS; step += 1) {
        const angle = (step / RING_SEGMENTS) * Math.PI * 2;
        scratch.ringVertices[step * 2] = x + Math.cos(angle) * radius;
        scratch.ringVertices[step * 2 + 1] = y + Math.sin(angle) * radius;
      }
      gl.bufferData(gl.ARRAY_BUFFER, scratch.ringVertices, gl.DYNAMIC_DRAW);
      gl.vertexAttribPointer(overlayUniforms.position, 2, gl.FLOAT, false, 0, 0);
      gl.uniform4f(overlayUniforms.color, outline[0], outline[1], outline[2], alpha);
      gl.drawArrays(gl.LINE_LOOP, 0, RING_SEGMENTS);
    }
    gl.enable(gl.DEPTH_TEST);
  }

  function hexToRgb(hex) {
    return [
      parseInt(hex.slice(1, 3), 16) / 255,
      parseInt(hex.slice(3, 5), 16) / 255,
      parseInt(hex.slice(5, 7), 16) / 255,
    ];
  }

  // ---- Drawer ------------------------------------------------------------------------------

  const sectionsHost = document.getElementById("sections");
  const sectionBodies = {};
  // Alphabetical, with only `objects` open; the desktop panel carries the same four.
  const SECTION_NAMES = ["apply", "diagnostics", "objects", "view"];

  function buildSections() {
    SECTION_NAMES.forEach((name) => {
      const details = document.createElement("details");
      details.className = "section";
      details.id = "section-" + name;
      if (name === "objects") details.open = true;
      const summary = document.createElement("summary");
      summary.textContent = name;
      const body = document.createElement("div");
      details.appendChild(summary);
      details.appendChild(body);
      sectionsHost.appendChild(details);
      sectionBodies[name] = body;
    });
  }

  function element(tag, className, text) {
    const node = document.createElement(tag);
    if (className) node.className = className;
    if (text !== undefined) node.textContent = text;
    return node;
  }

  function button(label, onClick, className) {
    const node = element("button", "small " + (className || ""), label);
    node.addEventListener("click", onClick);
    return node;
  }

  // ---- apply -------------------------------------------------------------------------------

  const applyState = { isBinary: false, operation: 0, first: SLOT_NONE, second: SLOT_NONE };

  function refreshApply() {
    const body = sectionBodies.apply;
    body.textContent = "";

    const arity = element("div", "row");
    ["unary", "binary"].forEach((word, index) => {
      const wanted = index === 1;
      const control = button(word, () => {
        applyState.isBinary = wanted;
        applyState.operation = rgaOperationAt(wanted, 0);
        refreshApply();
      }, applyState.isBinary === wanted ? "pressed" : "");
      arity.appendChild(control);
    });
    body.appendChild(arity);

    const picker = element("select");
    const count = rgaOperationCount(applyState.isBinary);
    for (let index = 0; index < count; index += 1) {
      const operation = rgaOperationAt(applyState.isBinary, index);
      const option = element("option", null, rgaOperationLabel(operation));
      option.value = String(operation);
      if (operation === applyState.operation) option.selected = true;
      picker.appendChild(option);
    }
    picker.addEventListener("change", () => {
      applyState.operation = Number(picker.value);
    });
    body.appendChild(withName("operation", picker));

    // Operand pickers are what keep this section usable at three or more selected: it can say
    // which two it means, where the floating menu cannot.
    body.appendChild(withName("𝐦", operandPicker("first")));
    if (applyState.isBinary) body.appendChild(withName("𝐧", operandPicker("second")));

    const run = button("apply", () => {
      const first = applyState.first;
      const second = applyState.isBinary ? applyState.second : first;
      if (first === SLOT_NONE) return;
      const derived = rgaApply(applyState.operation, first, second);
      if (derived !== SLOT_NONE) refreshAll();
    });
    body.appendChild(run);
  }

  function operandPicker(which) {
    const picker = element("select");
    const count = rgaItemCount();
    if (applyState[which] === SLOT_NONE && count > 0) {
      applyState[which] = rgaSelectionCount() > (which === "second" ? 1 : 0)
        ? rgaSelectionAt(which === "second" ? 1 : 0)
        : rgaItemSlotAt(0);
    }
    for (let index = 0; index < count; index += 1) {
      const slot = rgaItemSlotAt(index);
      const option = element("option", null, rgaItemLabel(slot));
      option.value = String(slot);
      if (slot === applyState[which]) option.selected = true;
      picker.appendChild(option);
    }
    picker.addEventListener("change", () => { applyState[which] = Number(picker.value); });
    return picker;
  }

  function withName(name, control) {
    const row = element("div", "row");
    const label = element("span", "name", name);
    label.style.minWidth = "72px";
    row.appendChild(label);
    control.classList.add("grow");
    row.appendChild(control);
    return row;
  }

  // ---- objects -----------------------------------------------------------------------------

  function refreshObjects() {
    const body = sectionBodies.objects;
    body.textContent = "";

    const top = element("div", "row");
    const add = button("add", () => {
      rgaSessionStartComposing("new");
      refreshAll();
    });
    add.disabled = rgaSessionIsOpen();
    top.appendChild(add);
    body.appendChild(top);

    if (rgaSessionIsOpen() && !rgaSessionIsEditing()) body.appendChild(sessionRow(SLOT_NONE));

    const count = rgaItemCount();
    for (let index = 0; index < count; index += 1) {
      const slot = rgaItemSlotAt(index);
      body.appendChild(itemRow(slot));
    }
  }

  function itemRow(slot) {
    const host = element("div", "item" + (rgaItemIsVisible(slot) ? "" : " hidden-item"));
    const head = element("div", "row");

    const check = element("input");
    check.type = "checkbox";
    check.checked = rgaIsSelected(slot);
    check.title = "add to the selection, in pick order";
    check.addEventListener("change", () => { rgaSelectToggle(slot); refreshAll(); });
    head.appendChild(check);

    const swatch = element("span", "swatch");
    swatch.style.background = rgaItemColorHex(slot);
    head.appendChild(swatch);

    const name = element("button", "small grow", rgaItemLabel(slot));
    name.style.textAlign = "left";
    name.addEventListener("click", () => { rgaSelectOnly(slot); refreshAll(); });
    head.appendChild(name);

    head.appendChild(button("edit", () => { rgaSessionStartEditing(slot); refreshAll(); }));
    head.appendChild(button(rgaItemIsVisible(slot) ? "hide" : "show", () => {
      rgaSetItemVisible(slot, !rgaItemIsVisible(slot));
      refreshAll();
    }));
    head.appendChild(button("remove", () => { rgaRemoveItem(slot); refreshAll(); }));
    host.appendChild(head);

    // A coefficient reading is data, so it reads in the mono family the style guide names.
    host.appendChild(element(
      "div", "reading mono", rgaItemShapeWord(slot) + ": " + rgaItemCoefficients(slot)
    ));

    if (rgaSessionIsOpen() && rgaSessionIsEditing() && rgaSessionSlot() === slot) {
      host.appendChild(sessionRow(slot));
    }
    return host;
  }

  function sessionRow(slot) {
    const host = element("div");
    const head = element("div", "row");

    const label = element("input");
    label.type = "text";
    label.value = rgaSessionLabel();
    label.className = "grow";
    label.addEventListener("input", () => { rgaSessionSetLabel(label.value); });
    head.appendChild(label);

    const paints = element("select");
    for (let index = 0; index < rgaPaletteCount(); index += 1) {
      const paint = rgaPaletteAt(index);
      const option = element("option", null, rgaPaletteName(paint));
      option.value = String(paint);
      if (paint === rgaSessionPaint()) option.selected = true;
      paints.appendChild(option);
    }
    paints.addEventListener("change", () => { rgaSessionSetPaint(Number(paints.value)); });
    head.appendChild(paints);

    head.appendChild(button("save", () => { rgaSessionSave(); refreshAll(); }));
    head.appendChild(button("✕", () => { rgaSessionCancel(); refreshAll(); }));
    if (slot !== SLOT_NONE) {
      head.appendChild(button(rgaItemIsVisible(slot) ? "hide" : "show", () => {
        rgaSetItemVisible(slot, !rgaItemIsVisible(slot));
        refreshAll();
      }));
      head.appendChild(button("remove", () => {
        rgaSessionCancel();
        rgaRemoveItem(slot);
        refreshAll();
      }));
    }
    host.appendChild(head);
    host.appendChild(element("div", "reading", rgaSessionShapeWord()));
    host.appendChild(coefficientGrid());
    return host;
  }

  function coefficientGrid() {
    // One flexible row per grade, 0 to n; the grade of each element comes from the core, so
    // nothing here hardcodes this build's dimension.
    const host = element("div");
    const rows = [];
    for (let grade = 0; grade <= rgaMaxGrade(); grade += 1) rows.push(element("div", "grade-row"));
    for (let index = 0; index < rgaBasisCount(); index += 1) {
      const cell = element("div", "cell");
      const name = element("label", null, rgaBasisName(index));
      const field = element("input");
      field.type = "text";
      field.className = "coefficient";
      field.value = rgaFormat(rgaSessionCoefficient(index));
      field.addEventListener("change", () => {
        rgaSessionSetCoefficient(index, rgaParseNumber(field.value));
        field.value = rgaFormat(rgaSessionCoefficient(index));
        refreshReadings();
      });
      cell.appendChild(name);
      cell.appendChild(field);
      rows[rgaBasisGrade(index)].appendChild(cell);
    }
    rows.forEach((row) => host.appendChild(row));
    return host;
  }

  function refreshReadings() {
    // A staged edit changes only what the ghost and the session's own reading show.
    const reading = document.querySelector("#section-objects .reading");
    if (reading && rgaSessionIsOpen()) reading.textContent = rgaSessionShapeWord();
  }

  // ---- view --------------------------------------------------------------------------------

  function refreshView() {
    const body = sectionBodies.view;
    body.textContent = "";
    for (let index = 0; index < rgaCameraFieldCount(); index += 1) {
      const field = element("input");
      field.type = "text";
      field.className = "coefficient";
      field.value = rgaFormat(rgaCameraField(index));
      field.addEventListener("change", () => {
        rgaSetCameraField(index, rgaParseNumber(field.value));
        field.value = rgaFormat(rgaCameraField(index));
      });
      body.appendChild(withName(rgaCameraFieldName(index), field));
    }
  }

  // ---- diagnostics -------------------------------------------------------------------------

  let frameCanvas = null;
  let poolCanvas = null;

  function diagnosticsOpen() {
    const section = document.getElementById("section-diagnostics");
    return section && section.open;
  }

  function refreshDiagnosticsPanel() {
    const body = sectionBodies.diagnostics;
    body.textContent = "";
    body.appendChild(element("div", "reading",
      "Browser stand-ins: frame time from animation-frame deltas, JS heap where the browser " +
      "reports it, live pool slots. The native build's arena readings describe that build's " +
      "own allocator and have no browser equivalent worth pretending to."));
    frameCanvas = element("canvas");
    frameCanvas.width = 360;
    frameCanvas.height = 70;
    frameCanvas.style.width = "100%";
    body.appendChild(frameCanvas);
    body.appendChild(element("div", "row mono", "")).id = "frame-reading";
    poolCanvas = element("canvas");
    poolCanvas.width = 360;
    poolCanvas.height = 18;
    poolCanvas.style.width = "100%";
    body.appendChild(poolCanvas);
    body.appendChild(element("div", "row mono", "")).id = "pool-reading";
  }

  function refreshDiagnostics() {
    if (!frameCanvas) return;
    const context = frameCanvas.getContext("2d");
    context.clearRect(0, 0, frameCanvas.width, frameCanvas.height);
    const samples = rgaFrameSampleCount();
    const peak = Math.max(rgaFramePeak(), 1);
    context.strokeStyle = "#00a7a5";
    context.beginPath();
    for (let index = 0; index < samples; index += 1) {
      // Raw and unsmoothed: smoothing hides exactly the rare slow frame this exists for.
      const x = (index / Math.max(samples - 1, 1)) * frameCanvas.width;
      const y = frameCanvas.height - (rgaFrameSampleAt(index) / peak) * frameCanvas.height;
      if (index === 0) context.moveTo(x, y); else context.lineTo(x, y);
    }
    context.stroke();

    const heap = performance.memory ? performance.memory.usedJSHeapSize : 0;
    const frameReading = document.getElementById("frame-reading");
    if (frameReading) {
      frameReading.textContent =
        "frame " + rgaFormat(rgaFrameSampleAt(Math.max(samples - 1, 0))) + " ms" +
        "  peak " + rgaFormat(peak) + " ms" +
        "  mean " + rgaFormat(rgaFrameMean()) + " ms" +
        (heap ? "  heap " + rgaFormat(heap / 1048576) + " MB" : "  heap unavailable");
    }

    // The strip arrives as one buffer of colour triples: no palette rule lives here.
    const poolContext = poolCanvas.getContext("2d");
    const slots = rgaPoolStrip(scratch.strip);
    const cell = poolCanvas.width / slots;
    for (let index = 0; index < slots; index += 1) {
      const r = Math.round(scratch.strip[index * 3] * 255);
      const g = Math.round(scratch.strip[index * 3 + 1] * 255);
      const b = Math.round(scratch.strip[index * 3 + 2] * 255);
      poolContext.fillStyle = "rgb(" + r + "," + g + "," + b + ")";
      poolContext.fillRect(index * cell, 0, Math.max(cell - 1, 1), poolCanvas.height);
    }
    const poolReading = document.getElementById("pool-reading");
    if (poolReading) {
      poolReading.textContent =
        "pool " + rgaPoolActive() + " active  " + (rgaPoolCapacity() - rgaPoolActive()) + " free";
    }
  }

  // ---- Floating selection menu --------------------------------------------------------------

  const selectionMenu = document.getElementById("selection-menu");
  const picker = document.getElementById("picker");
  const pickerSelect = document.getElementById("picker-select");
  const menuApply = document.getElementById("menu-apply");
  const menuEdit = document.getElementById("menu-edit");
  const menuHide = document.getElementById("menu-hide");
  const menuDelete = document.getElementById("menu-delete");

  function refreshSelectionMenu() {
    const count = rgaSelectionCount();
    selectionMenu.classList.toggle("open", count > 0);
    if (count === 0) {
      picker.classList.remove("open");
      return;
    }
    // At three or more picked this menu has no operand pickers, so it cannot say which two it
    // would use; the drawer's apply section can, and stays usable.
    menuApply.style.display = count >= 3 ? "none" : "";
    menuEdit.style.display = count === 1 ? "" : "none";
    const showing = !picker.classList.contains("open");
    menuHide.style.display = showing ? "" : "none";
    menuDelete.style.display = showing ? "" : "none";
    menuHide.textContent = rgaSelectionIsEntirelyHidden() ? "show" : "hide";

    const isBinary = rgaSelectionIsBinary();
    pickerSelect.textContent = "";
    const operations = rgaOperationCount(isBinary);
    for (let index = 0; index < operations; index += 1) {
      const operation = rgaOperationAt(isBinary, index);
      const option = element("option", null, rgaOperationLabel(operation));
      option.value = String(operation);
      pickerSelect.appendChild(option);
    }
  }

  function positionSelectionMenu() {
    if (rgaSelectionCount() === 0) return;
    const slot = rgaSelectionAt(0);
    if (!rgaSlotScreen(slot, scratch.screen)) {
      selectionMenu.style.visibility = "hidden";
      return;
    }
    selectionMenu.style.visibility = "visible";
    selectionMenu.style.left = (scratch.screen[0] - selectionMenu.offsetWidth / 2) + "px";
    selectionMenu.style.top = (scratch.screen[1] - 52) + "px";
  }

  menuApply.addEventListener("click", () => {
    if (!picker.classList.contains("open")) {
      picker.classList.add("open");
      refreshSelectionMenu();
      return;
    }
    const derived = rgaApplySelection(Number(pickerSelect.value));
    picker.classList.remove("open");
    if (derived !== SLOT_NONE) refreshAll();
  });
  document.getElementById("menu-back").addEventListener("click", () => {
    picker.classList.remove("open");
    refreshSelectionMenu();
  });
  menuEdit.addEventListener("click", () => {
    const slot = rgaSelectionAt(0);
    rgaSessionStartEditing(slot);
    drawer.classList.add("open");
    document.getElementById("section-objects").open = true;
    refreshAll();
    selectionMenu.classList.remove("open");
    const row = document.querySelector("#section-objects .item");
    if (row) row.scrollIntoView({ block: "center" });
  });
  menuHide.addEventListener("click", () => {
    rgaSetSelectionVisible(rgaSelectionIsEntirelyHidden());
    refreshAll();
  });
  menuDelete.addEventListener("click", () => { rgaRemoveSelected(); refreshAll(); });
  document.getElementById("menu-clear").addEventListener("click", () => {
    rgaSelectClear();
    refreshAll();
  });

  // ---- Chip row ----------------------------------------------------------------------------

  const drawer = document.getElementById("drawer");
  const fileMenu = document.getElementById("menu-file");
  const chips = document.getElementById("chips");

  document.getElementById("chip-drawer").addEventListener("click", () => {
    drawer.classList.toggle("open");
  });
  document.getElementById("chip-undo").addEventListener("click", () => {
    if (rgaUndo()) refreshAll();
  });
  document.getElementById("chip-redo").addEventListener("click", () => {
    if (rgaRedo()) refreshAll();
  });
  document.getElementById("chip-axes").addEventListener("click", (event) => {
    rgaShowAxes(!rgaIsShowingAxes());
    event.currentTarget.setAttribute("aria-pressed", String(rgaIsShowingAxes()));
  });
  document.getElementById("chip-grid").addEventListener("click", (event) => {
    rgaShowGrid(!rgaIsShowingGrid());
    event.currentTarget.setAttribute("aria-pressed", String(rgaIsShowingGrid()));
  });
  document.getElementById("chip-menu").addEventListener("click", (event) => {
    event.stopPropagation();
    fileMenu.classList.toggle("open");
  });

  // The outside-tap listener fires on pointer-down, before a tap resolves on release, so the
  // canvas, the drawer and the chip row are excluded: including the canvas would clear the
  // selection before the gesture that should use it has run.
  document.addEventListener("pointerdown", (event) => {
    if (canvas.contains(event.target)) return;
    if (drawer.contains(event.target)) return;
    if (chips.contains(event.target)) return;
    if (fileMenu.contains(event.target)) return;
    fileMenu.classList.remove("open");
  });

  function refreshChips() {
    document.getElementById("chip-undo").disabled = !rgaCanUndo();
    document.getElementById("chip-redo").disabled = !rgaCanRedo();
  }

  // ---- Files -------------------------------------------------------------------------------

  document.getElementById("file-load-demo").addEventListener("click", () => {
    rgaLoadDemo();
    fileMenu.classList.remove("open");
    refreshAll();
  });

  document.getElementById("file-save-scene").addEventListener("click", () => {
    fileMenu.classList.remove("open");
    download("scene.rgascene", encodeScene());
  });

  document.getElementById("file-save-image").addEventListener("click", () => {
    fileMenu.classList.remove("open");
    canvas.toBlob((blob) => downloadBlob("scene.png", blob));
  });

  document.getElementById("file-load-scene").addEventListener("click", () => {
    fileMenu.classList.remove("open");
    document.getElementById("file-input").click();
  });

  document.getElementById("file-input").addEventListener("change", (event) => {
    const file = event.target.files[0];
    if (!file) return;
    const reader = new FileReader();
    reader.onload = () => {
      if (decodeScene(new DataView(reader.result))) refreshAll();
      else window.alert("That file is not a scene this build can read.");
    };
    reader.readAsArrayBuffer(file);
    event.target.value = "";
  });

  function encodeScene() {
    // The core hands over raw per-item fields; the platform's own binary view does the float
    // encoding, native-endian, rather than the core reinventing IEEE-754.
    const basis = rgaBasisCount();
    const count = rgaRecordCount();
    let size = 4 + 1 + 1 + 4;
    const labels = [];
    for (let index = 0; index < count; index += 1) {
      const label = new TextEncoder().encode(rgaRecordLabel(index));
      labels.push(label);
      size += 3 + label.length + basis * 8;
    }
    const bytes = new Uint8Array(size);
    const view = new DataView(bytes.buffer);
    const magic = rgaFileMagic();
    for (let index = 0; index < magic.length; index += 1) bytes[index] = magic.charCodeAt(index);
    let cursor = magic.length;
    view.setUint8(cursor, rgaFileVersion()); cursor += 1;
    view.setUint8(cursor, basis); cursor += 1;
    view.setUint32(cursor, count, true); cursor += 4;
    for (let index = 0; index < count; index += 1) {
      view.setUint8(cursor, rgaRecordPaint(index)); cursor += 1;
      view.setUint8(cursor, rgaRecordIsVisible(index) ? 1 : 0); cursor += 1;
      view.setUint8(cursor, labels[index].length); cursor += 1;
      bytes.set(labels[index], cursor); cursor += labels[index].length;
      for (let b = 0; b < basis; b += 1) {
        view.setFloat64(cursor, rgaRecordCoefficient(index, b), true);
        cursor += 8;
      }
    }
    return bytes;
  }

  function decodeScene(view) {
    const basis = rgaBasisCount();
    if (view.byteLength < 10) return false;
    const magic = rgaFileMagic();
    for (let index = 0; index < magic.length; index += 1) {
      if (view.getUint8(index) !== magic.charCodeAt(index)) return false;
    }
    let cursor = magic.length;
    if (view.getUint8(cursor) !== rgaFileVersion()) return false;
    cursor += 1;
    if (view.getUint8(cursor) !== basis) return false;
    cursor += 1;
    const count = view.getUint32(cursor, true);
    cursor += 4;
    rgaLoadBegin();
    for (let index = 0; index < count; index += 1) {
      if (cursor + 3 > view.byteLength) return false;
      const paint = view.getUint8(cursor);
      const isVisible = view.getUint8(cursor + 1) !== 0;
      const labelLength = view.getUint8(cursor + 2);
      cursor += 3;
      if (cursor + labelLength + basis * 8 > view.byteLength) return false;
      const label = new TextDecoder().decode(
        new Uint8Array(view.buffer, view.byteOffset + cursor, labelLength)
      );
      cursor += labelLength;
      rgaLoadItem(paint, isVisible, label);
      for (let b = 0; b < basis; b += 1) {
        rgaLoadCoefficient(b, view.getFloat64(cursor, true));
        cursor += 8;
      }
    }
    return rgaLoadCommit();
  }

  function download(name, bytes) {
    downloadBlob(name, new Blob([bytes], { type: "application/octet-stream" }));
  }

  function downloadBlob(name, blob) {
    const url = URL.createObjectURL(blob);
    const anchor = document.createElement("a");
    anchor.href = url;
    anchor.download = name;
    anchor.click();
    URL.revokeObjectURL(url);
  }

  // ---- Pointer input -------------------------------------------------------------------------

  const pointer = {
    isDown: false,
    button: 0,
    startX: 0,
    startY: 0,
    lastX: 0,
    lastY: 0,
    startTime: 0,
    slot: SLOT_NONE,
    movement: 0,
  };
  // The browser numbers its buttons 0, 2, 1; the core numbers them left, right, middle. That
  // translation is the only part of the drag mapping this layer holds.
  const BUTTON_TO_CORE = { 0: 0, 2: 1, 1: 2 };

  canvas.addEventListener("contextmenu", (event) => event.preventDefault());

  canvas.addEventListener("pointerdown", (event) => {
    if (event.pointerType === "touch") return;
    canvas.setPointerCapture(event.pointerId);
    pointer.isDown = true;
    pointer.button = BUTTON_TO_CORE[event.button] !== undefined ? BUTTON_TO_CORE[event.button] : 0;
    pointer.startX = pointer.lastX = event.clientX;
    pointer.startY = pointer.lastY = event.clientY;
    pointer.startTime = performance.now();
    pointer.movement = 0;
    pointer.slot = rgaPick(event.clientX, event.clientY);
  });

  canvas.addEventListener("pointermove", (event) => {
    if (event.pointerType === "touch") return;
    const dx = event.clientX - pointer.lastX;
    const dy = event.clientY - pointer.lastY;
    pointer.lastX = event.clientX;
    pointer.lastY = event.clientY;
    if (!pointer.isDown) {
      rgaSetHover(rgaPick(event.clientX, event.clientY));
      return;
    }
    pointer.movement += Math.abs(dx) + Math.abs(dy);
    if (pointer.slot !== SLOT_NONE) return;  // Dragging from an object derives, not moves.
    if (pointer.button === 0) rgaCameraOrbit(dx, dy);
    else if (pointer.button === 1) rgaCameraPan(dx, dy);
  });

  canvas.addEventListener("pointerup", (event) => {
    if (event.pointerType === "touch") return;
    if (!pointer.isDown) return;
    pointer.isDown = false;
    const elapsed = performance.now() - pointer.startTime;
    const moved = Math.hypot(event.clientX - pointer.startX, event.clientY - pointer.startY);
    if (rgaIsClick(elapsed, moved)) {
      if (pointer.slot === SLOT_NONE) rgaSelectClear();
      else if (event.shiftKey) rgaSelectToggle(pointer.slot);
      else rgaSelectOnly(pointer.slot);
      refreshAll();
      return;
    }
    if (pointer.slot !== SLOT_NONE) {
      const destination = rgaPick(event.clientX, event.clientY);
      if (destination !== SLOT_NONE && destination !== pointer.slot) {
        rgaDrag(pointer.button, pointer.slot, destination);
        refreshAll();
      }
    }
  });

  canvas.addEventListener("wheel", (event) => {
    event.preventDefault();
    rgaCameraDolly(event.deltaY > 0 ? -1 : 1);
  }, { passive: false });

  // ---- Touch input ---------------------------------------------------------------------------

  const touch = {
    startTime: 0,
    startX: 0,
    startY: 0,
    lastX: 0,
    lastY: 0,
    movement: 0,
    slot: SLOT_NONE,
    pressTimer: null,
    pinchDistance: 0,
    pinchX: 0,
    pinchY: 0,
  };

  canvas.addEventListener("touchstart", (event) => {
    event.preventDefault();
    if (event.touches.length === 1) {
      const point = event.touches[0];
      touch.startTime = performance.now();
      touch.startX = touch.lastX = point.clientX;
      touch.startY = touch.lastY = point.clientY;
      touch.movement = 0;
      touch.slot = rgaPick(point.clientX, point.clientY);
      rgaSetHover(touch.slot);
      touch.pressTimer = window.setTimeout(() => {
        if (touch.slot !== SLOT_NONE) {
          rgaSelectOnly(touch.slot);
          refreshAll();
        }
        touch.pressTimer = null;
      }, rgaLongPressDuration());
    } else if (event.touches.length === 2) {
      clearPressTimer();
      touch.pinchDistance = touchDistance(event.touches);
      touch.pinchX = (event.touches[0].clientX + event.touches[1].clientX) / 2;
      touch.pinchY = (event.touches[0].clientY + event.touches[1].clientY) / 2;
    }
  }, { passive: false });

  canvas.addEventListener("touchmove", (event) => {
    event.preventDefault();
    if (event.touches.length === 1) {
      const point = event.touches[0];
      const dx = point.clientX - touch.lastX;
      const dy = point.clientY - touch.lastY;
      touch.lastX = point.clientX;
      touch.lastY = point.clientY;
      touch.movement += Math.abs(dx) + Math.abs(dy);
      if (touch.movement > 12) clearPressTimer();
      rgaCameraOrbit(dx, dy);
    } else if (event.touches.length === 2) {
      const distance = touchDistance(event.touches);
      const centreX = (event.touches[0].clientX + event.touches[1].clientX) / 2;
      const centreY = (event.touches[0].clientY + event.touches[1].clientY) / 2;
      if (touch.pinchDistance > 0) {
        rgaCameraDolly((distance - touch.pinchDistance) / 40);
      }
      rgaCameraPan(centreX - touch.pinchX, centreY - touch.pinchY);
      touch.pinchDistance = distance;
      touch.pinchX = centreX;
      touch.pinchY = centreY;
    }
  }, { passive: false });

  canvas.addEventListener("touchend", (event) => {
    event.preventDefault();
    const wasPressPending = touch.pressTimer !== null;
    clearPressTimer();
    if (event.touches.length === 0) {
      const elapsed = performance.now() - touch.startTime;
      if (wasPressPending && rgaIsTap(elapsed, touch.movement)) {
        // A tap toggles only once a selection exists; with nothing selected, selecting is
        // what the long press is for, and a tap on empty space clears.
        if (touch.slot === SLOT_NONE) rgaSelectClear();
        else if (rgaSelectionCount() > 0) rgaSelectToggle(touch.slot);
        refreshAll();
      }
      // Touch has no continuous pointer, so a hover reading would sit stale forever and its
      // ring — only a fifth dimmer than a selection ring — would read as a second selection.
      rgaSetHover(SLOT_NONE);
      touch.pinchDistance = 0;
    }
  }, { passive: false });

  function clearPressTimer() {
    if (touch.pressTimer !== null) {
      window.clearTimeout(touch.pressTimer);
      touch.pressTimer = null;
    }
  }

  function touchDistance(touches) {
    return Math.hypot(
      touches[0].clientX - touches[1].clientX,
      touches[0].clientY - touches[1].clientY
    );
  }

  // ---- Startup ---------------------------------------------------------------------------------

  function refreshAll() {
    refreshApply();
    refreshObjects();
    refreshView();
    refreshChips();
    refreshSelectionMenu();
  }

  function showHint() {
    const hint = document.getElementById("hint");
    hint.textContent =
      "Drag between objects to derive one: left joins, right meets, middle projects. " +
      "One finger orbits, two pinch to zoom and pan; hold to select, tap to add to a selection.";
    // One hand-picked delay, in one place: a stylesheet delay would run from the moment the
    // class is added rather than from load, and the two would stack.
    window.setTimeout(() => hint.classList.add("faded"), 4000);
  }

  rgaInit();
  buildSections();
  refreshDiagnosticsPanel();
  document.getElementById("section-diagnostics").addEventListener("toggle", () => {
    if (diagnosticsOpen()) refreshDiagnosticsPanel();
  });
  document.getElementById("intro").textContent =
    "Drag one object onto another to derive a third: left joins, right meets, middle projects " +
    "orthogonally. Drag empty space to move the camera.";
  refreshAll();
  showHint();
  requestAnimationFrame(render);

  // Exposed for the headless driver, which reads what the page shows rather than what it knows.
  window.rgaPage = { refreshAll, encodeScene, decodeScene };
})();
