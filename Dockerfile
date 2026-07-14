# syntax=docker/dockerfile:1.6
# Prepares a container ready to build the LATEST ungoogled-chromium directly
# from https://github.com/ungoogled-software/ungoogled-chromium (not the
# Debian-packaging fork, which is pinned to Chromium 120 from Jan 2024 and
# hasn't moved since). This follows docs/building.md from that repo.
#
# This image only does setup: OS deps, Chromium source fetch + patches,
# Chromium's own prebuilt clang/rust toolchain + sysroot, and `gn gen`.
# It does NOT run the actual multi-hour compile — that's container-build.sh,
# run synchronously via `docker exec -it`, so you keep full control of the
# terminal session for the whole build (no backgrounding/detaching involved).
#
# Usage:
#   ./build.sh                                                       # builds image, starts container
#   docker exec -it ungoogled-chromium-builder container-build.sh    # runs the compile, in the foreground
#   docker exec ungoogled-chromium-builder container-collect.sh      # after it finishes
#   docker cp ungoogled-chromium-builder:/artifacts/. ./artifacts/
#
# Needs on host: ~200GB disk, 16GB+ RAM, linux/amd64.

FROM debian:12.6

ENV DEBIAN_FRONTEND=noninteractive
ENV LANG=C.UTF-8
ENV LC_ALL=C.UTF-8

# Baseline tools: git/curl to fetch things, sudo+lsb-release for Chromium's
# own build/install-build-deps.py (which shells out to `sudo apt-get ...`),
# ninja-build provides `ninja`. binutils provides `ar`, needed to bootstrap
# GN from source below (Debian's own `generate-ninja`/gn package is version-
# pinned to whatever was current when bookworm released, and is too old to
# parse recent Chromium's .gn/BUILD.gn files — so we don't install it at all).
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    curl \
    git \
    python3 \
    python-is-python3 \
    xz-utils \
    sudo \
    lsb-release \
    pkg-config \
    file \
    patch \
    procps \
    rsync \
    binutils \
    ninja-build \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /build

RUN git clone --depth 1 \
    https://github.com/ungoogled-software/ungoogled-chromium.git \
    ungoogled-chromium

WORKDIR /build/ungoogled-chromium

# Fetch the official Chromium source tarball for the version pinned in
# chromium_version.txt, then unpack it to /build/src.
RUN mkdir -p /build/download_cache \
    && ./utils/downloads.py retrieve -c /build/download_cache -i downloads.ini \
    && ./utils/downloads.py unpack -c /build/download_cache -i downloads.ini -- /build/src

WORKDIR /build/src

# Official Chromium OS build-deps installer (root can run `sudo` fine here).
RUN python3 build/install-build-deps.py --no-prompt

# Chromium's own pinned clang + rust toolchains (NOT apt/system clang — recent
# Chromium tracks LLVM trunk snapshots far ahead of any released distro clang,
# which is exactly why the Debian-packaging fork got stuck on old versions).
# MUST run before domain_substitution.py below: these scripts fetch from real
# Google domains (commondatastorage.googleapis.com), and domain substitution
# rewrites exactly those strings throughout the tree (that's how it stops the
# built browser from calling home at runtime) — running it first would corrupt
# the URLs these build-time scripts need.
RUN python3 tools/clang/scripts/update.py
RUN python3 tools/rust/update_rust.py

# Sysroot for a consistent, portable glibc baseline (also fetches from Google's
# CDN, so this must run before domain substitution too).
RUN python3 build/linux/sysroot_scripts/install-sysroot.py --arch=amd64

# Node.js binary needed by the WebUI build toolchain. Normally a `gclient`
# GCS-type hook (see DEPS: src/third_party/node/linux); we're not using
# gclient, so fetch the exact pinned object directly. Same domain-substitution
# ordering constraint as clang/rust/sysroot above.
RUN NODE_INFO="$(python3 -c "ns={}; ns['Var']=lambda n: ns['vars'][n]; ns['Str']=lambda s: s; exec(open('DEPS').read(), ns); o=ns['deps']['src/third_party/node/linux']['objects'][0]; print(o['object_name']+' '+o['sha256sum'])")" \
    && NODE_OBJECT="$(echo "$NODE_INFO" | cut -d' ' -f1)" \
    && NODE_SHA256="$(echo "$NODE_INFO" | cut -d' ' -f2)" \
    && mkdir -p third_party/node/linux \
    && curl -fSL "https://storage.googleapis.com/chromium-nodejs/${NODE_OBJECT}" -o /tmp/node-linux-x64.tar.gz \
    && echo "${NODE_SHA256}  /tmp/node-linux-x64.tar.gz" | sha256sum -c - \
    && tar -xzf /tmp/node-linux-x64.tar.gz -C third_party/node/linux/ \
    && rm /tmp/node-linux-x64.tar.gz

# Build GN from source at the exact commit this Chromium version pins in DEPS
# (read dynamically, so this keeps working as the tracked version advances).
# Debian's packaged GN is too old (see above) — GN moved out of Chromium's
# source tree into its own repo and is normally fetched prebuilt via CIPD,
# which isn't usable without depot_tools, so we build it ourselves here,
# using Chromium's own fetched clang++ as the compiler.
RUN GN_VERSION="$(grep -oP "'gn_version': 'git_revision:\K[0-9a-f]+" DEPS)" \
    && git clone https://gn.googlesource.com/gn /build/gn \
    && cd /build/gn \
    && git checkout "$GN_VERSION" \
    && CXX=/build/src/third_party/llvm-build/Release+Asserts/bin/clang++ \
       CXXFLAGS="-Wno-deprecated-declarations" \
       python3 build/gen.py --out-path out \
    && ninja -C out \
    && cp out/gn /usr/local/bin/gn

WORKDIR /build/ungoogled-chromium
# --keep-contingent-paths: by default this also deletes third_party/llvm-build,
# third_party/rust-toolchain, and the sysroot dirs, since those are normally
# expected to come from CIPD/GCS via `gclient sync` — which we're not using,
# we fetched them ourselves above, so skip pruning them.
RUN ./utils/prune_binaries.py --keep-contingent-paths /build/src pruning.list
RUN ./utils/patches.py apply /build/src patches
RUN ./utils/domain_substitution.py apply \
    -r domain_regex.list \
    -f domain_substitution.list \
    -c /build/domsubcache.tar.gz \
    /build/src

WORKDIR /build/src

# GN args: ungoogled-chromium's own flags, plus the minimal essentials any
# build needs (release, no debug symbols to save time/disk), plus proprietary
# codec support (H.264/AAC/MP3) — flags.gn doesn't set this, so without it
# ffmpeg is built decoder-less for these formats and sites like YouTube fail
# with "FFmpegDemuxer: no supported streams".
RUN mkdir -p out/Release \
    && cp ../ungoogled-chromium/flags.gn out/Release/args.gn \
    && printf 'is_debug=false\nsymbol_level=0\nproprietary_codecs=true\nffmpeg_branding="Chrome"\n' >> out/Release/args.gn \
    && gn gen out/Release --fail-on-unused-args

COPY container-build.sh container-collect.sh /usr/local/bin/
RUN chmod +x /usr/local/bin/container-build.sh /usr/local/bin/container-collect.sh

# Keep the container alive so the compile can be driven via `docker exec`.
CMD ["sleep", "infinity"]
