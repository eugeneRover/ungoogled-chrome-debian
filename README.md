# ungoogled-chromium-docker

Docker setup to build [ungoogled-chromium](https://github.com/ungoogled-software/ungoogled-chromium) — Chromium with Google services stripped out — straight from its upstream source, tracking whatever version is currently pinned there (**150.x** as of this writing).

This intentionally does **not** use the [ungoogled-chromium-debian](https://github.com/ungoogled-software/ungoogled-chromium-debian) fork, which has been stuck on Chromium 120 since January 2024. Instead it follows upstream's own [`docs/building.md`](https://github.com/ungoogled-software/ungoogled-chromium/blob/master/docs/building.md), fetching Chromium's own pinned clang/rust toolchain, sysroot, and Node.js directly (no `depot_tools`/`gclient` needed), and builds GN from source since Debian's packaged GN is too old to parse recent Chromium's build files.

## Requirements

- Docker, `linux/amd64`
- ~200GB free disk
- 16GB+ RAM (builds have succeeded with a bit less, but linking gets tight)
- Patience — the compile step takes several hours

## Usage

```sh
./build.sh
```

Builds the image (source fetch, toolchain setup, `gn gen` — no compiling yet) and starts a long-lived container. This step does real network I/O (multi-GB downloads) but no multi-hour compute.

Then start the actual compile, synchronously, in its own container so it isn't tied to `docker build`'s connection (a dropped connection there won't lose your build):

```sh
docker exec -it ungoogled-chromium-builder container-build.sh
```

Keep that shell open until it finishes. Optionally watch progress from another terminal:

```sh
docker exec -it ungoogled-chromium-builder tail -f /build/build.log
```

Once it's done, pull the built browser out:

```sh
docker exec ungoogled-chromium-builder container-collect.sh
docker cp ungoogled-chromium-builder:/artifacts/. ./artifacts/
```

`container-collect.sh` stages only what's needed to actually run the browser (`chrome`, ICU/pak resources, locales, SwiftShader libs, etc.) — `out/Release` otherwise carries several GB of build-time-only cruft (test binaries, one-off code generators) that isn't needed at runtime.

## Running the built browser

```sh
cd artifacts/chrome-bin
sudo chown root:root chrome_sandbox && sudo chmod 4755 chrome_sandbox
./chrome
```

Without the `chrome_sandbox` ownership/permission fix, launch with `./chrome --no-sandbox` instead.

## Build flags used 

```
docker exec ungoogled-chromium-builder bash -c 'cd /build/src && gn args out/Release --list' > flags.txt
```

## Notes

- Includes `proprietary_codecs`/`ffmpeg_branding=Chrome` so H.264/AAC/MP3 (and sites like YouTube) work — ungoogled-chromium's own `flags.gn` doesn't set these.
- The image build re-fetches the Chromium source tarball and toolchain fresh each time by default (no `--no-cache`, so unchanged layers are still cached); the version tracked is whatever `chromium_version.txt` says in ungoogled-chromium's repo at build time.
- If you interrupt/rebuild the *image*, you lose the *container's* compiled output — they're separate. Don't `docker rm` a container mid-build or after a build you want to keep; edit `out/Release/args.gn` and re-run `gn gen` + `container-build.sh` inside the existing container for incremental rebuilds instead.
