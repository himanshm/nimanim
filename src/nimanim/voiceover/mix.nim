## Audio mixing for `nimanim/voiceover`.
##
## Each `VoiceoverScene.say()` call produces one audio clip plus a start
## time (the moment in the final video when narration should begin). This
## module turns that list of `(clip, start_time)` pairs into a single WAV
## via ffmpeg's `adelay`+`amix` filter graph -- no need to ship a custom
## mixer.
##
## The output is mono 22050 Hz by default (enough for speech, and keeps
## file sizes small); callers wanting different settings can pass optional
## args.

import std/[osproc, strutils, streams, os]
import ./synth

type
  VoiceoverSegment* = object
    ## One piece of narration scheduled on the final audio track.
    audioPath*: string
    startTime*: float       ## seconds from start of video
    duration*: float        ## seconds (length of the clip)
    text*: string
    voice*: string
    words*: seq[WordBoundary]

proc mixVoiceoverSegments*(segments: seq[VoiceoverSegment], outputPath: string,
                           sampleRate = 22050, channels = 1): bool =
  ## Mixes `segments` into a single WAV at `outputPath` using ffmpeg.
  ## Returns true on success, false if ffmpeg failed (or there were no
  ## segments to mix).
  ##
  ## Each segment is delayed by `startTime` milliseconds and then all are
  ## summed with `amix`. The result is resampled to a uniform format so
  ## backends with different sample rates (espeak 22050, kokoro 24000)
  ## can be freely mixed.
  if segments.len == 0:
    return false

  var inputs: seq[string] = @[]
  for s in segments:
    inputs.add(@["-i", s.audioPath])

  var filterParts: seq[string] = @[]
  var labels: seq[string] = @[]
  for i, s in segments:
    let delayMs = int(s.startTime * 1000.0)
    let label = "a" & $i
    # adelay takes one value per channel; specifying the same value twice
    # works for both mono and stereo inputs.
    let delayArg = if channels == 1: $delayMs else: $delayMs & "|" & $delayMs
    filterParts.add("[" & $i & ":a]aformat=channel_layouts=" &
                    (if channels == 1: "mono" else: "stereo") &
                    ",adelay=" & delayArg & "[" & label & "]")
    labels.add("[" & label & "]")

  let mixLabel = labels.join("") & "amix=inputs=" & $segments.len &
                 ":duration=longest:dropout_transition=0"

  var args = @["-y"]
  for inp in inputs:
    args.add(inp)
  args.add(@[
    "-filter_complex", filterParts.join(";") & ";" & mixLabel,
    "-ar", $sampleRate,
    "-ac", $channels,
    outputPath,
  ])

  let p = startProcess("ffmpeg", args = args,
                       options = {poUsePath, poStdErrToStdOut})
  discard p.outputStream().readAll()  # drain so the pipe doesn't deadlock
  let rc = p.waitForExit()
  p.close()
  result = (rc == 0) and fileExists(outputPath)
