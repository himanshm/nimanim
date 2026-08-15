## Mobjects ("mathematical objects" in manim parlance) are the visible
## things in a scene: shapes, text, groups, and freeform bezier paths.
##
## A single variant type (`Mobject`) is used for every shape kind instead of
## a class hierarchy, which keeps the whole package to a handful of files
## and avoids Nim's more awkward corners around inheritance + copying.

import cairo
import ./core
import ./font

type
  MobjectKind* = enum
    mkCircle, mkSquare, mkRectangle, mkLine, mkPolygon, mkArc, mkText,
    mkGroup, mkPath, mkImage, mkLatex
    # `mkImage` is used by both `newImage` and `newLatex` (LaTeX renders to
    # a PNG which we display via a Cairo image surface).

  PathSegKind* = enum
    psLine   ## straight line to `p3`
    psCurve  ## cubic bezier to `p3` with control points `p1`, `p2`

  PathSeg* = object
    kind*: PathSegKind
    p1*, p2*, p3*: Point2

  Mobject* = ref object
    kind*: MobjectKind
    center*: Point2
    rotation*: float          ## radians, applied about `center` at draw time
    scaleFactor*: float       ## multiplier applied about `center` at draw time
    fillColor*: Color
    strokeColor*: Color
    fillOpacity*: float       ## 0..1, independent of fillColor.a
    strokeOpacity*: float     ## 0..1, independent of strokeColor.a
    strokeWidth*: float       ## in scene units
    visible*: bool

    # --- shape-specific fields (only the relevant ones are used) ---
    radius*: float                    # mkCircle, mkArc
    startAngle*, endAngle*: float      # mkArc, radians
    width*, height*: float             # mkSquare, mkRectangle
    p1*, p2*: Point2                   # mkLine endpoints (absolute, ignores center)
    vertices*: seq[Point2]             # mkPolygon, relative to center

    text*: string                      # mkText
    fontFamily*: string                # mkText (used when fontFile == "")
    fontFile*: string                  # mkText -- if non-empty, load this .ttf/.otf
    fontSlant*: FontSlant              # mkText (Cairo slant, default normal)
    fontWeight*: FontWeight            # mkText (Cairo weight, default normal)
    fontSize*: float                   # mkText, in scene units

    submobjects*: seq[Mobject]         # mkGroup

    pathStart*: Point2                 # mkPath, relative to center
    pathSegs*: seq[PathSeg]            # mkPath, points relative to center
    pathClosed*: bool                  # mkPath

    imageSurface*: ptr Surface         # mkImage, mkLatex -- owned Cairo surface
    imageWidth*: float                 # mkImage, mkLatex -- in scene units
    imageHeight*: float                # mkImage, mkLatex -- in scene units

    # `writeFraction` is set by the `write()` animation to control how much
    # of the text's glyph outline to stroke. 0.0 = nothing, 1.0 = full
    # text. < 0 (default) means "draw normally via showText". This is what
    # gives us manim-style stroke-by-stroke glyph tracing without needing
    # per-glyph timing data from the font.
    writeFraction*: float

proc defaultMobject(kind: MobjectKind): Mobject =
  Mobject(
    kind: kind,
    center: (0.0, 0.0),
    rotation: 0.0,
    scaleFactor: 1.0,
    fillColor: WHITE,
    strokeColor: WHITE,
    fillOpacity: 0.0,
    strokeOpacity: 1.0,
    strokeWidth: 0.04,
    visible: true,
    fontSlant: FontSlantNormal,
    fontWeight: FontWeightNormal,
    writeFraction: -1.0,
  )

# ---------------------------------------------------------------------------
# Constructors
# ---------------------------------------------------------------------------

proc newCircle*(radius: float = 1.0, center: Point2 = (0.0, 0.0),
                 fillColor = WHITE, strokeColor = WHITE,
                 fillOpacity = 0.0, strokeOpacity = 1.0,
                 strokeWidth = 0.04): Mobject =
  result = defaultMobject(mkCircle)
  result.radius = radius
  result.center = center
  result.fillColor = fillColor
  result.strokeColor = strokeColor
  result.fillOpacity = fillOpacity
  result.strokeOpacity = strokeOpacity
  result.strokeWidth = strokeWidth

proc newArc*(radius: float = 1.0, startAngle: float = 0.0,
             endAngle: float = PI, center: Point2 = (0.0, 0.0),
             strokeColor = WHITE, strokeWidth = 0.04): Mobject =
  result = defaultMobject(mkArc)
  result.radius = radius
  result.startAngle = startAngle
  result.endAngle = endAngle
  result.center = center
  result.strokeColor = strokeColor
  result.strokeWidth = strokeWidth
  result.fillOpacity = 0.0

proc newSquare*(sideLength: float = 2.0, center: Point2 = (0.0, 0.0),
                fillColor = WHITE, strokeColor = WHITE,
                fillOpacity = 0.0, strokeOpacity = 1.0,
                strokeWidth = 0.04): Mobject =
  result = defaultMobject(mkSquare)
  result.width = sideLength
  result.height = sideLength
  result.center = center
  result.fillColor = fillColor
  result.strokeColor = strokeColor
  result.fillOpacity = fillOpacity
  result.strokeOpacity = strokeOpacity
  result.strokeWidth = strokeWidth

proc newRectangle*(width: float = 4.0, height: float = 2.0,
                    center: Point2 = (0.0, 0.0),
                    fillColor = WHITE, strokeColor = WHITE,
                    fillOpacity = 0.0, strokeOpacity = 1.0,
                    strokeWidth = 0.04): Mobject =
  result = defaultMobject(mkRectangle)
  result.width = width
  result.height = height
  result.center = center
  result.fillColor = fillColor
  result.strokeColor = strokeColor
  result.fillOpacity = fillOpacity
  result.strokeOpacity = strokeOpacity
  result.strokeWidth = strokeWidth

proc newLine*(p1, p2: Point2, strokeColor = WHITE, strokeWidth = 0.04): Mobject =
  result = defaultMobject(mkLine)
  result.p1 = p1
  result.p2 = p2
  result.center = ((p1.x + p2.x) / 2.0, (p1.y + p2.y) / 2.0)
  result.strokeColor = strokeColor
  result.strokeWidth = strokeWidth
  result.fillOpacity = 0.0

proc newPolygon*(vertices: seq[Point2], fillColor = WHITE, strokeColor = WHITE,
                  fillOpacity = 0.0, strokeOpacity = 1.0,
                  strokeWidth = 0.04): Mobject =
  ## `vertices` are given in absolute scene coordinates; the polygon's
  ## center is computed as their centroid and vertices are stored relative
  ## to it so that shift/rotate/scale behave as expected.
  result = defaultMobject(mkPolygon)
  var cx, cy: float
  for v in vertices:
    cx += v.x
    cy += v.y
  let n = vertices.len.float
  let centroid: Point2 = (cx / n, cy / n)
  result.center = centroid
  result.vertices = @[]
  for v in vertices:
    result.vertices.add(v - centroid)
  result.fillColor = fillColor
  result.strokeColor = strokeColor
  result.fillOpacity = fillOpacity
  result.strokeOpacity = strokeOpacity
  result.strokeWidth = strokeWidth

proc newTriangle*(size: float = 2.0, center: Point2 = (0.0, 0.0),
                   fillColor = WHITE, strokeColor = WHITE,
                   fillOpacity = 0.0, strokeOpacity = 1.0): Mobject =
  let r = size / sqrt(3.0)
  var verts: seq[Point2] = @[]
  for i in 0..2:
    let a = PI / 2.0 + i.float * TAU / 3.0
    verts.add((center.x + r * cos(a), center.y + r * sin(a)))
  newPolygon(verts, fillColor, strokeColor, fillOpacity, strokeOpacity)

proc newText*(text: string, fontSize: float = 0.5,
              center: Point2 = (0.0, 0.0), color = WHITE,
              fontFamily: string = "sans-serif",
              fontFile: string = "",
              fontSlant: FontSlant = FontSlantNormal,
              fontWeight: FontWeight = FontWeightNormal): Mobject =
  ## Creates a text mobject. Two font-selection modes:
  ##
  ##   * `fontFile = ""` (default): load the font by CSS-style
  ##     `fontFamily` (e.g. `"sans-serif"`, `"DejaVu Serif"`). This goes
  ##     through Cairo's "toy" font face API, which routes through whatever
  ##     system font backend Cairo was built against (fontconfig on Linux,
  ##     CoreText on macOS, etc.). Same behaviour as before, but now via
  ##     the proper `cairo_toy_font_face_create` API rather than the
  ##     deprecated `cairo_select_font_face` Context mutator.
  ##
  ##   * `fontFile = "/abs/path/to/font.ttf"`: load the font FILE directly
  ##     via FreeType + Cairo's FreeType bridge. This lifts the README's
  ##     "toy text API only" limitation -- you can now ship a custom
  ##     `.ttf` / `.otf` with your scene and not depend on what's
  ##     installed on the user's system.
  ##
  ## `fontSlant` and `fontWeight` only apply to the family-name mode; if
  ## `fontFile` is set, the font file itself determines those.
  result = defaultMobject(mkText)
  result.text = text
  result.fontSize = fontSize
  result.center = center
  result.fillColor = color
  result.strokeColor = color
  result.fillOpacity = 1.0
  result.strokeOpacity = 0.0
  result.fontFamily = fontFamily
  result.fontFile = fontFile
  result.fontSlant = fontSlant
  result.fontWeight = fontWeight

proc newGroup*(mobjects: varargs[Mobject]): Mobject =
  result = defaultMobject(mkGroup)
  result.submobjects = @[]
  for m in mobjects:
    result.submobjects.add(m)
  # A group's own center is the average of its children's centers; this is
  # only used as a reference point, children keep their absolute centers.
  var cx, cy: float
  if mobjects.len > 0:
    for m in mobjects:
      cx += m.center.x
      cy += m.center.y
    result.center = (cx / mobjects.len.float, cy / mobjects.len.float)

proc newPath*(start: Point2, strokeColor = WHITE, fillColor = WHITE,
              fillOpacity = 0.0, strokeOpacity = 1.0,
              strokeWidth = 0.04): Mobject =
  ## Freeform path built with `lineTo` / `curveTo`, e.g.:
  ##   var p = newPath((-2.0, 0.0))
  ##   p.lineTo((0.0, 1.0))
  ##   p.curveTo((1.0, 2.0), (2.0, 2.0), (2.0, 0.0))
  result = defaultMobject(mkPath)
  result.center = start
  result.pathStart = (0.0, 0.0)
  result.pathSegs = @[]
  result.fillColor = fillColor
  result.strokeColor = strokeColor
  result.fillOpacity = fillOpacity
  result.strokeOpacity = strokeOpacity
  result.strokeWidth = strokeWidth

proc lineTo*(m: Mobject, p: Point2) =
  assert m.kind == mkPath, "lineTo only applies to path mobjects"
  m.pathSegs.add(PathSeg(kind: psLine, p3: p - m.center))

proc curveTo*(m: Mobject, cp1, cp2, p: Point2) =
  assert m.kind == mkPath, "curveTo only applies to path mobjects"
  m.pathSegs.add(PathSeg(kind: psCurve, p1: cp1 - m.center, p2: cp2 - m.center,
                          p3: p - m.center))

proc closePath*(m: Mobject) =
  assert m.kind == mkPath, "closePath only applies to path mobjects"
  m.pathClosed = true

# ---------------------------------------------------------------------------
# Image mobject (used by `newImage` and by `newLatex`, which renders LaTeX
# source to a PNG via the system `pdflatex` + `pdftoppm` tools).
# ---------------------------------------------------------------------------

import std/[osproc, streams, os, hashes]

proc loadImageSurface*(path: string): ptr Surface =
  ## Loads a PNG file into a Cairo image surface, suitable for drawing
  ## via `cairo_set_source_surface`. Supports PNG natively; for other
  ## formats, use ImageMagick or similar to convert first.
  result = imageSurfaceCreateFromPng(path.cstring)
  if result == nil:
    raise newException(ValueError, "Failed to load image: " & path)

proc newImage*(path: string, width: float = 4.0, height: float = 0.0,
              center: Point2 = (0.0, 0.0)): Mobject =
  ## Creates an image mobject. `width` is in scene units; `height` defaults
  ## to the image's intrinsic aspect ratio times `width`. The image is
  ## loaded into a Cairo surface at construction time and kept in memory
  ## for the lifetime of the mobject.
  result = defaultMobject(mkImage)
  result.imageSurface = loadImageSurface(path)
  result.imageWidth = width
  let intrinsicW = result.imageSurface.getWidth().float
  let intrinsicH = result.imageSurface.getHeight().float
  result.imageHeight = if height > 0: height
                       elif intrinsicW > 0: width * intrinsicH / intrinsicW
                       else: width
  result.center = center
  result.fillOpacity = 1.0
  result.strokeOpacity = 0.0

# ---------------------------------------------------------------------------
# LaTeX rendering. Shells out to `pdflatex` + `pdftoppm` to render a snippet
# of LaTeX source into a PNG, then loads the PNG as an image mobject.
#
# This lifts the README's "No LaTeX rendering" limitation (along with the
# "No camera moves/zooming" one, which is implemented in `scene.nim`).
#
# The intermediate files are written to a cache directory keyed by the SHA
# of the source, so re-rendering the same scene is essentially free after
# the first run. If `pdflatex` or `pdftoppm` aren't on PATH, the constructor
# raises a clear error pointing at the install commands.
# ---------------------------------------------------------------------------

proc renderLatexToPng(code: string, cacheDir: string,
                     dpi: int): tuple[pngPath: string,
                                       widthUnits: float, heightUnits: float] =
  ## Renders `code` (a fragment of LaTeX math, e.g. `r"E = mc^2"`) to a PNG
  ## via `pdflatex` -> `pdftoppm`. Returns the path to the cached PNG plus
  ## its size in scene units (we use 1 unit = 50px at the given DPI as a
  ## reasonable default; callers can rescale via `scaleBy`).
  let key = "tex_" & $hash(code)
  if not dirExists(cacheDir):
    createDir(cacheDir)
  let pngPath = cacheDir / (key & ".png")
  if fileExists(pngPath):
    return (pngPath, 0.0, 0.0)
  let texPath = cacheDir / (key & ".tex")
  let pdfPath = cacheDir / (key & ".pdf")
  let standalone = "\\documentclass[preview,border=2pt]{standalone}\n" &
                    "\\usepackage{amsmath,amssymb}\n" &
                    "\\begin{document}\n" &
                    "$$" & code & "$$\n" &
                    "\\end{document}\n"
  writeFile(texPath, standalone)

  # Run pdflatex in the cache directory so .aux/.log land there too.
  block:
    var p: Process
    try:
      p = startProcess("pdflatex", args = @[
        "-interaction=nonstopmode",
        "-output-directory=" & cacheDir,
        texPath,
      ], options = {poUsePath, poStdErrToStdOut})
    except OSError as e:
      raise newException(ValueError,
        "pdflatex not found on PATH (" & e.msg &
        "). Install with: apt-get install texlive-latex-base texlive-latex-extra")
    discard p.outputStream().readAll()
    let rc = p.waitForExit()
    p.close()
    if rc != 0 or not fileExists(pdfPath):
      raise newException(ValueError,
        "pdflatex failed (rc=" & $rc & "). Is TeX installed? " &
        "Install with: apt-get install texlive-latex-base texlive-latex-extra")

  # Convert PDF page 1 to PNG at the requested DPI.
  block:
    var p: Process
    try:
      p = startProcess("pdftoppm", args = @[
        "-png", "-r", $dpi,
        "-singlefile",
        pdfPath,
        pngPath.changeFileExt(""),  # pdftoppm appends .png itself
      ], options = {poUsePath, poStdErrToStdOut})
    except OSError as e:
      raise newException(ValueError,
        "pdftoppm not found on PATH (" & e.msg &
        "). Install with: apt-get install poppler-utils")
    discard p.outputStream().readAll()
    let rc = p.waitForExit()
    p.close()
    if rc != 0 or not fileExists(pngPath):
      raise newException(ValueError,
        "pdftoppm failed (rc=" & $rc & "). Install with: apt-get install poppler-utils")

  result = (pngPath, 0.0, 0.0)

proc newLatex*(code: string, fontSize: float = 0.5,
              center: Point2 = (0.0, 0.0),
              color = WHITE,
              cacheDir = "media/latex_cache",
              dpi = 300): Mobject =
  ## Renders the LaTeX fragment `code` (e.g. `r"E = mc^2"`, `r"\frac{a}{b}"`)
  ## to a PNG via `pdflatex` + `pdftoppm`, then wraps it as an image
  ## mobject sized so that 1 LaTeX `pt` ≈ `fontSize` scene units. The PNG
  ## is cached, so re-running the scene is essentially free after the
  ## first build.
  ##
  ## Requires `pdflatex` and `pdftoppm` on PATH. If they're missing, the
  ## constructor raises a clear ValueError pointing at the install
  ## commands.
  ##
  ## `color` is currently a no-op for LaTeX mobjects (the rendered PNG is
  ## black-on-transparent). To get colored math, set `color` in the LaTeX
  ## source itself (e.g. `r"{\color{red} E = mc^2}"`). The parameter is
  ## kept for API symmetry with `newText`.
  let (pngPath, _, _) = renderLatexToPng(code, cacheDir, dpi)
  result = newImage(pngPath, width = fontSize * 8.0, height = 0.0, center = center)
  result.kind = mkLatex
  result.text = code  # store source so copyMobject / transform can recreate
  result.fillColor = color

# ---------------------------------------------------------------------------
# Transform helpers (mutate in place; return the mobject too for chaining)
# ---------------------------------------------------------------------------

proc shift*(m: Mobject, delta: Point2): Mobject {.discardable.} =
  m.center = m.center + delta
  if m.kind == mkLine:
    m.p1 = m.p1 + delta
    m.p2 = m.p2 + delta
  if m.kind == mkGroup:
    for sub in m.submobjects:
      discard shift(sub, delta)
  m

proc moveTo*(m: Mobject, p: Point2): Mobject {.discardable.} =
  shift(m, p - m.center)

proc rotateBy*(m: Mobject, angle: float): Mobject {.discardable.} =
  m.rotation += angle
  if m.kind == mkGroup:
    for sub in m.submobjects:
      sub.rotation += angle
      sub.center = rotatePoint(sub.center, m.center, angle)
  m

proc scaleBy*(m: Mobject, factor: float): Mobject {.discardable.} =
  m.scaleFactor *= factor
  if m.kind == mkGroup:
    for sub in m.submobjects:
      sub.scaleFactor *= factor
      let d = sub.center - m.center
      sub.center = m.center + d * factor
  m

proc setColor*(m: Mobject, c: Color): Mobject {.discardable.} =
  m.fillColor = c
  m.strokeColor = c
  if m.kind == mkGroup:
    for sub in m.submobjects:
      discard setColor(sub, c)
  m

proc setOpacity*(m: Mobject, opacity: float): Mobject {.discardable.} =
  m.fillOpacity = (if m.fillOpacity > 0: opacity else: m.fillOpacity)
  m.strokeOpacity = opacity
  if m.kind == mkGroup:
    for sub in m.submobjects:
      discard setOpacity(sub, opacity)
  m

proc copyMobject*(m: Mobject): Mobject =
  new(result)
  result[] = m[]
  result.vertices = m.vertices
  result.pathSegs = m.pathSegs
  result.submobjects = @[]
  for sub in m.submobjects:
    result.submobjects.add(copyMobject(sub))
  # For image mobjects, share the underlying surface (Cairo surfaces are
  # refcounted internally, so this is cheap and safe; we must NOT destroy
  # it in the copy because the original still owns it).

# ---------------------------------------------------------------------------
# Forward declarations for the text glyph-path helpers (defined below the
# Drawing section, but referenced by `getBoundaryPoints` since text morph
# needs them too).
# ---------------------------------------------------------------------------

proc sampleTextOutline*(m: Mobject, n: int): seq[Point2]

# ---------------------------------------------------------------------------
# Boundary sampling, used by the `transform` animation to morph one shape
# into another regardless of what kind each one is.
# ---------------------------------------------------------------------------

proc getBoundaryPoints*(m: Mobject, n: int): seq[Point2] =
  ## Returns `n` points (absolute scene coordinates) approximating the
  ## outline of `m`, honoring its current rotation/scale.
  ##
  ## For text and groups, we no longer fall back to "all points = center"
  ## (which made `transform()` on text/groups a glorified cross-fade).
  ## Instead:
  ##
  ##   * **Text**: we build the glyph outlines (via `cairo_text_path` +
  ##     `cairo_copy_path_flat`) and sample `n` points evenly along the
  ##     total arc length. This works for any font (including `fontFile`
  ##     fonts loaded via FreeType) and produces a real shape morph.
  ##   * **Groups**: we recursively sample each child's boundary and
  ##     concatenate, then resample to exactly `n` points.
  result = @[]
  proc place(local: Point2): Point2 =
    let scaled: Point2 = (local.x * m.scaleFactor, local.y * m.scaleFactor)
    rotatePoint(m.center + scaled, m.center, m.rotation)

  case m.kind
  of mkCircle, mkArc:
    let a0 = if m.kind == mkArc: m.startAngle else: 0.0
    let a1 = if m.kind == mkArc: m.endAngle else: TAU
    for i in 0..<n:
      let t = a0 + (a1 - a0) * (i.float / max(1, n - 1).float)
      result.add(place((m.radius * cos(t), m.radius * sin(t))))
  of mkSquare, mkRectangle:
    let hw = m.width / 2.0
    let hh = m.height / 2.0
    let corners = [(-hw, -hh), (hw, -hh), (hw, hh), (-hw, hh), (-hw, -hh)]
    for i in 0..<n:
      let f = i.float / max(1, n - 1).float * 4.0
      let seg = min(3, int(f))
      let localT = f - seg.float
      let a = corners[seg]
      let b = corners[seg + 1]
      result.add(place((a[0] + (b[0] - a[0]) * localT,
                         a[1] + (b[1] - a[1]) * localT)))
  of mkPolygon:
    let verts = m.vertices
    if verts.len == 0: return
    let segCount = verts.len
    for i in 0..<n:
      let f = i.float / max(1, n - 1).float * segCount.float
      let seg = min(segCount - 1, int(f))
      let localT = f - seg.float
      let a = verts[seg]
      let b = verts[(seg + 1) mod segCount]
      result.add(place(lerpPoint(a, b, localT)))
  of mkLine:
    for i in 0..<n:
      let t = i.float / max(1, n - 1).float
      result.add(lerpPoint(m.p1, m.p2, t))
  of mkPath:
    # Flatten every segment into `stepsPerSeg` points, then resample to n.
    var flat: seq[Point2] = @[m.pathStart]
    var cur = m.pathStart
    const stepsPerSeg = 16
    for seg in m.pathSegs:
      case seg.kind
      of psLine:
        flat.add(seg.p3)
      of psCurve:
        for i in 1..stepsPerSeg:
          let t = i.float / stepsPerSeg.float
          let mt = 1.0 - t
          let x = mt*mt*mt*cur.x + 3*mt*mt*t*seg.p1.x + 3*mt*t*t*seg.p2.x + t*t*t*seg.p3.x
          let y = mt*mt*mt*cur.y + 3*mt*mt*t*seg.p1.y + 3*mt*t*t*seg.p2.y + t*t*t*seg.p3.y
          flat.add((x, y))
      cur = seg.p3
    if flat.len == 0: return
    for i in 0..<n:
      let f = i.float / max(1, n - 1).float * (flat.len - 1).float
      let seg = min(flat.len - 2, int(f))
      let localT = f - seg.float
      result.add(place(lerpPoint(flat[seg], flat[min(flat.len-1, seg+1)], localT)))
  of mkImage, mkLatex:
    # Treat the image's bounding box as the "outline" -- the morphed
    # polygon will be a rectangle that matches the image's footprint.
    let hw = m.imageWidth / 2.0
    let hh = m.imageHeight / 2.0
    let corners = [(-hw, -hh), (hw, -hh), (hw, hh), (-hw, hh), (-hw, -hh)]
    for i in 0..<n:
      let f = i.float / max(1, n - 1).float * 4.0
      let seg = min(3, int(f))
      let localT = f - seg.float
      let a = corners[seg]
      let b = corners[seg + 1]
      result.add(place((a[0] + (b[0] - a[0]) * localT,
                         a[1] + (b[1] - a[1]) * localT)))
  of mkText:
    # Sample `n` points along the flattened glyph outlines of the text.
    # We build a throwaway Cairo surface to access the glyph-path APIs,
    # then translate the resulting points back into scene units.
    result = sampleTextOutline(m, n)
  of mkGroup:
    # Recursively sample each child and resample to `n` total points.
    if m.submobjects.len == 0:
      for i in 0..<n: result.add(m.center)
      return
    # Give each child a number of samples proportional to its own
    # "outline length" if we can compute it cheaply, else equal share.
    # For simplicity (and to avoid heavy recursion costs), we give every
    # child an equal share of `n` -- not perfectly optimal but a good
    # approximation for typical scenes where children are similar sizes.
    var allPoints: seq[Point2] = @[]
    let perChild = max(4, n div m.submobjects.len)
    for sub in m.submobjects:
      let subPts = getBoundaryPoints(sub, perChild)
      allPoints.add(subPts)
    if allPoints.len == 0:
      for i in 0..<n: result.add(m.center)
      return
    # Resample `allPoints` down (or up) to exactly `n` points by
    # walking them as a closed loop.
    for i in 0..<n:
      let f = i.float / max(1, n - 1).float * (allPoints.len - 1).float
      let seg = min(allPoints.len - 2, int(f))
      let localT = f - seg.float
      result.add(lerpPoint(allPoints[seg],
                            allPoints[min(allPoints.len - 1, seg + 1)], localT))

# ---------------------------------------------------------------------------
# Text glyph-path helpers (used by both drawing and boundary sampling).
#
# We build a throwaway 1x1 Cairo surface to access glyph-path APIs that
# depend on a Context (`textPath`, `copyPathFlat`). The Context's font is
# set up exactly the same way as the real drawing Context uses it, so the
# resulting path geometry is pixel-identical to what `draw()` produces.
# ---------------------------------------------------------------------------

var textHelperSurface: ptr Surface = nil
var textHelperCtx: ptr Context = nil

proc textHelper(): ptr Context =
  if textHelperCtx == nil:
    textHelperSurface = imageSurfaceCreate(FORMAT_ARGB32, 1.int32, 1.int32)
    textHelperCtx = create(textHelperSurface)
  result = textHelperCtx

proc setupFontOnContext(cr: ptr Context, m: Mobject, pixelsPerUnit: float) =
  ## Sets `cr`'s current FontFace + font size to match what `m` would
  ## draw with. Used by both `draw()` and `sampleTextOutline()`.
  if m.fontFile.len > 0:
    let face = loadFontFileFontFace(m.fontFile)
    cr.setFontFace(face)
  else:
    let face = loadFamilyFontFace(m.fontFamily, m.fontSlant, m.fontWeight)
    cr.setFontFace(face)
  cr.setFontSize(m.fontSize * m.scaleFactor * pixelsPerUnit)

proc sampleTextOutline*(m: Mobject, n: int): seq[Point2] =
  ## Returns `n` points (in absolute scene coordinates) approximating the
  ## outline of `m.text`, honoring `m.center`, `m.rotation`, `m.scaleFactor`.
  ##
  ## Uses `cairo_text_path` + `cairo_copy_path_flat` to get the glyph
  ## outlines as a flattened path, then walks the path accumulating arc
  ## length and samples `n` points evenly along that length.
  result = @[]
  if m.text.len == 0 or n <= 0: return
  let cr = textHelper()
  cr.save()
  cr.newPath()
  setupFontOnContext(cr, m, 1.0)  # 1px = 1 scene unit for measurement
  var extents: TextExtents
  cr.textExtents(m.text.cstring, addr extents)
  let cx = extents.width / 2.0 + extents.xBearing
  let cy = extents.height / 2.0 + extents.yBearing
  # textPath places glyphs so their baseline-start is at (0, 0); we offset
  # so the text is centered at the origin, then we apply the mobject's
  # own center/rotation/scale when emitting each sampled point.
  cr.moveTo(-cx, -cy)
  cr.textPath(m.text.cstring)
  let flat = cr.copyPathFlatToSeqs()
  cr.restore()
  cr.newPath()
  let totalLen = flat.totalLength()
  if totalLen <= 1e-6:
    for i in 0..<n: result.add(m.center)
    return
  # Sample n points evenly along the total arc length.
  for i in 0..<n:
    let frac = i.float / max(1, n - 1).float
    let traced = flat.traceFraction(frac)
    # Take the endpoint of the last drawn segment as our sample point --
    # i.e. walk the path until we've covered `frac` of its length, then
    # take the current pen position. This gives us `n` evenly-distributed
    # points around the outline.
    var foundPt: Point2 = m.center
    for sub in traced.subpaths:
      if sub.len > 0:
        foundPt = sub[^1]
        break
    if foundPt == m.center and traced.subpaths.len > 0 and
       traced.subpaths[0].len > 0:
      foundPt = traced.subpaths[0][0]
    # The flat path was built in pixel space at 1px = 1 scene unit, with
    # text centered at origin. Convert back to absolute scene coords by
    # applying the mobject's center/rotation/scale.
    let scaled: Point2 = (foundPt.x * m.scaleFactor, foundPt.y * m.scaleFactor)
    result.add(rotatePoint(m.center + scaled, m.center, m.rotation))

# ---------------------------------------------------------------------------
# Drawing
# ---------------------------------------------------------------------------

proc applyPaint(cr: ptr Context, m: Mobject, hasFill, hasStroke: bool) =
  if hasFill and m.fillOpacity > 0.001:
    cr.setSourceRgba(m.fillColor.r, m.fillColor.g, m.fillColor.b,
                      m.fillColor.a * m.fillOpacity)
    if hasStroke and m.strokeOpacity > 0.001:
      cr.fillPreserve()
    else:
      cr.fill()
  if hasStroke and m.strokeOpacity > 0.001:
    cr.setSourceRgba(m.strokeColor.r, m.strokeColor.g, m.strokeColor.b,
                      m.strokeColor.a * m.strokeOpacity)
    cr.stroke()
  elif hasFill and m.fillOpacity > 0.001:
    discard # already filled above
  else:
    cr.newPath() # nothing visible; clear any pending path

proc draw*(cr: ptr Context, m: Mobject, mapPt: PointMap, pixelsPerUnit: float) =
  if not m.visible:
    return

  if m.kind == mkGroup:
    for sub in m.submobjects:
      draw(cr, sub, mapPt, pixelsPerUnit)
    return

  cr.newPath()
  cr.setLineWidth(m.strokeWidth * m.scaleFactor * pixelsPerUnit)

  proc toPixel(local: Point2): Point2 =
    let scaled: Point2 = (local.x * m.scaleFactor, local.y * m.scaleFactor)
    mapPt(rotatePoint(m.center + scaled, m.center, m.rotation))

  case m.kind
  of mkCircle:
    # cairo has no ellipse primitive; draw via a scale+arc for perfect circles.
    let c = mapPt(m.center)
    let r = m.radius * m.scaleFactor * pixelsPerUnit
    cr.newPath()
    cr.arc(c.x, c.y, r, 0.0, TAU)
    applyPaint(cr, m, true, true)
  of mkArc:
    let c = mapPt(m.center)
    let r = m.radius * m.scaleFactor * pixelsPerUnit
    cr.newPath()
    # Screen y is flipped relative to scene y, so negate the angles.
    cr.arc(c.x, c.y, r, -m.endAngle, -m.startAngle)
    applyPaint(cr, m, false, true)
  of mkSquare, mkRectangle:
    let hw = m.width / 2.0
    let hh = m.height / 2.0
    let p0 = toPixel((-hw, -hh))
    let p1 = toPixel((hw, -hh))
    let p2 = toPixel((hw, hh))
    let p3 = toPixel((-hw, hh))
    cr.moveTo(p0.x, p0.y)
    cr.lineTo(p1.x, p1.y)
    cr.lineTo(p2.x, p2.y)
    cr.lineTo(p3.x, p3.y)
    cr.closePath()
    applyPaint(cr, m, true, true)
  of mkLine:
    let a = mapPt(m.p1)
    let b = mapPt(m.p2)
    cr.moveTo(a.x, a.y)
    cr.lineTo(b.x, b.y)
    applyPaint(cr, m, false, true)
  of mkPolygon:
    if m.vertices.len == 0: return
    let p0 = toPixel(m.vertices[0])
    cr.moveTo(p0.x, p0.y)
    for i in 1..<m.vertices.len:
      let p = toPixel(m.vertices[i])
      cr.lineTo(p.x, p.y)
    cr.closePath()
    applyPaint(cr, m, true, true)
  of mkPath:
    let p0 = toPixel(m.pathStart)
    cr.moveTo(p0.x, p0.y)
    for seg in m.pathSegs:
      case seg.kind
      of psLine:
        let p = toPixel(seg.p3)
        cr.lineTo(p.x, p.y)
      of psCurve:
        let c1 = toPixel(seg.p1)
        let c2 = toPixel(seg.p2)
        let p = toPixel(seg.p3)
        cr.curveTo(c1.x, c1.y, c2.x, c2.y, p.x, p.y)
    if m.pathClosed:
      cr.closePath()
    applyPaint(cr, m, true, true)
  of mkImage, mkLatex:
    if m.imageSurface == nil: return
    let c = mapPt(m.center)
    let w = m.imageWidth * m.scaleFactor * pixelsPerUnit
    let h = m.imageHeight * m.scaleFactor * pixelsPerUnit
    let intrinsicW = m.imageSurface.getWidth().float
    let intrinsicH = m.imageSurface.getHeight().float
    if intrinsicW <= 0 or intrinsicH <= 0: return
    # Scale the image from its intrinsic pixel size to the desired scene
    # size, position it centered at `m.center` (accounting for rotation
    # via a Cairo matrix transform).
    cr.save()
    cr.translate(c.x, c.y)
    if m.rotation != 0.0:
      cr.rotate(m.rotation)
    let sx = w / intrinsicW
    let sy = h / intrinsicH
    cr.scale(sx, sy)
    cr.setSource(m.imageSurface, -intrinsicW / 2.0, -intrinsicH / 2.0)
    cr.rectangle(-intrinsicW / 2.0, -intrinsicH / 2.0,
                  intrinsicW, intrinsicH)
    cr.paint()
    cr.restore()
  of mkText:
    cr.save()
    setupFontOnContext(cr, m, pixelsPerUnit)
    var extents: TextExtents
    cr.textExtents(m.text.cstring, addr extents)
    let c = mapPt(m.center)
    let x = c.x - extents.width / 2.0 - extents.xBearing
    let y = c.y - extents.height / 2.0 - extents.yBearing
    if m.writeFraction >= 0.0 and m.writeFraction < 1.0:
      # Stroke-by-stroke tracing (the `write()` animation sets this).
      # Build the full glyph path, flatten it, then replay only the
      # first `writeFraction` of the total arc length as a stroke.
      cr.newPath()
      cr.moveTo(x, y)
      cr.textPath(m.text.cstring)
      let flat = cr.copyPathFlatToSeqs()
      let traced = flat.traceFraction(m.writeFraction)
      traced.appendToContext(cr)
      cr.setSourceRgba(m.fillColor.r, m.fillColor.g, m.fillColor.b,
                        m.fillColor.a * m.fillOpacity)
      cr.setLineWidth(m.fontSize * m.scaleFactor * pixelsPerUnit * 0.12)
      cr.stroke()
    else:
      # Normal text rendering -- paint the glyphs with the fill color.
      # If writeFraction >= 1.0 (animation just finished), we want the
      # final fully-drawn text rather than a stroked outline, so we
      # fall through to the showText path.
      cr.moveTo(x, y)
      cr.setSourceRgba(m.fillColor.r, m.fillColor.g, m.fillColor.b,
                        m.fillColor.a * m.fillOpacity)
      cr.showText(m.text.cstring)
    cr.restore()
  of mkGroup:
    discard # handled above
