## Animations describe how a mobject's properties change over the course
## of a `play()` call. Like `Mobject`, a single variant type is used for
## every animation kind to keep dispatch simple.
##
## Camera animations (`panTo`, `zoomTo`) are stored alongside mobject
## animations in the same `Animation` variant; they simply target
## `scene.camera` instead of a `Mobject`. `Scene.play` detects these via
## `Animation.isCamera` and steps the camera directly rather than touching
## any mobject.

import ./core
import ./mobject
# Note: we deliberately do NOT `import ./scene` here -- that would create
# a circular import (scene.nim imports animation.nim to call `step` /
# `finish` on `Animation`s). The `Scene` type isn't referenced from this
# module; camera animations use `Camera`, which lives in `core.nim` for
# exactly this reason. `Scene.play` is what binds `anim.camera` to
# `scene.camera` before stepping.

type
  AnimationKind* = enum
    akCreate, akUncreate, akFadeIn, akFadeOut, akShift, akMoveTo,
    akRotateBy, akScaleTo, akTransform, akWrite, akFadeTransform,
    akCameraPanTo, akCameraZoomTo

  Animation* = ref object
    kind*: AnimationKind
    target*: Mobject
    duration*: float
    easing*: EasingFunc

    # kind-specific parameters, set by the constructors below
    delta*: Point2          ## akShift
    destination*: Point2    ## akMoveTo, akCameraPanTo
    angle*: float           ## akRotateBy
    targetScale*: float     ## akScaleTo, akCameraZoomTo (zoom multiplier)
    other*: Mobject         ## akTransform / akFadeTransform: the "into" shape

    # Camera animations store the target Camera here (set by Scene.play
    # before the first step). `startCenter` / `startScale` are reused for
    # the camera's starting pan/zoom.
    isCamera*: bool
    camera*: Camera
    startCameraCenter*: Point2
    startCameraZoom*: float

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
  ## Manim-style stroke-by-stroke glyph tracing. The text's glyph outlines
  ## are extracted via `cairo_text_path` + `cairo_copy_path_flat`, then
  ## revealed progressively along the cumulative arc length over
  ## `duration` seconds. The pen "writes" the text exactly as a human
  ## would -- left to right, glyph by glyph, stroke by stroke.
  ##
  ## Works for any font, including those loaded via `fontFile = "..."`.
  ## At the end of the animation, the mobject is snapped to its normal
  ## `showText` rendering (the stroked-trace look is only for the
  ## in-progress animation, not the final state).
  newAnimation(akWrite, m, duration, easing)

# ---------------------------------------------------------------------------
# Camera animations. These don't target a mobject -- they target the
# scene's `Camera` object, animating its `center` (pan) and `zoom` over
# time. `Scene.play` recognises them via `anim.isCamera` and binds the
# actual `Camera` reference before the first step.
# ---------------------------------------------------------------------------

proc panTo*(destination: Point2, duration = 1.0,
            easing: EasingFunc = smoothstep): Animation =
  ## Pans the scene's camera so its center moves to `destination` over
  ## `duration` seconds. Pass it to `scene.play(...)` like any other
  ## animation; the scene's `Camera` is bound automatically.
  ##
  ## Example: `scene.play(panTo((3.0, 0.0), duration = 1.5))`
  result = Animation(kind: akCameraPanTo, target: nil, duration: duration,
                     easing: easing, isCamera: true)
  result.destination = destination

proc zoomTo*(zoom: float, duration = 1.0,
             easing: EasingFunc = smoothstep): Animation =
  ## Zooms the scene's camera to `zoom` (a multiplier; 2.0 = 2x zoom-in,
  ## 0.5 = half-size zoom-out) over `duration` seconds.
  ##
  ## Example: `scene.play(zoomTo(2.0, duration = 1.0))`
  result = Animation(kind: akCameraZoomTo, target: nil, duration: duration,
                     easing: easing, isCamera: true)
  result.targetScale = zoom

# ---------------------------------------------------------------------------
# Stepping
# ---------------------------------------------------------------------------

proc captureStart(anim: Animation) =
  if anim.isCamera:
    if anim.camera == nil:
      raise newException(ValueError,
        "Camera animation has no bound camera. Did you call " &
        "`scene.play(panTo(...))` instead of constructing it manually?")
    anim.startCameraCenter = anim.camera.center
    anim.startCameraZoom = anim.camera.zoom
    anim.started = true
    return
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
  let rawT = clamp(elapsed / max(anim.duration, 0.0001), 0.0, 1.0)
  let t = anim.easing(rawT)

  # Camera animations bypass the mobject-specific step logic.
  if anim.isCamera:
    case anim.kind
    of akCameraPanTo:
      anim.camera.center = lerpPoint(anim.startCameraCenter, anim.destination, t)
    of akCameraZoomTo:
      anim.camera.zoom = anim.startCameraZoom + (anim.targetScale - anim.startCameraZoom) * t
    else:
      discard
    return

  let m = anim.target

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
    # Real stroke-by-stroke glyph tracing: ramp `writeFraction` from 0 to 1.
    # The `draw()` proc checks this field; when it's between 0 and 1 it
    # traces the glyph outlines as a partial stroke rather than doing a
    # fade/scale-in. Once it reaches 1.0 (or stays at the default -1.0),
    # `draw()` falls back to the normal `showText` path.
    m.writeFraction = t
    m.fillOpacity = anim.startFillOpacity
    m.strokeOpacity = anim.startStrokeOpacity
    m.scaleFactor = anim.startScale
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
  of akCameraPanTo, akCameraZoomTo:
    # Handled in the `isCamera` branch above; this case is unreachable but
    # required by Nim's exhaustiveness check.
    discard

proc finish*(anim: Animation) =
  ## Snaps the target to its exact end state. Called after the last frame
  ## of a `play()` so animations land precisely regardless of easing.
  step(anim, anim.duration)
  let m = anim.target
  case anim.kind
  of akUncreate, akFadeOut:
    m.visible = false
  of akWrite:
    # Reset writeFraction so subsequent frames draw via the normal showText
    # path -- the stroked-trace is only for the in-progress animation.
    m.writeFraction = -1.0
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
    m.fontFile = o.fontFile
    m.fontSlant = o.fontSlant
    m.fontWeight = o.fontWeight
    m.fontSize = o.fontSize
    m.pathStart = o.pathStart
    m.pathSegs = o.pathSegs
    m.pathClosed = o.pathClosed
    m.imageSurface = o.imageSurface
    m.imageWidth = o.imageWidth
    m.imageHeight = o.imageHeight
    m.writeFraction = o.writeFraction
    m.fillColor = o.fillColor
    m.strokeColor = o.strokeColor
    m.fillOpacity = o.fillOpacity
    m.strokeOpacity = o.strokeOpacity
  else:
    discard
