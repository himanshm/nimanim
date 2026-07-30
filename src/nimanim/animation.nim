## Animations describe how a mobject's properties change over the course
## of a `play()` call. Like `Mobject`, a single variant type is used for
## every animation kind to keep dispatch simple.

import ./core
import ./mobject

type
  AnimationKind* = enum
    akCreate, akUncreate, akFadeIn, akFadeOut, akShift, akMoveTo,
    akRotateBy, akScaleTo, akTransform, akWrite, akFadeTransform

  Animation* = ref object
    kind*: AnimationKind
    target*: Mobject
    duration*: float
    easing*: EasingFunc

    # kind-specific parameters, set by the constructors below
    delta*: Point2          ## akShift
    destination*: Point2    ## akMoveTo
    angle*: float           ## akRotateBy
    targetScale*: float     ## akScaleTo
    other*: Mobject         ## akTransform / akFadeTransform: the "into" shape

    # captured automatically the first time the animation is stepped
    started*: bool
    startCenter*: Point2
    startRotation*: float
    startScale*: float
    startFillOpacity*: float
    startStrokeOpacity*: float
    startFillColor*: Color
    startStrokeColor*: Color
    morphFrom*: seq[Point2]
    morphTo*: seq[Point2]

const morphSamples = 48 ## points used to approximate shapes during `transform`

proc newAnimation(kind: AnimationKind, target: Mobject, duration: float,
                   easing: EasingFunc): Animation =
  Animation(kind: kind, target: target, duration: duration, easing: easing,
            started: false)

proc create*(m: Mobject, duration = 1.0, easing: EasingFunc = smoothstep): Animation =
  ## Draws the mobject on progressively (opacity ramps 0 -> its own opacity).
  newAnimation(akCreate, m, duration, easing)

proc uncreate*(m: Mobject, duration = 1.0, easing: EasingFunc = smoothstep): Animation =
  newAnimation(akUncreate, m, duration, easing)

proc fadeIn*(m: Mobject, duration = 1.0, easing: EasingFunc = smoothstep): Animation =
  newAnimation(akFadeIn, m, duration, easing)

proc fadeOut*(m: Mobject, duration = 1.0, easing: EasingFunc = smoothstep): Animation =
  newAnimation(akFadeOut, m, duration, easing)

proc shiftBy*(m: Mobject, delta: Point2, duration = 1.0,
              easing: EasingFunc = smoothstep): Animation =
  result = newAnimation(akShift, m, duration, easing)
  result.delta = delta

proc moveTo*(m: Mobject, destination: Point2, duration = 1.0,
             easing: EasingFunc = smoothstep): Animation =
  result = newAnimation(akMoveTo, m, duration, easing)
  result.destination = destination

proc rotateBy*(m: Mobject, angle: float, duration = 1.0,
               easing: EasingFunc = smoothstep): Animation =
  result = newAnimation(akRotateBy, m, duration, easing)
  result.angle = angle

proc scaleTo*(m: Mobject, factor: float, duration = 1.0,
              easing: EasingFunc = smoothstep): Animation =
  result = newAnimation(akScaleTo, m, duration, easing)
  result.targetScale = factor

proc transform*(m: Mobject, into: Mobject, duration = 1.0,
                easing: EasingFunc = smoothstep): Animation =
  ## Morphs `m` into the shape/position/color of `into` over `duration`
  ## seconds. Both mobjects are approximated as `morphSamples`-point
  ## outlines and linearly interpolated; `m`'s kind becomes `into`'s kind
  ## once the animation finishes so later animations behave normally.
  result = newAnimation(akTransform, m, duration, easing)
  result.other = into

proc write*(m: Mobject, duration = 1.0, easing: EasingFunc = smoothstep): Animation =
  ## Intended for text: fades/scales the text into view. (Manim's real
  ## `Write` traces glyph strokes; that requires font outline access this
  ## package doesn't have, so this is a readable approximation.)
  newAnimation(akWrite, m, duration, easing)

# ---------------------------------------------------------------------------
# Stepping
# ---------------------------------------------------------------------------

proc captureStart(anim: Animation) =
  let m = anim.target
  anim.startCenter = m.center
  anim.startRotation = m.rotation
  anim.startScale = m.scaleFactor
  anim.startFillOpacity = m.fillOpacity
  anim.startStrokeOpacity = m.strokeOpacity
  anim.startFillColor = m.fillColor
  anim.startStrokeColor = m.strokeColor
  if anim.kind == akTransform:
    anim.morphFrom = getBoundaryPoints(m, morphSamples)
    anim.morphTo = getBoundaryPoints(anim.other, morphSamples)
  anim.started = true

proc applyMorph(m: Mobject, pts: seq[Point2]) =
  ## Repurposes `m` as a polygon mobject tracing `pts`, used mid-`transform`.
  m.kind = mkPolygon
  m.center = (0.0, 0.0)
  m.rotation = 0.0
  m.scaleFactor = 1.0
  m.vertices = pts

proc step*(anim: Animation, elapsed: float) =
  ## Advances the animation to `elapsed` seconds into its duration.
  ## Safe to call every frame with a monotonically increasing `elapsed`.
  if not anim.started:
    captureStart(anim)
  let m = anim.target
  let rawT = clamp(elapsed / max(anim.duration, 0.0001), 0.0, 1.0)
  let t = anim.easing(rawT)

  case anim.kind
  of akCreate, akFadeIn:
    m.fillOpacity = anim.startFillOpacity * t
    m.strokeOpacity = anim.startStrokeOpacity * t
    m.visible = true
  of akUncreate, akFadeOut:
    m.fillOpacity = anim.startFillOpacity * (1.0 - t)
    m.strokeOpacity = anim.startStrokeOpacity * (1.0 - t)
  of akShift:
    m.center = lerpPoint(anim.startCenter, anim.startCenter + anim.delta, t)
  of akMoveTo:
    m.center = lerpPoint(anim.startCenter, anim.destination, t)
  of akRotateBy:
    m.rotation = anim.startRotation + anim.angle * t
  of akScaleTo:
    m.scaleFactor = anim.startScale + (anim.targetScale - anim.startScale) * t
  of akWrite:
    m.fillOpacity = anim.startFillOpacity * t
    m.strokeOpacity = anim.startStrokeOpacity * t
    m.scaleFactor = 0.8 + 0.2 * t
  of akFadeTransform:
    m.fillOpacity = anim.startFillOpacity * (1.0 - t)
    m.strokeOpacity = anim.startStrokeOpacity * (1.0 - t)
  of akTransform:
    var pts = newSeq[Point2](morphSamples)
    for i in 0..<morphSamples:
      pts[i] = lerpPoint(anim.morphFrom[i], anim.morphTo[i], t)
    applyMorph(m, pts)
    m.fillColor = lerpColor(anim.startFillColor, anim.other.fillColor, t)
    m.strokeColor = lerpColor(anim.startStrokeColor, anim.other.strokeColor, t)
    m.fillOpacity = anim.startFillOpacity + (anim.other.fillOpacity - anim.startFillOpacity) * t
    m.strokeOpacity = anim.startStrokeOpacity + (anim.other.strokeOpacity - anim.startStrokeOpacity) * t

proc finish*(anim: Animation) =
  ## Snaps the target to its exact end state. Called after the last frame
  ## of a `play()` so animations land precisely regardless of easing.
  step(anim, anim.duration)
  let m = anim.target
  case anim.kind
  of akUncreate, akFadeOut:
    m.visible = false
  of akTransform:
    let o = anim.other
    m.kind = o.kind
    m.center = o.center
    m.rotation = o.rotation
    m.scaleFactor = o.scaleFactor
    m.radius = o.radius
    m.startAngle = o.startAngle
    m.endAngle = o.endAngle
    m.width = o.width
    m.height = o.height
    m.p1 = o.p1
    m.p2 = o.p2
    m.vertices = o.vertices
    m.text = o.text
    m.fontFamily = o.fontFamily
    m.fontSize = o.fontSize
    m.pathStart = o.pathStart
    m.pathSegs = o.pathSegs
    m.pathClosed = o.pathClosed
    m.fillColor = o.fillColor
    m.strokeColor = o.strokeColor
    m.fillOpacity = o.fillOpacity
    m.strokeOpacity = o.strokeOpacity
  else:
    discard
