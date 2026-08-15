## Scene ties everything together: it holds the mobjects currently on
## screen, maps "scene units" to pixels, and drives ffmpeg to encode the
## frames produced each `play()`/`wait()` call into an MP4.
##
## Audio support: a Scene has an optional `audioTrackBuilder` hook. If set,
## `renderScene` first writes the video to a temp file, then calls the hook
## to obtain a mixed audio track (a path to a WAV/MP3 file), and finally
## muxes video + audio into the final output. This is what the optional
## `nimanim/voiceover` module uses to splice narration over animations.

import std/[osproc, streams, os]
import cairo
import ./core
import ./mobject
import ./animation

type
  AudioTrackBuilder* = proc(s: Scene): string {.closure.}
    ## Called by `renderScene` after `construct` has finished producing all
    ## video frames. Returns the path to a mixed audio file (WAV/MP3) to be
    ## muxed into the final MP4, or "" to skip muxing and keep the video as-is.

  Scene* = ref object
    pixelWidth*, pixelHeight*: int
    frameWidth*, frameHeight*: float ## scene-unit size of the visible frame
    fps*: int
    backgroundColor*: Color
    mobjects*: seq[Mobject]
    camera*: Camera          ## pan/zoom transform; default is center=(0,0), zoom=1.0
    audioTrackBuilder*: AudioTrackBuilder
      ## Optional audio hook -- nil for plain Scene, set by VoiceoverScene.

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
    camera: Camera(center: (0.0, 0.0), zoom: 1.0),
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
  ## Builds the scene-unit -> pixel-coordinate mapping, incorporating the
  ## camera's pan + zoom. The transform is:
  ##
  ##   pixel = (frameCenter) + (scenePt - camera.center) * ppu * camera.zoom
  ##
  ## with the y-axis flipped (scene is y-up, pixels are y-down). At the
  ## default camera (center=(0,0), zoom=1.0), this reduces to the same
  ## mapping as before the Camera type was introduced, so existing scenes
  ## render identically.
  let ppu = scene.pixelsPerUnit
  let z = scene.camera.zoom
  let camCx = scene.camera.center.x
  let camCy = scene.camera.center.y
  let cx = scene.pixelWidth.float / 2.0
  let cy = scene.pixelHeight.float / 2.0
  result = proc(p: Point2): Point2 =
    (cx + (p.x - camCx) * ppu * z, cy - (p.y - camCy) * ppu * z)
    # flip y: scene is y-up, pixels are y-down

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
  # `effectivePpu` includes the camera zoom so that stroke widths and
  # font sizes scale up/down with the camera (consistent with how a real
  # camera would render the scene).
  let ppu = scene.pixelsPerUnit * scene.camera.zoom
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
  # Bind any camera animations to this scene's camera before stepping.
  for a in anims:
    if a.isCamera and a.camera == nil:
      a.camera = scene.camera
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
  ##
  ## If `scene.audioTrackBuilder` is set, the video is first written to a
  ## temp file, then the builder is invoked to produce a mixed audio track,
  ## and finally video + audio are muxed into `outputPath`. Otherwise the
  ## video is written directly to `outputPath`.
  scene.surface = imageSurfaceCreate(FORMAT_ARGB32, scene.pixelWidth.int32,
                                       scene.pixelHeight.int32)
  scene.ctx = create(scene.surface)

  let (dir, _, _) = splitFile(outputPath)
  if dir.len > 0 and not dirExists(dir):
    createDir(dir)

  let useTemp = scene.audioTrackBuilder != nil
  let videoPath = if useTemp: outputPath & ".tmpvid.mp4" else: outputPath

  let args = @[
    "-y",
    "-f", "rawvideo",
    "-pixel_format", "bgra",
    "-video_size", $scene.pixelWidth & "x" & $scene.pixelHeight,
    "-framerate", $scene.fps,
    "-i", "-",
    "-c:v", "libx264",
    "-pix_fmt", "yuv420p",
    videoPath,
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

  # Audio mux step: voiceover (or any other audio producer) hooks in here.
  if useTemp:
    let audioPath = scene.audioTrackBuilder(scene)
    if audioPath.len > 0 and fileExists(audioPath):
      let muxArgs = @[
        "-y",
        "-i", videoPath,
        "-i", audioPath,
        "-map", "0:v",
        "-map", "1:a",
        "-c:v", "copy",
        "-c:a", "aac",
        "-b:a", "192k",
        "-shortest",
        outputPath,
      ]
      let muxProc = startProcess("ffmpeg", args = muxArgs,
                                  options = {poUsePath, poStdErrToStdOut})
      discard muxProc.waitForExit()
      muxProc.close()
      removeFile(videoPath)
    else:
      # Builder returned nothing useful -- just promote the temp file.
      if fileExists(outputPath): removeFile(outputPath)
      moveFile(videoPath, outputPath)
