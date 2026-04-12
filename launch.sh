#!/bin/sh

HUB_PATH="${1:-${HF_HUB_CACHE:-${HOME}/.cache/huggingface/hub}}"

podman run -d \
	--replace \
  --name llama-cuda \
  -p 8000:8000 \
	-v "${HUB_PATH}:/hub" \
  -e HF_HUB_CACHE=/hub \
  ghcr.io/bowmanjd/llama-cpp-cuda:b8762-cuda13
