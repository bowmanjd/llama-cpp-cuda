# Agent Instructions: llama-cpp-cuda

This repository provides a standalone Nix flake for building an OCI container with `llama.cpp` with CUDA 13 support and specialized optimizations.

## Core Architectural Principles

1.  Strict Nix Pinning: we pin `nixpkgs` to the stable branch in the flake. This ensures stability while allowing updates via `nix flake update`. Don't change the branch unless directed by the user.
2.  Upstream Alignment: We track a specific `llama.cpp` tag in the flake. Don't change this unless directed by the user.
3.  Static Integration of llguidance: `llguidance` is built as a Rust `staticlib`.

## Research & Reference Repositories

The following repositories are provided for your research and reference. Treat them as read-only and ephemeral -- they are for your research only
   - `~/devel/caleb-nix`: Reference `~/devel/caleb-nix/nixos/pkgs/llama-cpp.nix` for the original optimization logic (HTTPS, LLGuidance).
   - `~/src/llama.cpp` (ggml-org): The upstream source. `~/src/llama.cpp/.devops/nix/` directory may offer insights for nix builds, and `.devops/cuda.Dockerfile` for insights for building the container
