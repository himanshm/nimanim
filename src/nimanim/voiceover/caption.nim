## Caption / subtitle generation for voiceover segments.
##
## Given a list of `VoiceoverSegment`s with per-word `WordBoundary` timing,
## produces SRT or WebVTT subtitles. Word boundaries from Kokoro are
## real (model-emitted); the espeak and command backends approximate them
## by splitting the text on whitespace and spreading the duration evenly.
## Either way, the resulting captions are tightly synced to the audio.
##
## Grouping: words are batched into ~7-word caption lines (configurable
## via `wordsPerLine`) so the subtitles stay readable on one line.

import std/[strutils, strformat]
import ./synth
import ./mix  # gives us VoiceoverSegment

type
  CaptionFormat* = enum
    cfSrt   ## SubRip (.srt) -- the most widely supported
    cfVtt   ## WebVTT (.vtt) -- used by HTML5 video

proc formatTimestamp(seconds: float, vtt: bool): string =
  ## Formats a float number of seconds as `HH:MM:SS,mmm` (SRT) or
  ## `HH:MM:SS.mmm` (VTT).
  let total = max(0.0, seconds)
  let h = int(total) div 3600
  let m = (int(total) div 60) mod 60
  let s = int(total) mod 60
  let ms = int((total - float(int(total))) * 1000.0)
  let sep = if vtt: "." else: ","
  result = &"{h:02d}:{m:02d}:{s:02d}{sep}{ms:03d}"

proc buildCaptions*(segments: seq[VoiceoverSegment], format: CaptionFormat,
                    wordsPerLine = 7): string =
  ## Builds a subtitle file from a list of voiceover segments.
  ##
  ## `wordsPerLine` controls how many words appear in each caption block;
  ## the default of 7 is a good balance between readability and density.
  var lines: seq[string] = @[]
  if format == cfVtt:
    lines.add("WEBVTT")
    lines.add("")

  var idx = 1  # caption index (1-based for SRT)
  for seg in segments:
    if seg.words.len == 0: continue
    var i = 0
    while i < seg.words.len:
      let j = min(i + wordsPerLine - 1, seg.words.len - 1)
      let absStart = seg.startTime + seg.words[i].start
      let absEnd = seg.startTime + seg.words[j].`end`
      var textParts: seq[string] = @[]
      for k in i..j:
        textParts.add(seg.words[k].text)
      let text = textParts.join(" ")
      if format == cfSrt:
        lines.add($idx)
        inc idx
      lines.add(formatTimestamp(absStart, vtt = (format == cfVtt)) &
                " --> " &
                formatTimestamp(absEnd, vtt = (format == cfVtt)))
      lines.add(text)
      lines.add("")
      i = j + 1

  result = lines.join("\n")
