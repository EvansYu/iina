# Embedded Dolby Vision renderer (experimental)

This checkout uses `vo=libmpv` with the `opengl-next` render API from
[lhc70000/mpv at 97179b](https://github.com/lhc70000/mpv/commit/97179bce7ed980c53647d6344916f632fe689e9e).
It renders through libplacebo into IINA's existing OpenGL layer. It does **not**
create or reparent an mpv window, pump nested run loops, or launch an external
player. Stock libmpv does not provide this API; do not run `download_libs.sh`
after staging this library without rebuilding it.

## Build on Apple Silicon

Prerequisites: full Xcode, Python 3, and compatible Homebrew development libraries
(FFmpeg, libplacebo with OpenGL/DOVI, libass and their dependencies). The source
archive and build tools are pinned; Homebrew dependencies are local prerequisites,
not a reproducible release SDK. The tested dependency versions are recorded in
the task spec and `build/dv/dependencies.json`.

```sh
python3 -m venv build/dv/venv
build/dv/venv/bin/python -m pip install meson==1.9.1 ninja==1.13.2 pkgconf==3.0.7.post0
other/oona/build-libmpv.sh --install
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild \
  -project iina.xcodeproj -scheme iina -configuration Release \
  -derivedDataPath build/iina ARCHS=arm64 ONLY_ACTIVE_ARCH=YES CODE_SIGNING_ALLOWED=NO
python3 other/oona/bundle-libmpv.py build/iina/Build/Products/Release/IINA.app
codesign --force --deep -s - build/iina/Build/Products/Release/IINA.app
```

`--install` copies only to this checkout's `deps/lib` and `deps/include/mpv`.
Without it, only the library in `build/dv` is built. The script verifies the source
archive SHA-256, applies the checked-in patch and emits the dependency manifest
and binary/patch hashes. It does not update or install Homebrew packages.

The local patch retains libplacebo queue signatures instead of using reusable
allocator addresses as image identities, and keeps target OSD texture ownership
out of unrelated source-frame unmapping. It also fixes screenshot texture allocation,
10-bit plane normalization, negative strides, output color tags and subtitles.

## Rendering policy and limitations

- The embedded renderer is required. Initialization fails explicitly if the
  matching library is missing; there is no silent Profile 5 fallback to legacy GL.
- Software decoding and `videotoolbox-copy` can upload CPU-visible frames to GL.
  The experimental backend has no direct VideoToolbox texture interop. The user's
  automatic hardware-decoder selection is preserved; check `hwdec-current`.
- SDR output is tagged sRGB and converted by macOS ColorSync. The pinned backend
  does not implement mpv ICC profiles, so IINA's custom ICC option is not applied.
  HDR retains the existing PQ/EDR path; multi-display/HDR accuracy needs validation.
- No claim of full Profile 7 FEL reconstruction, HDMI DV signaling, or Dolby
  certification. Profile 8.1/8.4 require separate sample validation.
- Raw built dylibs link to Homebrew paths. Run the bundle helper **before launching**
  to stage and relocate one dependency closure; otherwise two FFmpeg copies can load.
  This is still a local development build, **not** a validated release: deployment
  target/architecture checks, license notices, notarization, and clean-machine
  testing remain required. The local libraries target this machine, not macOS 12.

## Offscreen smoke test

```sh
clang -Wno-deprecated-declarations -I deps/include other/oona/tests/render-probe.c \
  -L build/dv/mpv-build -lmpv -Wl,-rpath,"$PWD/build/dv/mpv-build" \
  -framework OpenGL -o build/dv/render-probe
build/dv/render-probe /path/to/sample.mkv build/dv/frame.ppm videotoolbox-copy
```

The sample must be longer than 62 seconds. The probe opens at 60 seconds, renders
until playback advances beyond 62 seconds, saves an sRGB PPM, reports actual
decoder/color matrix/error count, and tears down the render context and core.
Run outside a filesystem sandbox when CGL access is denied. It proves rendering
progress and teardown, not display accuracy or all UI controls. Compare real DV
frames with an independent gpu-next reference and test the full application.


For a running **test instance** explicitly launched with
`--mpv-input-ipc-server=/tmp/iina-dv-embedded-test.sock`, run:

```sh
python3 other/oona/tests/check-playback.py /tmp/iina-dv-embedded-test.sock \
  --sdr /path/to/sdr-sample.mp4 --output-dir build/dv
```

Both samples must exceed 94 seconds. This changes playback, subtitle selection,
and the current file in that test instance. It checks progress, pause, backward
and forward seek, screenshot success, and DV → SDR → DV transitions. It leaves
the test player paused. Fullscreen, PiP, visual EDR accuracy and audible A/V sync
still require manual checks.

## Subtitle orientation and audio regressions

`0002-output-plane-orientation.patch` applies `FLIP_Y` to the output plane,
not only the video crop. This keeps DST_FRAME subtitles and video aligned.
Run the framebuffer regression (requires ffmpeg and Pillow):

```sh
python3 other/oona/tests/check-orientation.py build/dv/render-probe build/dv/orientation-check
```

`check-playback.py` also rejects mute, zero volume, missing audio and null output.
Do not launch a user-facing test with `--mpv-mute=yes`: mpv can persist it per
file in watch-later state. For isolated silent render probes use `ao=null` and
`config=no`; those probes do not validate real audio output. Use a separate
watch-later directory for application regression sessions. Existing user mute
preferences must not be overridden in application code.

If a newly updated Xcode has a pending license agreement, use an already
configured Command Line Tools installation for the standalone library build:
`DEVELOPER_DIR=/Library/Developer/CommandLineTools other/oona/build-libmpv.sh --install`.
A full application rebuild still needs a working Xcode installation.

`0003-coreaudio-channel-layout.patch` fixes the pinned fork's AudioUnit property:
AudioChannelLayout must be passed to `kAudioUnitProperty_AudioChannelLayout` on
Input scope, not `kAudioOutputUnitProperty_ChannelMap` (which expects SInt32[]).
The latter can fail with -50 and disable the audio track. Verify actual CoreAudio
initialization as well as mute state; decoding video is not an audio test.

## Fork release packaging

After building and bundling, run:

```sh
python3 other/oona/package-release.py /path/to/bundled/IINA.app build/dv/release-1.0.0 1.0.0
```

The output directory must be new. This creates Oona DV.app with an independent
bundle identifier, disabled upstream automatic updates, local dependency notices
and source recipes. It retains only linked media libraries, checks arm64 support
and signs/verifies the bundle ad-hoc. It does not notarize or publish. See
[1.0.0 release notes](releases/1.0.0.md) for the deliberately limited compatibility
claim. Do not distribute a package without its matching source/notice attachments.
