import std/[os, strutils]

# all vendor subdirectories, excluding nwaku (a pre-rebase copy of
# logos-delivery that shadows the newer tree at
# vendor/logos-lez-rln/logos-delivery-module/vendor/logos-delivery when
# the latter is being built from within this parent config).
for dir in walkDir(thisDir() / "vendor"):
  if dir.kind == pcDir and not dir.path.endsWith("/nwaku"):
    switch("path", dir.path)
    switch("path", dir.path / "src")

switch("path", thisDir() / "vendor/libchat/nim-bindings")
switch("path", thisDir() / "vendor/libchat/nim-bindings/src")

# nwaku (PR #3807) consumes deps via nimble rather than vendored submodules,
# so add each package dir under nimbledeps/pkgs2 (and its src/) to the nim
# search path. The dir name carries the "<name>-<version>-<sha>" stamp; nim
# resolves imports by package name relative to those paths.
let nwakuDeps = thisDir() / "vendor/nwaku/nimbledeps/pkgs2"
if dirExists(nwakuDeps):
  for pkg in walkDir(nwakuDeps):
    if pkg.kind == pcDir:
      switch("path", pkg.path)
      if dirExists(pkg.path / "src"):
        switch("path", pkg.path / "src")