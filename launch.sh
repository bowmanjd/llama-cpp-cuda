#!/bin/sh

# Read version config from the single source of truth (config.json)
LLAMA_TAG=$(jq -r '.llamaCppTag' ./config.json)
CUDA_VER=$(jq -r '.cudaVersion' ./config.json)
IMAGE_TAG="ghcr.io/bowmanjd/llama-cpp-cuda:${LLAMA_TAG}-cuda${CUDA_VER}"

HUB_PATH="${1:-${HF_HUB_CACHE:-${HOME}/.cache/huggingface/hub}}"

podman run -d \
	--replace \
  --name llama-cuda \
  -p 8000:8000 \
	-v "${HUB_PATH}:/hub" \
  -e HF_HUB_CACHE=/hub \
  "$IMAGE_TAG"
