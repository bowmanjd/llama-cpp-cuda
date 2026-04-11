#!/bin/sh

echo "Building container image with Nix..."
nix build .#container

echo "Loading image into podman..."
podman load < result

# The tag is defined in the flake
TAG="ghcr.io/bowmanjd/llama-cpp-cuda:b8744-cuda13"

echo "Pushing image to GHCR with podman..."
podman push "$TAG"

echo "Done!"
