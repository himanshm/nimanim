## Font utilities for nimanim: loading arbitrary `.ttf` / `.otf` files via
## FreeType + Cairo's FreeType bridge, and turning text into Cairo path data
## so animations can do real stroke-by-stroke tracing (manim's `Write`).
##
## Background on the README "toy text API" limitation:
##
## Cairo's `select_font_face(family, slant, weight)` is officially called the
## "toy" text API. It only resolves fonts by family name through whatever
## system font backend (fontconfig on Linux, CoreText on macOS, GDI on
## Windows) Cairo was built against. There is no way to point it at a
## specific `.ttf` / `.otf` file on disk.
##
## To lift that limitation, this module:
##
##   1. Loads a font FILE through FreeType (`FT_New_Face`).
##   2. Wraps the FT_Face in a `cairo_ft_font_face_create_for_ft_face`
##      FontFace, which Cairo can then use for any text operation.
##   3. Caches the library + face for the lifetime of the process, keyed
##      by absolute file path, so repeated `newText(..., fontFile=...)`
##      calls with the same path don't re-load.
##
## For text drawn WITHOUT `fontFile` (the default), we use
## `cairo_toy_font_face_create` -- the proper Cairo API for family-name
## fonts -- instead of `cairo_select_font_face`. Behaviour is unchanged
## for existing callers, but we now own the `FontFace` object so it can
## be re-used across draws (cheaper) and swapped at runtime.
##
## Glyph outline access for `write()` / `transform()`:
##
##   `textPath(cr, "hello")` adds the outline of every glyph in "hello"
##   to the current Cairo path. `copyPathFlat(cr)` then returns that path
##   flattened to line segments, which we walk to (a) reveal progressively
##   for stroke-by-stroke Write, and (b) sample N boundary points for
##   shape morphing of text via `transform()`.

import cairo
import ./core
import std/[os, tables]

# ---------------------------------------------------------------------------
# FreeType bindings (only the handful of functions we need). We link against
# libfreetype directly via `{.libfreetype.}` -- the nimanim.nimble file adds
# `--passL: -lfreetype` (and `--passC: -I/usr/include/freetype2`) at build
# time, so end users don't need to install any Nim-level FreeType bindings.
# ---------------------------------------------------------------------------

{.pragma: libfreetype, dynlib: "libfreetype.so".}

# FreeType uses a long pointer to a struct; on 64-bit it's 8 bytes. The
# exact contents don't matter to us -- we just pass the handle around.
type
  FtLibrary* = distinct pointer   ## FT_Library, opaque
  FtFace* = distinct pointer      ## FT_Face, opaque
  FtError* = cint                 ## 0 == success, otherwise an FT_Err_*

# We only need the absolute minimum:
proc ftInitFreeType*(lib: var FtLibrary): FtError
    {.libfreetype, importc: "FT_Init_FreeType".}
proc ftDoneFreeType*(lib: FtLibrary): FtError
    {.libfreetype, importc: "FT_Done_FreeType".}
proc ftNewFace*(lib: FtLibrary, path: cstring, faceIndex: clong,
                face: var FtFace): FtError
    {.libfreetype, importc: "FT_New_Face".}
proc ftDoneFace*(face: FtFace): FtError
    {.libfreetype, importc: "FT_Done_Face".}

# Cairo FreeType bridge: hand an FT_Face to Cairo, get back a Cairo
# FontFace that can be set on a Context via `setFontFace`. This symbol
# lives in libcairo (NOT libfreetype) -- it's part of Cairo's FreeType
# font backend, which is compiled in whenever Cairo is built with FT
# support (the default on Linux).
proc ftFontFaceCreateForFtFace*(face: FtFace, loadFlags: clong): ptr FontFace
    {.importc: "cairo_ft_font_face_create_for_ft_face", dynlib: "libcairo.so.2".}
  ## Creates a `cairo_font_face_t` from an already-loaded FreeType face.
  ## The Cairo FontFace takes a reference on `face`; you must keep `face`
  ## (and the FT_Library it was loaded from) alive for at least as long as
  ## the FontFace is in use, and destroy `face` only after the FontFace
  ## has been destroyed.

# ---------------------------------------------------------------------------
# Cairo bindings for APIs the `cairo` Nim bindings don't expose. These are
# all stable libcairo functions.
# ---------------------------------------------------------------------------

proc toyFontFaceCreate*(family: cstring, slant: FontSlant,
                         weight: FontWeight): ptr FontFace
    {.importc: "cairo_toy_font_face_create", dynlib: "libcairo.so.2".}
  ## The non-deprecated way to build a `FontFace` from a family name.
  ## Equivalent to `select_font_face` but returns a re-usable FontFace
  ## object instead of mutating the current Context.

proc fontFaceDestroy*(face: ptr FontFace)
    {.importc: "cairo_font_face_destroy", dynlib: "libcairo.so.2".}

# ---------------------------------------------------------------------------
# Process-wide cache: one FT_Library, one FontFace per (file, family) key.
# ---------------------------------------------------------------------------

var
  ftLib: FtLibrary = FtLibrary(nil)
  ftLibInitDone = false
  ftFaceCache: Table[string, FtFace] = initTable[string, FtFace]()
  cairoFontFaceCache: Table[string, ptr FontFace] = initTable[string, ptr FontFace]()

proc initFtLib() =
  if ftLibInitDone: return
  var lib: FtLibrary = FtLibrary(nil)
  let rc = ftInitFreeType(lib)
  if rc.cint != 0:
    raise newException(ValueError,
      "FT_Init_FreeType failed (rc=" & $rc.cint & "). " &
      "Is libfreetype installed? `apt-get install libfreetype6-dev`.")
  ftLib = lib
  ftLibInitDone = true

proc loadFontFileFontFace*(fontPath: string): ptr FontFace =
  ## Loads the `.ttf` / `.otf` font at `fontPath`, caches it for the
  ## process lifetime, and returns a Cairo `FontFace` that can be set on
  ## any Context. Returns nil (and raises a clear error) if the file is
  ## missing or not a valid font.
  let absPath = absolutePath(fontPath).expandFilename()
    # ^ expandFilename raises OSError if the file doesn't exist, which
    # gives the caller a clear "no such font file" error.
  if cairoFontFaceCache.hasKey(absPath):
    return cairoFontFaceCache[absPath]
  initFtLib()
  if not ftFaceCache.hasKey(absPath):
    var face: FtFace = FtFace(nil)
    let rc = ftNewFace(ftLib, absPath.cstring, 0, face)
    if rc.cint != 0:
      raise newException(ValueError,
        "Failed to load font file '" & absPath & "' (FT_New_Face rc=" &
        $rc.cint & "). The file may not be a valid TrueType / OpenType font.")
    ftFaceCache[absPath] = face
  let face = ftFaceCache[absPath]
  # loadFlags = 0 means "default". For manim-style rendering this is fine;
  # if we ever need hinting/special metrics we can revisit.
  result = ftFontFaceCreateForFtFace(face, 0.clong)
  if result == nil:
    raise newException(ValueError,
      "cairo_ft_font_face_create_for_ft_face returned nil for '" & absPath & "'.")
  cairoFontFaceCache[absPath] = result

proc loadFamilyFontFace*(family: string, slant: FontSlant = FontSlantNormal,
                          weight: FontWeight = FontWeightNormal): ptr FontFace =
  ## Builds (and caches) a Cairo `FontFace` from a CSS-style family name
  ## like `"sans-serif"` or `"DejaVu Serif"`. Uses Cairo's "toy" font face
  ## API under the hood (the proper Cairo API for this -- NOT the
  ## deprecated `select_font_face` Context mutator that the README flagged
  ## as a limitation).
  let key = family & "\1" & $ord(slant) & "\1" & $ord(weight)
  if cairoFontFaceCache.hasKey(key):
    return cairoFontFaceCache[key]
  result = toyFontFaceCreate(family.cstring, slant, weight)
  if result == nil:
    # Should not happen with Cairo, but be defensive.
    raise newException(ValueError, "cairo_toy_font_face_create returned nil.")
  cairoFontFaceCache[key] = result

# ---------------------------------------------------------------------------
# Path flattening helpers, used by both `write()` (stroke tracing) and
# `transform()` (text morphing) in `mobject.nim` / `animation.nim`.
# ---------------------------------------------------------------------------

type
  PathCmdKind* = enum
    pkMoveTo, pkLineTo, pkCurveTo, pkClosePath

  PathCmd* = object
    kind*: PathCmdKind
    p1*, p2*, p3*: Point2

  FlattenedPath* = object
    ## A flattened (lines-only) representation of a Cairo path: a series of
    ## subpaths, each starting with a moveTo and followed by lineTos.
    ## Stored in absolute pixel coordinates (whatever the Cairo CTM was
    ## when the path was built).
    subpaths*: seq[seq[Point2]]

proc copyPathFlatToSeqs*(cr: ptr Context): FlattenedPath =
  ## Calls `cairo_copy_path_flat` on `cr`'s current path and converts the
  ## result into a more Nim-friendly `FlattenedPath`. Each subpath is one
  ## entry in `subpaths`; closePath segments that close a subpath are
  ## implicitly handled (we add the start point to the end of the
  ## subpath so the line segments form a closed polygon if the original
  ## path was closed).
  ##
  ## The Nim cairo bindings only expose `PathData.x` / `PathData.y` --
  ## not the `header.type` / `header.length` union members needed to walk
  ## the path. We work around this by re-declaring the union locally and
  ## casting the raw pointer.
  ##
  ## `cairo_path_data_t` in C is a union:
  ##   union {
  ##     struct { cairo_path_data_type_t type; int length; } header;
  ##     struct { double x, y; } point;
  ##   };
  ## Both members occupy the same 16-byte slot (4 + 4 padding + 8 + 8).
  ## We model it as a flat record of 16 bytes and reinterpret it on
  ## demand, to avoid Nim's case-object branch restrictions.
  type
    # `cairo_path_data_t` is a 16-byte union:
    #   union {
    #     struct { int type; int length; } header;  // bytes 0-7
    #     struct { double x, y; } point;            // bytes 0-15 (overlaps)
    #   };
    # Both members START at the same address. The header view reads
    # bytes 0-3 (type) and 4-7 (length); the point view reads bytes 0-7
    # (x) and 8-15 (y). We model each view with its own Nim object so
    # the field offsets line up correctly.
    CairoPathHeader = object
      dtype*: cint
      dlen*: cint
      # The union is 16 bytes total; pad the header to match so pointer
      # arithmetic via `UncheckedArray` advances correctly
      # (4 + 4 + 8 = 16 bytes).
      pad0*: float64
    CairoPathPoint = object
      x*, y*: float64
  static:
    doAssert sizeof(CairoPathHeader) == 16 and sizeof(CairoPathPoint) == 16,
      "both views must match the 16-byte cairo_path_data_t union"
  let p: ptr Path = cr.copyPathFlat()
  if p == nil or p.data == nil:
    cr.newPath()
    return
  defer: p.destroy()
  result = FlattenedPath(subpaths: @[])
  var curSubpath: seq[Point2] = @[]
  let n = p.numData.int
  var i = 0
  let baseHdr = cast[ptr UncheckedArray[CairoPathHeader]](p.data)
  let basePt = cast[ptr UncheckedArray[CairoPathPoint]](p.data)
  while i < n:
    let hdr = baseHdr[i]
    let dtype = hdr.dtype
    let dlen = if hdr.dlen > 0: hdr.dlen.int else: 1
    case dtype
    of 0:  # PathMoveTo (header + 1 point)
      if curSubpath.len > 0:
        result.subpaths.add(curSubpath)
      curSubpath = @[(basePt[i + 1].x, basePt[i + 1].y)]
      i += dlen
    of 1:  # PathLineTo (header + 1 point)
      curSubpath.add((basePt[i + 1].x, basePt[i + 1].y))
      i += dlen
    of 2:  # PathCurveTo (header + 3 points; flattened paths shouldn't contain these)
      curSubpath.add((basePt[i + 3].x, basePt[i + 3].y))
      i += dlen
    of 3:  # PathClosePath (header only)
      if curSubpath.len > 0:
        curSubpath.add(curSubpath[0])  # close the loop explicitly
        result.subpaths.add(curSubpath)
        curSubpath = @[]
      i += dlen
    else:
      # Unknown path data type -- skip safely.
      i += dlen
  if curSubpath.len > 0:
    result.subpaths.add(curSubpath)
  cr.newPath()

proc totalLength*(p: FlattenedPath): float =
  ## Sum of segment lengths across all subpaths.
  for sub in p.subpaths:
    for i in 1..<sub.len:
      let dx = sub[i].x - sub[i - 1].x
      let dy = sub[i].y - sub[i - 1].y
      result += sqrt(dx * dx + dy * dy)

proc traceFraction*(p: FlattenedPath, frac: float): FlattenedPath =
  ## Returns a copy of `p` truncated to the first `frac` of total arc
  ## length (0.0 .. 1.0). Each subpath's segments are walked until the
  ## cumulative length reaches `frac * total`; the final segment on the
  ## last subpath is cut exactly at the requested length.
  ##
  ## Used by `write()` to render text outlines stroke-by-stroke: we build
  ## the full glyph-path, flatten it, and at each frame replay only the
  ## first `t` fraction of the total length as a stroke.
  let total = p.totalLength()
  let target = total * clamp(frac, 0.0, 1.0)
  result = FlattenedPath(subpaths: @[])
  if total <= 0.0: return
  var walked = 0.0
  for sub in p.subpaths:
    if sub.len < 2:
      if walked <= target and sub.len > 0:
        result.subpaths.add(@[sub[0]])
      continue
    var newSub: seq[Point2] = @[sub[0]]
    for i in 1..<sub.len:
      let segDx = sub[i].x - sub[i - 1].x
      let segDy = sub[i].y - sub[i - 1].y
      let segLen = sqrt(segDx * segDx + segDy * segDy)
      if walked + segLen <= target:
        newSub.add(sub[i])
        walked += segLen
      else:
        # Partial segment: walk only as far as needed to hit `target`.
        let remaining = target - walked
        if segLen > 1e-9:
          let t = remaining / segLen
          newSub.add((sub[i - 1].x + segDx * t,
                      sub[i - 1].y + segDy * t))
        result.subpaths.add(newSub)
        return result
    result.subpaths.add(newSub)
    if walked >= target: break

proc appendToContext*(p: FlattenedPath, cr: ptr Context) =
  ## Replays a `FlattenedPath` back onto a Cairo Context as a series of
  ## `moveTo` / `lineTo` calls -- i.e. converts it back into a Cairo path
  ## that can then be stroked or filled.
  cr.newPath()
  for sub in p.subpaths:
    if sub.len == 0: continue
    cr.moveTo(sub[0].x, sub[0].y)
    for i in 1..<sub.len:
      cr.lineTo(sub[i].x, sub[i].y)
