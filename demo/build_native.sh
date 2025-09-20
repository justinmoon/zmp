#!/usr/bin/env bash
set -euo pipefail

ZIG=${ZIG:-zig}
ANDROID_API=${ANDROID_API:-24}
OUT_ARM64=android/app/src/main/jniLibs/arm64-v8a
OUT_X64=android/app/src/main/jniLibs/x86_64
mkdir -p "$OUT_ARM64" "$OUT_X64"

$ZIG build-lib native/ffi.zig -dynamic -fPIC -OReleaseSafe \
  -target aarch64-linux-android -Dandroid_api_level=$ANDROID_API \
  -femit-bin="$OUT_ARM64/libzmpserver.so"

$ZIG build-lib native/ffi.zig -dynamic -fPIC -OReleaseSafe \
  -target x86_64-linux-android -Dandroid_api_level=$ANDROID_API \
  -femit-bin="$OUT_X64/libzmpserver.so"

echo "Built JNI libraries into $OUT_ARM64 and $OUT_X64"
