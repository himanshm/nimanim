# Package

version       = "1.3.0"
author        = "himanshm"
description   = "A port of ManimCE in Nim (with optional voiceover support)"
license       = "MIT"
srcDir        = "src"


# Dependencies

requires "nim >= 1.6.0"
requires "cairo >= 1.1.0"

# FreeType is used by `nimanim/font.nim` to load arbitrary `.ttf` / `.otf`
# font files (the README's "toy text API only" limitation). The link flag
# is applied to every binary that imports `nimanim`, so callers don't need
# to add anything special to their own Nim files.
before build:
  switch("passL", "-lfreetype")
  switch("passC", "-I/usr/include/freetype2")
