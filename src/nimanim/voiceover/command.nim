## Generic command-line speech synthesizer backend.
##
## For TTS engines that expose a CLI but don't have a dedicated nimanim
## module yet. You provide a shell-template string; the backend
## substitutes `{text}` and `{output}` and runs it.
##
## Example (festival):
##
##   let synth = newCommandSynthesizer(
##     cmd = "echo {text} | text2wave -o {output}",
##     durationFromProbe = true,
##   )
##
## Example (pico2wave):
##
##   let synth = newCommandSynthesizer(
##     cmd = "pico2wave -w {output} {text}",
##     durationFromProbe = true,
##   )
##
## Word-level timing is approximated by splitting the text on whitespace
## and spreading the duration evenly, the same way the eSpeak backend does.

import std/[os, osproc, strutils, streams]
import ./synth

proc splitWordsEvenly(text: string, duration: float): seq[WordBoundary] =
  let words = text.splitWhitespace()
  if words.len == 0 or duration <= 0.0:
    return @[]
  result = newSeq[WordBoundary](words.len)
  let per = duration / words.len.float
  for i, w in words:
    result[i] = WordBoundary(
      text: w,
      start: per * i.float,
      `end`: per * (i.float + 1.0),
    )

proc newCommandSynthesizer*(cmd: string,
                             durationFromProbe = true,
                             defaultVoice = "",
                             cacheDir = "media/voiceover_cache",
                             shell = false): SpeechSynthesizer =
  ## Builds a `SpeechSynthesizer` from a shell-template `cmd`.
  ##
  ## `cmd` is invoked with `{text}` replaced by the (shell-quoted) input
  ## text and `{output}` replaced by a path to a temp WAV the command is
  ## expected to write.
  ##
  ## Set `durationFromProbe = true` (the default) to measure the resulting
  ## WAV's duration with ffprobe; set it to `false` only if your command
  ## already prints duration info to stdout (not currently parsed, but
  ## keeps the door open).
  ##
  ## Set `shell = true` to run the command through `/bin/sh -c` instead
  ## of `startProcess`-style arg splitting. This is required for commands
  ## that use shell features like pipes (`|`) or redirects (`>`).
  let captureCmd = cmd
  let captureShell = shell
  let captureProbe = durationFromProbe

  proc fn(text: string, v: string): SynthesisResult {.closure.} =
    let tmpPath = getTempDir() / "nimanim_cmd_" & $os.getCurrentProcessId() & ".wav"
    let filledCmd = captureCmd.replace("{text}", quoteShell(text))
                              .replace("{output}", tmpPath)

    if captureShell:
      let p = startProcess("/bin/sh", args = @["-c", filledCmd],
                           options = {poUsePath, poStdErrToStdOut})
      discard p.outputStream().readAll()
      let rc = p.waitForExit()
      p.close()
      if rc != 0:
        raise newException(ValueError, "Command failed (rc=" & $rc & "): " & filledCmd)
    else:
      let args = filledCmd.parseCmdLine()
      let exe = args[0]
      let rest = args[1..^1]
      let p = startProcess(exe, args = rest,
                           options = {poUsePath, poStdErrToStdOut})
      discard p.outputStream().readAll()
      let rc = p.waitForExit()
      p.close()
      if rc != 0:
        raise newException(ValueError, "Command failed (rc=" & $rc & "): " & filledCmd)

    if not fileExists(tmpPath):
      raise newException(ValueError,
        "Command did not produce output file at " & tmpPath & ": " & filledCmd)

    let dur = if captureProbe: probeAudioDuration(tmpPath) else: 0.0
    result = SynthesisResult(
      audioPath: tmpPath,
      duration: dur,
      sampleRate: 0,
      words: splitWordsEvenly(text, dur),
    )

  result = newSpeechSynthesizer(
    name = "command",
    synthesizeFn = fn,
    defaultVoice = defaultVoice,
    cacheDir = cacheDir,
  )
