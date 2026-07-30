## Mobjects ("mathematical objects" in manim parlance) are the visible
## things in a scene: shapes, text, groups, and freeform bezier paths.
##
## A single variant type (`Mobject`) is used for every shape kind instead of
## a class hierarchy, which keeps the whole package to a handful of files
## and avoids Nim's more awkward corners around inheritance + copying.

import cairo
import ./core

type
  MobjectKind* = enum
    mkCircle, mkSquare, mkRectangle, mkLine, mkPolygon, mkArc, mkText,
    mkGroup, mkPath

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
    fontFamily*: string                # mkText
    fontSize*: float                   # mkText, in scene units

    submobjects*: seq[Mobject]         # mkGroup

    pathStart*: Point2                 # mkPath, relative to center
    pathSegs*: seq[PathSeg]            # mkPath, points relative to center
    pathClosed*: bool                  # mkPath

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
              fontFamily: string = "sans-serif"): Mobject =
  result = defaultMobject(mkText)
  result.text = text
  result.fontSize = fontSize
  result.center = center
  result.fillColor = color
  result.strokeColor = color
  result.fillOpacity = 1.0
  result.strokeOpacity = 0.0
  result.fontFamily = fontFamily

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

# ---------------------------------------------------------------------------
# Boundary sampling, used by the `transform` animation to morph one shape
# into another regardless of what kind each one is.
# ---------------------------------------------------------------------------

proc getBoundaryPoints*(m: Mobject, n: int): seq[Point2] =
  ## Returns `n` points (absolute scene coordinates) approximating the
  ## outline of `m`, honoring its current rotation/scale.
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
  of mkText, mkGroup:
    # Not meaningfully "morphable" into a point cloud; callers should fall
    # back to a cross-fade instead (see animation.nim).
    for i in 0..<n:
      result.add(m.center)

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
  of mkText:
    cr.selectFontFace(m.fontFamily.cstring, FontSlantNormal, FontWeightNormal)
    cr.setFontSize(m.fontSize * m.scaleFactor * pixelsPerUnit)
    var extents: TextExtents
    cr.textExtents(m.text.cstring, addr extents)
    let c = mapPt(m.center)
    let x = c.x - extents.width / 2.0 - extents.xBearing
    let y = c.y - extents.height / 2.0 - extents.yBearing
    cr.moveTo(x, y)
    cr.setSourceRgba(m.fillColor.r, m.fillColor.g, m.fillColor.b,
                      m.fillColor.a * m.fillOpacity)
    cr.showText(m.text.cstring)
  of mkGroup:
    discard # handled above
