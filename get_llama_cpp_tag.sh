#!/bin/sh
set -e

# get_llama_cpp_tag.sh: Update llama.cpp tag in flake.nix and config.json

# Prioritize gh for finding the latest release tag
if command -v gh >/dev/null 2>&1; then
    NEW_TAG=$(gh release view --repo ggml-org/llama.cpp --json tagName --jq .tagName 2>/dev/null)
else
    # Fallback to git ls-remote if gh is unavailable
    # This finds the last tag matching the 'b[0-9]*' pattern
    NEW_TAG=$(git ls-remote --tags --sort='v:refname' https://github.com/ggml-org/llama.cpp.git | \
              grep -o 'refs/tags/b[0-9]*' | tail -n 1 | cut -d'/' -f3)
fi

if [ -z "$NEW_TAG" ]; then
    echo "Error: Could not determine latest llama.cpp tag" >&2
    exit 1
fi

echo "Latest llama.cpp tag: $NEW_TAG"

# Update config.json
if [ -f "config.json" ]; then
    sed "s/\"llamaCppTag\": \".*\"/\"llamaCppTag\": \"$NEW_TAG\"/" config.json > config.json.tmp && mv config.json.tmp config.json
    echo "Updated config.json"
else
    echo "Warning: config.json not found" >&2
fi

# Update flake.nix
if [ -f "flake.nix" ]; then
    # Matches url = "github:ggml-org/llama.cpp/<tag>"; and replaces the tag
    sed "s|\(url = \"github:ggml-org/llama.cpp/\)[^\"]*\(.*\)|\1$NEW_TAG\2|" flake.nix > flake.nix.tmp && mv flake.nix.tmp flake.nix
    echo "Updated flake.nix"
else
    echo "Warning: flake.nix not found" >&2
fi

echo "Done. Latest tag is $NEW_TAG."
