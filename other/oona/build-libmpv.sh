#!/bin/bash
# Build the experimental embedded gpu-next backend; never modify Homebrew itself.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
WORK="$ROOT/build/dv"
REV=97179bce7ed980c53647d6344916f632fe689e9e
SHA=0aa760258c3ad07b5339bb8998ea0f93b53357234eb49836f0caaa9da15e96e7
SOURCE="$WORK/mpv-$REV"
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
export PATH="$WORK/venv/bin:$PATH"
BREW_PREFIX=${BREW_PREFIX:-/opt/homebrew}
export PKG_CONFIG_PATH="$WORK/pkgconfig:$BREW_PREFIX/lib/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
if [[ ${1:-} != "" && ${1:-} != --install ]]; then
  echo "Usage: $0 [--install]" >&2; exit 2
fi
for tool in meson ninja pkg-config; do
  command -v "$tool" >/dev/null || { echo "Missing $tool; see other/oona/README.md" >&2; exit 1; }
done
mkdir -p "$WORK/pkgconfig"
# Homebrew freetype references SDK libraries, which ship without .pc files.
cat > "$WORK/pkgconfig/zlib.pc" <<'PC'
Name: zlib
Description: macOS SDK zlib
Version: 1.2.12
Libs: -lz
PC
cat > "$WORK/pkgconfig/bzip2.pc" <<'PC'
Name: bzip2
Description: macOS SDK bzip2
Version: 1.0.8
Libs: -lbz2
PC
if [[ ! -f "$WORK/mpv-source.tar.gz" ]]; then
  curl -fL "https://codeload.github.com/lhc70000/mpv/tar.gz/$REV" -o "$WORK/mpv-source.tar.gz"
fi
printf '%s  %s\n' "$SHA" "$WORK/mpv-source.tar.gz" | shasum -a 256 -c -
[[ -d "$SOURCE" ]] || tar -xzf "$WORK/mpv-source.tar.gz" -C "$WORK"
PATCHES=("$ROOT"/other/oona/patches/*.patch)
for PATCH in "${PATCHES[@]}"; do
  if ! patch --dry-run -R -p1 -d "$SOURCE" < "$PATCH" >/dev/null 2>&1; then
    patch --batch -p1 -d "$SOURCE" < "$PATCH"
  fi
done
args=()
[[ ! -f "$WORK/mpv-build/build.ninja" ]] || args+=(--reconfigure)
meson setup "${args[@]}" "$WORK/mpv-build" "$SOURCE" \
  -Dlibmpv=true -Dcplayer=false -Dbuildtype=release -Db_lundef=true \
  -Dswift-build=enabled -Dcocoa=enabled -Dgl-cocoa=enabled \
  -Dvulkan=enabled -Dvideotoolbox-pl=disabled --wrap-mode=nofallback
meson compile -C "$WORK/mpv-build" -j "${JOBS:-8}"
meson introspect "$WORK/mpv-build" --dependencies > "$WORK/dependencies.json"
shasum -a 256 "${PATCHES[@]}" "$WORK/mpv-build/libmpv.2.dylib" > "$WORK/build.sha256"
if [[ ${1:-} == --install ]]; then
  # --install only stages in this checkout, not /Applications or Homebrew.
  cp "$WORK/mpv-build/libmpv.2.dylib" "$ROOT/deps/lib/libmpv.2.dylib"
  for header in client.h render.h render_gl.h; do
    cp "$SOURCE/include/mpv/$header" "$ROOT/deps/include/mpv/$header"
  done
fi
printf '\nBuilt %s\nDependency manifest: %s\n' "$WORK/mpv-build/libmpv.2.dylib" "$WORK/dependencies.json"
