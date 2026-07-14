#!/bin/bash
# Run inside the builder container once container-build.sh has finished.
# Stages only what's needed to actually run the browser at /artifacts —
# out/Release is otherwise full of build-time cruft (test-target metadata,
# one-off code generators like v8_context_snapshot_generator/mksnapshot,
# whose *output* is already baked into the .pak/.bin files below).
#   docker cp <container>:/artifacts/. ./artifacts/
set -euo pipefail

cd /build/src/out/Release

if pgrep -f 'ninja -j' >/dev/null 2>&1; then
    echo "Build is still running — check /build/build.log" >&2
    exit 1
fi

if [ ! -x ./chrome ]; then
    echo "No chrome binary found in out/Release — build may have failed. Check /build/build.log" >&2
    exit 1
fi

DEST=/artifacts/chrome-bin
mkdir -p "$DEST"

FILES=(
    chrome
    chrome_sandbox
    chrome_crashpad_handler
    icudtl.dat
    resources.pak
    chrome_100_percent.pak
    chrome_200_percent.pak
    v8_context_snapshot.bin
    snapshot_blob.bin
    libEGL.so
    libGLESv2.so
    libvulkan.so.1
    libvk_swiftshader.so
    libVkICD_mock_icd.so
    vk_swiftshader_icd.json
    product_logo_48.png
)
DIRS=(locales resources)

for f in "${FILES[@]}"; do
    [ -e "$f" ] && cp -a "$f" "$DEST/"
done
for d in "${DIRS[@]}"; do
    [ -d "$d" ] && cp -a "$d" "$DEST/"
done

du -sh "$DEST"
echo "Staged at $DEST. Note: chrome_sandbox needs root:root ownership"
echo "and mode 4755 on the host to enable the sandbox (or run chrome with --no-sandbox)."
