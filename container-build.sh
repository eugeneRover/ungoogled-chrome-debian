#!/bin/bash
# Run inside the builder container, in the foreground:
#   docker exec -it ungoogled-chromium-builder container-build.sh
# Keep this session open until it finishes (or drive it yourself, e.g. tmux).
set -euo pipefail

cd /build/src

ninja -j "${BUILD_PARALLEL:-6}" -C out/Release chrome chrome_sandbox chromedriver 2>&1 | tee /build/build.log
