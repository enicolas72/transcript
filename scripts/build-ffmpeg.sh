#!/bin/bash
#
# Reproducible FFmpeg → XCFramework build for xTranscript.
#
# Audio-only, LGPL-only, statically linked. Drops every GPL or non-free
# component by configuring with `--disable-everything` and explicitly
# enabling only the demuxers/decoders/parsers we need. The output is a
# universal (arm64 + x86_64) XCFramework at Vendor/FFmpeg.xcframework.
#
# Usage: ./scripts/build-ffmpeg.sh [--clean]
#
set -euo pipefail

FFMPEG_VERSION="n7.1.1"
DEPLOYMENT_TARGET="14.0"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
# Scratch space — gitignored via .gitignore's `build/` rule (case-insensitive
# match on APFS). Keeps the source tree clean.
BUILD_DIR="$PROJECT_DIR/Build/ffmpeg-build"
SRC_DIR="$BUILD_DIR/ffmpeg-source"
INSTALL_BASE="$BUILD_DIR/install"
OUTPUT_DIR="$PROJECT_DIR/Vendor"
XCFRAMEWORK_PATH="$OUTPUT_DIR/FFmpeg.xcframework"

ARCHES=("arm64" "x86_64")

if [ "${1:-}" = "--clean" ]; then
    echo "Cleaning $BUILD_DIR and $XCFRAMEWORK_PATH"
    rm -rf "$BUILD_DIR" "$XCFRAMEWORK_PATH"
fi

mkdir -p "$BUILD_DIR" "$OUTPUT_DIR"

SDK="$(xcrun --sdk macosx --show-sdk-path)"

# ----------------------------------------------------------------------
# 1. Fetch FFmpeg source (shallow clone of the pinned release tag).
# ----------------------------------------------------------------------
if [ ! -d "$SRC_DIR/.git" ]; then
    echo "==> Cloning FFmpeg $FFMPEG_VERSION"
    git clone --depth 1 --branch "$FFMPEG_VERSION" https://github.com/FFmpeg/FFmpeg.git "$SRC_DIR"
fi
FFMPEG_SHA="$(cd "$SRC_DIR" && git rev-parse HEAD)"

# ----------------------------------------------------------------------
# 2. Configure-and-build for each architecture.
# ----------------------------------------------------------------------
# Args with spaces (--extra-cflags / --extra-ldflags) need to survive as a
# single argument apiece — handled with a bash array rather than a tr-joined
# string.

for ARCH in "${ARCHES[@]}"; do
    INSTALL_DIR="$INSTALL_BASE/$ARCH"
    if [ -f "$INSTALL_DIR/lib/libavformat.a" ]; then
        echo "==> Skip $ARCH (already built — pass --clean to rebuild)"
        continue
    fi
    echo "==> Building FFmpeg for $ARCH"
    BUILD_ARCH_DIR="$BUILD_DIR/build-$ARCH"
    rm -rf "$BUILD_ARCH_DIR"
    mkdir -p "$BUILD_ARCH_DIR"

    EXTRA="-arch $ARCH -mmacosx-version-min=$DEPLOYMENT_TARGET -isysroot $SDK"
    CONFIG_ARGS=(
        "--prefix=$INSTALL_DIR"
        "--target-os=darwin"
        "--arch=$ARCH"
        "--cc=clang"
        "--enable-cross-compile"
        "--enable-static"
        "--disable-shared"
        "--enable-pic"
        "--disable-everything"
        "--disable-doc"
        "--disable-programs"
        "--disable-debug"
        "--disable-network"
        "--disable-protocols"
        "--enable-protocol=file"
        "--disable-autodetect"
        "--disable-iconv"
        "--disable-asm"
        "--enable-swresample"
        "--enable-demuxer=matroska,ogg,mov,mp3,wav,flac,aac,aiff,mp4,avi,asf"
        "--enable-decoder=opus,vorbis,mp3,mp3float,aac,flac,ac3,eac3,wmav1,wmav2,wmavoice,wmapro,pcm_s16le,pcm_s16be,pcm_s24le,pcm_s32le,pcm_f32le,pcm_alaw,pcm_mulaw"
        "--enable-parser=opus,vorbis,mpegaudio,aac,flac,ac3"
        "--extra-cflags=$EXTRA"
        "--extra-ldflags=$EXTRA"
    )

    pushd "$BUILD_ARCH_DIR" >/dev/null
    printf '%s\n' "${CONFIG_ARGS[@]}" > .configure-args
    "$SRC_DIR/configure" "${CONFIG_ARGS[@]}"
    make -j"$(sysctl -n hw.ncpu)"
    make install
    popd >/dev/null
done

# ----------------------------------------------------------------------
# 3. Combine arch-specific libs into a single fat libffmpeg.a.
# ----------------------------------------------------------------------
echo "==> Lipo'ing per-library universal binaries"
UNIVERSAL_DIR="$BUILD_DIR/universal"
UNIV_LIB_DIR="$UNIVERSAL_DIR/lib"
rm -rf "$UNIVERSAL_DIR"
mkdir -p "$UNIV_LIB_DIR"
for LIB in libavformat libavcodec libavutil libswresample; do
    lipo -create \
        "$INSTALL_BASE/arm64/lib/$LIB.a" \
        "$INSTALL_BASE/x86_64/lib/$LIB.a" \
        -output "$UNIV_LIB_DIR/$LIB.a"
done

echo "==> Combining libav* into a single libffmpeg.a"
COMBINED_LIB="$UNIVERSAL_DIR/libffmpeg.a"
libtool -static -o "$COMBINED_LIB" \
    "$UNIV_LIB_DIR/libavformat.a" \
    "$UNIV_LIB_DIR/libavcodec.a" \
    "$UNIV_LIB_DIR/libavutil.a" \
    "$UNIV_LIB_DIR/libswresample.a"

# ----------------------------------------------------------------------
# 4. GPL / non-free contamination check.
# ----------------------------------------------------------------------
echo "==> Checking for GPL / non-free symbols"
if nm -gU "$COMBINED_LIB" 2>/dev/null | grep -iE 'x264|x265|fdk_aac|libgsm|libamr|libopencore|libtheora|wavpack_encoder' ; then
    echo "ERROR: GPL or non-free symbols found in libffmpeg.a"
    exit 1
fi
echo "    OK: no GPL or non-free symbols found."

# ----------------------------------------------------------------------
# 5. Build the XCFramework.
# ----------------------------------------------------------------------
echo "==> Assembling XCFramework"
HEADERS_DIR="$UNIVERSAL_DIR/headers"
rm -rf "$HEADERS_DIR"
mkdir -p "$HEADERS_DIR"
cp -R "$INSTALL_BASE/arm64/include/"* "$HEADERS_DIR/"

# Module map so Swift can `import CFFmpeg`. We list headers explicitly
# rather than `umbrella "."` so the platform-specific hardware-accel
# headers (d3d11va.h, qsv.h, hwcontext_cuda.h, …) — which reference
# Windows/Linux-only system headers — don't get pulled into the macOS
# Clang module graph.
cat > "$HEADERS_DIR/module.modulemap" <<'EOF'
module CFFmpeg {
    header "libavformat/avformat.h"

    header "libavcodec/avcodec.h"
    header "libavcodec/codec.h"
    header "libavcodec/codec_id.h"
    header "libavcodec/codec_par.h"
    header "libavcodec/packet.h"
    header "libavcodec/defs.h"
    header "libavcodec/version_major.h"
    header "libavcodec/version.h"

    header "libavutil/avutil.h"
    header "libavutil/buffer.h"
    header "libavutil/channel_layout.h"
    header "libavutil/common.h"
    header "libavutil/dict.h"
    header "libavutil/error.h"
    header "libavutil/frame.h"
    header "libavutil/log.h"
    header "libavutil/macros.h"
    header "libavutil/mathematics.h"
    header "libavutil/mem.h"
    header "libavutil/opt.h"
    header "libavutil/pixfmt.h"
    header "libavutil/rational.h"
    header "libavutil/samplefmt.h"
    header "libavutil/version.h"

    header "libswresample/swresample.h"

    export *
}
EOF

rm -rf "$XCFRAMEWORK_PATH"
xcodebuild -create-xcframework \
    -library "$COMBINED_LIB" \
    -headers "$HEADERS_DIR" \
    -output "$XCFRAMEWORK_PATH" >/dev/null

# ----------------------------------------------------------------------
# 6. Record exact build provenance.
# ----------------------------------------------------------------------
cat > "$OUTPUT_DIR/FFmpeg-source-tag.txt" <<EOF
FFmpeg version: $FFMPEG_VERSION
FFmpeg SHA:     $FFMPEG_SHA

Build host:     $(uname -m) macOS $(sw_vers -productVersion 2>/dev/null || echo unknown)
Xcode SDK:      $SDK
Deployment min: macOS $DEPLOYMENT_TARGET

Configure args (per-arch — read from one architecture's build dir):
$(cat "$BUILD_DIR/build-arm64/.configure-args")

Source download (LGPL §6 compliance):
  https://github.com/FFmpeg/FFmpeg/archive/refs/tags/$FFMPEG_VERSION.tar.gz
EOF

echo
echo "==> Done."
du -sh "$XCFRAMEWORK_PATH"
echo "Provenance: $OUTPUT_DIR/FFmpeg-source-tag.txt"
