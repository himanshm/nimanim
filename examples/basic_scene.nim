## Run with:  nim c -r -d:release examples/basic_scene.nim
## Produces:  output/basic_scene.mp4

import nimanim

proc construct(s: Scene) =
  let title = newText("nimanim", fontSize = 1.0, center = (0.0, 3.0), color = WHITE)
  s.add(title)
  s.play(1.0, write(title))
  s.wait(0.3)

  let circle = newCircle(radius = 1.2, center = (-3.5, 0.0),
                          fillColor = BLUE, strokeColor = BLUE,
                          fillOpacity = 0.6)
  let square = newSquare(sideLength = 2.0, center = (3.5, 0.0),
                          fillColor = YELLOW, strokeColor = YELLOW,
                          fillOpacity = 0.6)
  s.add(circle, square)
  s.play(1.0, create(circle), create(square))
  s.wait(0.3)

  # Move them toward each other with an ease-in-out cubic instead of the
  # default smoothstep, just to show `easing` is swappable per-animation.
  s.play(
    moveTo(circle, (-1.0, -1.5), duration = 1.2, easing = easeInOutCubic),
    moveTo(square, (1.0, -1.5), duration = 1.2, easing = easeInOutCubic),
    rotateBy(square, degToRad(45.0), duration = 1.2),
  )
  s.wait(0.3)

  # Group them and move together, then apply an instant (non-animated)
  # rescale directly via the mobject helper rather than `play`.
  let pair = newGroup(circle, square)
  s.play(shiftBy(pair, (0.0, 2.0), duration = 1.0))
  discard scaleBy(pair, 0.6)

  # Morph the circle into a triangle.
  let triangle = newTriangle(size = 2.0, center = circle.center,
                              fillColor = GREEN, strokeColor = GREEN,
                              fillOpacity = 0.6)
  s.play(transform(circle, triangle, duration = 1.2))
  s.wait(0.3)

  s.play(0.8, fadeOut(circle), fadeOut(square), fadeOut(title))

let scene = newScene(pixelWidth = 1280, pixelHeight = 720, fps = 30)
renderScene(scene, construct, "output/basic_scene.mp4")
