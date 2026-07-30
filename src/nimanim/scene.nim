## Scene ties everything together: it holds the mobjects currently on
## screen, maps "scene units" to pixels, and drives ffmpeg to encode the
## frames produced each `play()`/`wait()` call into an MP4.

import std/[osproc, streams, os]
import cairo
import ./core
import ./mobject
import ./animation

type
  Scene* = ref object
    pixelWidth*, pixelHeight*: int
    frameWidth*, frameHeight*: float ## scene-unit size of the visible frame
    fps*: int
    backgroundColor*: Color
    mobjects*: seq[Mobject]

    surface: ptr Surface
    ctx: ptr Context
    ffmpeg: Process
    ffmpegIn: Stream
    frameBuf: string          ## reused each frame to avoid reallocating

proc newScene*(pixelWidth = 1280, pixelHeight = 720, fps = 30,
               frameWidth = 14.222, frameHeight = 8.0,
               backgroundColor = BLACK): Scene =
  Scene(
    pixelWidth: pixelWidth, pixelHeight: pixelHeight, fps: fps,
    frameWidth: frameWidth, frameHeight: frameHeight,
    backgroundColor: backgroundColor, mobjects: @[],
  )

proc add*(scene: Scene, mobjects: varargs[Mobject]) =
  for m in mobjects:
    scene.mobjects.add(m)

proc remove*(scene: Scene, m: Mobject) =
  let idx = scene.mobjects.find(m)
  if idx >= 0:
    scene.mobjects.delete(idx)

proc pixelsPerUnit(scene: Scene): float =
  scene.pixelWidth.float / scene.frameWidth

proc mapToPixel(scene: Scene): PointMap =
  let ppu = scene.pixelsPerUnit
  let cx = scene.pixelWidth.float / 2.0
  let cy = scene.pixelHeight.float / 2.0
  result = proc(p: Point2): Point2 =
    (cx + p.x * ppu, cy - p.y * ppu) ## flip y: scene is y-up, pixels are y-down

proc writeFrame(scene: Scene) =
  ## Renders the current state of `scene.mobjects` to one frame and pipes
  ## its raw pixels to ffmpeg's stdin.
  let cr = scene.ctx
  cr.save()
  cr.setSourceRgba(scene.backgroundColor.r, scene.backgroundColor.g,
                    scene.backgroundColor.b, scene.backgroundColor.a)
  cr.paint()
  cr.restore()

  let mapPt = scene.mapToPixel()
  let ppu = scene.pixelsPerUnit
  for m in scene.mobjects:
    draw(cr, m, mapPt, ppu)

  let data = scene.surface.getData()
  let stride = scene.surface.getStride()
  let rowBytes = scene.pixelWidth * 4
  # Cairo's ARGB32 surfaces are stored, byte-for-byte on little-endian
  # machines, as B,G,R,A per pixel -- i.e. ffmpeg's "bgra" rawvideo format.
  # `stride` may be larger than `rowBytes` due to alignment padding, so
  # rows are copied individually rather than blitting the whole buffer.
  for row in 0..<scene.pixelHeight:
    let srcOffset = row * stride
    scene.ffmpegIn.writeData(unsafeAddr data[srcOffset], rowBytes)

proc renderFrames(scene: Scene, seconds: float) =
  let frameCount = max(1, int(seconds * scene.fps.float + 0.5))
  for _ in 0..<frameCount:
    scene.writeFrame()

proc wait*(scene: Scene, seconds: float = 1.0) =
  renderFrames(scene, seconds)

proc playImpl(scene: Scene, anims: openArray[Animation], duration: float) =
  let frameCount = max(1, int(duration * scene.fps.float + 0.5))
  for f in 0..<frameCount:
    let elapsed = (f.float + 1.0) / frameCount.float * duration
    for a in anims:
      step(a, min(elapsed, a.duration))
    scene.writeFrame()
  for a in anims:
    finish(a)

proc play*(scene: Scene, anims: varargs[Animation]) =
  ## Plays one or more animations simultaneously, running for as long as
  ## the longest individual animation's `duration`.
  var duration = 0.0
  for a in anims:
    if a.duration > duration: duration = a.duration
  if duration <= 0: duration = 1.0
  playImpl(scene, anims, duration)

proc play*(scene: Scene, runTime: float, anims: varargs[Animation]) =
  ## Same as `play`, but forces the whole `play` call to take exactly
  ## `runTime` seconds regardless of the animations' own `duration`.
  ## (Note: `runTime` comes first -- Nim's varargs must be the last
  ## parameter, so it can't follow the animation list.)
  playImpl(scene, anims, runTime)

proc renderScene*(scene: Scene, construct: proc(s: Scene),
                   outputPath: string) =
  ## Opens the ffmpeg pipe, runs `construct` (which should call `add`,
  ## `play`, and `wait` on `scene`), then closes out the video file.
  scene.surface = imageSurfaceCreate(FORMAT_ARGB32, scene.pixelWidth.int32,
                                       scene.pixelHeight.int32)
  scene.ctx = create(scene.surface)

  let (dir, _, _) = splitFile(outputPath)
  if dir.len > 0 and not dirExists(dir):
    createDir(dir)

  let args = @[
    "-y",
    "-f", "rawvideo",
    "-pixel_format", "bgra",
    "-video_size", $scene.pixelWidth & "x" & $scene.pixelHeight,
    "-framerate", $scene.fps,
    "-i", "-",
    "-c:v", "libx264",
    "-pix_fmt", "yuv420p",
    outputPath,
  ]
  scene.ffmpeg = startProcess("ffmpeg", args = args,
                               options = {poUsePath, poStdErrToStdOut})
  scene.ffmpegIn = scene.ffmpeg.inputStream()

  construct(scene)

  scene.ffmpegIn.close()
  discard scene.ffmpeg.waitForExit()
  scene.ffmpeg.close()

  scene.ctx.destroy()
  scene.surface.destroy()
