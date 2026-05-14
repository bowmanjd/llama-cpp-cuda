#!/bin/sh
set -e

# Usage: ./publish.sh <cuda_version>
# Example: ./publish.sh 13.0

if [ -z "$1" ]; then
    echo "Usage: $0 <cuda_version>"
    echo "Available versions in config.json:"
    jq -r '.cudaVersions | keys[]' ./config.json
    exit 1
fi

CUDA_VER=$1
# Check if version exists in config.json
if ! jq -e ".cudaVersions[\"$CUDA_VER\"]" ./config.json > /dev/null; then
    echo "Error: CUDA version $CUDA_VER not found in config.json"
    exit 1
fi

# Read llama tag from config.json
LLAMA_TAG=$(jq -r '.llamaCppTag' ./config.json)

# Convert 13.0 to 13-0 for nix attribute
SLUG=$(echo "$CUDA_VER" | tr '.' '-')
ATTR="container-$SLUG"
TAG="ghcr.io/bowmanjd/llama-cpp-cuda:${LLAMA_TAG}-cuda${CUDA_VER}"

echo "Building container image for CUDA $CUDA_VER (attribute $ATTR)..."
nix build ".#$ATTR"

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
