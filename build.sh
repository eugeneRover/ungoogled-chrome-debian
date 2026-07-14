#!/usr/bin/env bash
set -euo pipefail

IMAGE="ungoogled-chromium-bookworm-builder"
CONTAINER="ungoogled-chromium-builder"

mkdir -p artifacts

docker build \
  --platform linux/amd64 \
  -t "$IMAGE" \
  .

if docker ps -a --format '{{.Names}}' | grep -qx "$CONTAINER"; then
  status="$(docker inspect -f '{{.State.Status}}' "$CONTAINER")"
  if [ "$status" = "running" ]; then
    echo "Container '$CONTAINER' is already running — leaving it as-is (not touching a possible in-progress build)."
  else
    echo "Container '$CONTAINER' exists but is stopped ($status). Starting it."
    docker start "$CONTAINER" >/dev/null
  fi
else
  docker run -d \
    --name "$CONTAINER" \
    --platform linux/amd64 \
    -e "BUILD_PARALLEL=${BUILD_PARALLEL:-6}" \
    "$IMAGE"
  echo "Started container '$CONTAINER'."
fi

cat <<EOF

Environment is ready. Next steps:

  1. Start the (multi-hour) compile — runs synchronously in this shell,
     keep the session open until it's done:
       docker exec -it $CONTAINER container-build.sh

  2. Optionally watch progress from another terminal:
       docker exec -it $CONTAINER tail -f /build/build.log

  3. Once it's done, stage + pull out the built browser:
       docker exec $CONTAINER container-collect.sh
       docker cp $CONTAINER:/artifacts/. ./artifacts/

EOF
