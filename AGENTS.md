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

See README.md for instructions on building and deploying.

## Use Case

The container will be deployed on Modal. The script we are using is `serve.py`

It can be launched with `MODAL_FORCE_BUILD=1 modal serve serve.py`

You can research more about Modal at https://modal.com/llms.txt, but the following links are most relevant; read any of these that seem relevant to the task you are working on.

https://modal.com/docs/guide/existing-images.md (Explains how Modal handles entrypoints and environment variables for external registry images)
https://modal.com/docs/reference/modal.web_server.md (Technical reference for the decorator and how it monitors the specified port)
https://modal.com/docs/examples/llm_inference.md (The most relevant architectural example; it demonstrates deploying an LLM server as a web endpoint)
https://modal.com/docs/guide/gpu.md (Covers requesting specific GPU types and the underlying driver availability)
https://modal.com/docs/guide/volumes.md (Standard guide for high-performance read/write storage)
https://modal.com/docs/guide/model-weights.md (Explains best practices for the "cache-and-mount" pattern you are using for Hugging Face)
https://modal.com/docs/guide/environment_variables.md (Details on setting runtime variables at the App level)
