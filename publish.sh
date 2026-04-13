#!/bin/sh

# Read version config from the single source of truth (config.json)
LLAMA_TAG=$(jq -r '.llamaCppTag' ./config.json)
CUDA_VER=$(jq -r '.cudaVersion' ./config.json)
TAG="ghcr.io/bowmanjd/llama-cpp-cuda:${LLAMA_TAG}-cuda${CUDA_VER}"

echo "Building container image with Nix..."
nix build .#container

echo "Loading image into podman..."
podman load < result

echo "Refreshing image creation timestamp..."
# Nix images are bit-for-bit reproducible, which sets the date to 1970 (Unix Epoch).
# We "date" the image by committing a temporary container so registries show the correct time.
TMP_CONTAINER="stamp-date-$(date +%s)"
podman create --name "$TMP_CONTAINER" "$TAG"
podman commit "$TMP_CONTAINER" "$TAG"
podman rm "$TMP_CONTAINER"

echo "Pushing image to GHCR with podman..."
podman push "$TAG"

echo "Done!"
