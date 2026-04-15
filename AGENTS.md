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

## GPU/CUDA in the Container

The container uses `GGML_BACKEND_DL=ON`, which builds CUDA as a dynamically-loaded plugin (`libggml-cuda.so`). This has several implications:

1. **Backend plugin search path**: `ggml_backend_load_all()` searches for `libggml-*.so` plugins in the **executable's directory** (via `/proc/self/exe`), NOT in the `libggml.so` directory. The plugins must be in the same directory as `llama-server` (i.e., `/bin/` in the container).

2. **NVIDIA driver env vars are required**: The container image MUST set `NVIDIA_VISIBLE_DEVICES=all` and `NVIDIA_DRIVER_CAPABILITIES=compute,utility`. Without these, the nvidia-container-toolkit treats the container as non-GPU and never mounts `libcuda.so.1` into the container at all.

3. **Modal puts `libcuda.so.1` at `/usr/lib64/`**: This path MUST be in `LD_LIBRARY_PATH`. The slim build's patchelf step replaces all RPATHs with `/lib`, stripping the `/run/opengl-driver/lib` that the upstream nix `autoAddDriverRunpath` hook originally set. So `LD_LIBRARY_PATH` must compensate.

4. **Silent fallback**: In release builds (`NDEBUG`), if `libggml-cuda.so` fails to `dlopen` (e.g., because `libcuda.so.1` is missing), the error is completely silent and llama.cpp falls back to CPU-only. The symptom is `CPU_Mapped` in the load_tensors log instead of `CUDA0`.

## Use Case

The container will be deployed on Modal. The script we are using is `serve.py`

We do not follow the common Modal paradigm of "injecting" Python through an additional container layer. In fact, we don't even expose `pip` for installing Python packages; instead, we follow the nix way of using nixpkgs for the python dependencies.

The container can be launched on Modal with `modal serve serve.py` -- if needed, you can prefix it with `MODAL_FORCE_BUILD=1` to reload the container.

You can research more about Modal at https://modal.com/llms.txt, but the following links are most relevant; read any of these that seem relevant to the task you are working on.

https://modal.com/docs/guide/existing-images.md (Explains how Modal handles entrypoints and environment variables for external registry images)
https://modal.com/docs/reference/modal.web_server.md (Technical reference for the decorator and how it monitors the specified port)
https://modal.com/docs/examples/llm_inference.md (The most relevant architectural example; it demonstrates deploying an LLM server as a web endpoint)
https://modal.com/docs/guide/gpu.md (Covers requesting specific GPU types and the underlying driver availability)
https://modal.com/docs/guide/volumes.md (Standard guide for high-performance read/write storage)
https://modal.com/docs/guide/model-weights.md (Explains best practices for the "cache-and-mount" pattern you are using for Hugging Face)
https://modal.com/docs/guide/environment_variables.md (Details on setting runtime variables at the App level)
