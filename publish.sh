#!/bin/sh
set -e

# Read version config from the single source of truth (config.json)
LLAMA_TAG=$(jq -r '.llamaCppTag' ./config.json)
CUDA_VER=$(jq -r '.cudaVersion' ./config.json)
TAG="ghcr.io/bowmanjd/llama-cpp-cuda:${LLAMA_TAG}-cuda${CUDA_VER}"

echo "Building container image with Nix..."
nix build .#container

echo "Cleaning up previous images and dangling layers..."
# Remove all images matching the repo name to save space
IMAGES=$(podman images -q ghcr.io/bowmanjd/llama-cpp-cuda)
if [ -n "$IMAGES" ]; then
    podman rmi -f $IMAGES 2>/dev/null || true
fi
# Also prune dangling images (often created by the 'podman commit' dating step)
podman image prune -f

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
