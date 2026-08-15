## nimanim -- a small, manim-inspired 2D animation engine for Nim.
##
## Renders scenes with Cairo and encodes them to MP4 with ffmpeg. Import
## this single module to get everything: shapes, animations, and Scene.
##
## Quick example:
##
##   import nimanim
##
##   proc construct(s: Scene) =
##     let circle = newCircle(radius = 1.5, strokeColor = BLUE, fillColor = BLUE,
##                             fillOpacity = 0.5)
##     s.add(circle)
##     s.play(create(circle))
##     s.play(shiftBy(circle, (3.0, 0.0)))
##     s.wait(0.5)
##
##   let scene = newScene()
##   renderScene(scene, construct, "output/my_video.mp4")

import ./nimanim/core
import ./nimanim/font
import ./nimanim/mobject
import ./nimanim/animation
import ./nimanim/scene

export core
export font
export mobject
export animation
export scene
