#!/bin/sh

podman run -d \
	--replace \
  --name llama-cuda \
  -p 8000:8000 \
	-v ~/.cache/huggingface/hub:/hub \
  -e HF_HUB_CACHE=/hub \
  ghcr.io/bowmanjd/llama-cpp-cuda:b8762-cuda13
