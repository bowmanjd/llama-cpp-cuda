#!/bin/sh

podman run -d \
  --name llama-cuda \
  -p 8000:8000 \
  -v ~/.cache/huggingface:/cache \
  -e HF_CACHE_PATH=/cache \
  ghcr.io/bowmanjd/llama-cpp-cuda:b8762-cuda13
