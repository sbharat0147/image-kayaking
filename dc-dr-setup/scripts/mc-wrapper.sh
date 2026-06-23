#!/bin/bash
docker run --rm -i --network host \
  -v "$HOME/.mc:/root/.mc" \
  minio/mc:RELEASE.2024-11-17T19-35-25Z "$@"
