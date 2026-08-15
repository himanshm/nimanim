## Core primitives shared by the rest of nimanim: 2D points, RGBA color,
## and easing (rate function) helpers used to shape animation timing.

import std/math
export math ## re-export so callers of `core` get PI, TAU, sin, cos, etc.

type
  Point2* = tuple[x, y: float]
    ## A 2D point in "scene units" (manim-style: origin at the center of
    ## the frame, +x right, +y up).

  Color* = object
    r*, g*, b*, a*: float   ## each channel in 0.0 .. 1.0

  EasingFunc* = proc(t: float): float {.closure.}
    ## Maps a linear progress value t in [0, 1] to an eased progress value,
    ## also expected to land in roughly [0, 1].

  PointMap* = proc(p: Point2): Point2 {.closure.}
    ## Converts a Point2 in scene units into pixel coordinates. Built by
    ## Scene and passed down into drawing code so mobjects never need to
    ## know about pixel resolution.

  Camera* = ref object
    ## A 2D camera: pan + zoom over the scene. The camera's `center` is in
    ## scene units (same coordinate system as `Mobject.center`), and `zoom`
    ## is a multiplier (>1 = zoom in, <1 = zoom out). 1.0 = no zoom.
    ##
    ## Defined here (rather than in `scene.nim`) to avoid a circular import
    ## between `scene.nim` and `animation.nim`: animations reference
    ## `Camera` to pan/zoom it, and `scene.nim` references `Animation`.
    center*: Point2
    zoom*: float

# ---------------------------------------------------------------------------
# Color helpers
# ---------------------------------------------------------------------------

proc color*(r, g, b: float, a: float = 1.0): Color =
  Color(r: r, g: g, b: b, a: a)

proc rgb255*(r, g, b: int, a: float = 1.0): Color =
  Color(r: r.float / 255.0, g: g.float / 255.0, b: b.float / 255.0, a: a)

proc lerpColor*(a, b: Color, t: float): Color =
  Color(
    r: a.r + (b.r - a.r) * t,
    g: a.g + (b.g - a.g) * t,
    b: a.b + (b.b - a.b) * t,
    a: a.a + (b.a - a.a) * t,
  )

# A handful of manim-flavored named colors.
const
  WHITE* = Color(r: 1.0, g: 1.0, b: 1.0, a: 1.0)
  BLACK* = Color(r: 0.0, g: 0.0, b: 0.0, a: 1.0)
  RED* = Color(r: 0.988, g: 0.278, b: 0.278, a: 1.0)
  GREEN* = Color(r: 0.267, g: 0.831, b: 0.454, a: 1.0)
  BLUE* = Color(r: 0.337, g: 0.596, b: 0.980, a: 1.0)
  YELLOW* = Color(r: 1.0, g: 0.859, b: 0.325, a: 1.0)
  ORANGE* = Color(r: 1.0, g: 0.588, b: 0.208, a: 1.0)
  PURPLE* = Color(r: 0.686, g: 0.443, b: 0.859, a: 1.0)
  TEAL* = Color(r: 0.290, g: 0.796, b: 0.760, a: 1.0)
  GRAY* = Color(r: 0.5, g: 0.5, b: 0.5, a: 1.0)
  TRANSPARENT* = Color(r: 0.0, g: 0.0, b: 0.0, a: 0.0)

# ---------------------------------------------------------------------------
# Point helpers
# ---------------------------------------------------------------------------

proc `+`*(a, b: Point2): Point2 = (a.x + b.x, a.y + b.y)
proc `-`*(a, b: Point2): Point2 = (a.x - b.x, a.y - b.y)
proc `*`*(a: Point2, s: float): Point2 = (a.x * s, a.y * s)

proc lerpPoint*(a, b: Point2, t: float): Point2 =
  (a.x + (b.x - a.x) * t, a.y + (b.y - a.y) * t)

proc rotatePoint*(p: Point2, center: Point2, angle: float): Point2 =
  let s = sin(angle)
  let c = cos(angle)
  let dx = p.x - center.x
  let dy = p.y - center.y
  (center.x + dx * c - dy * s, center.y + dx * s + dy * c)

# ---------------------------------------------------------------------------
# Easing / rate functions (the manim term is "rate_func")
# ---------------------------------------------------------------------------

proc linear*(t: float): float = t

proc smoothstep*(t: float): float =
  ## Same shape as manim's default `smooth` rate function.
  let x = clamp(t, 0.0, 1.0)
  x * x * (3.0 - 2.0 * x)

proc easeInSine*(t: float): float = 1.0 - cos(t * PI / 2.0)
proc easeOutSine*(t: float): float = sin(t * PI / 2.0)
proc easeInOutSine*(t: float): float = -(cos(PI * t) - 1.0) / 2.0

proc easeInCubic*(t: float): float = t * t * t
proc easeOutCubic*(t: float): float = 1.0 - pow(1.0 - t, 3.0)
proc easeInOutCubic*(t: float): float =
  if t < 0.5: 4.0 * t * t * t
  else: 1.0 - pow(-2.0 * t + 2.0, 3.0) / 2.0

proc thereAndBack*(t: float): float =
  ## Ramps 0 -> 1 -> 0 across the animation; handy for "pulse" effects.
  if t < 0.5: smoothstep(2.0 * t)
  else: smoothstep(2.0 - 2.0 * t)

proc degToRad*(deg: float): float = deg * PI / 180.0
