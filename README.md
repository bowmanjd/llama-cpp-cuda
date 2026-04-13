# llama.cpp with CUDA support

This flake provides an optimized build of `llama.cpp` with CUDA support.

Version configuration is managed in `config.json` — update `llamaCppTag` there to track a new llama.cpp release.

It incorporates several optimizations and features:
- CUDA Support
- HTTPS Support: Enabled via OpenSSL and internal httplib.
- LLGuidance Support: Integrated with the pre-built Rust `llguidance` package.
- Multi-variant CPU support: Built with `GGML_CPU_ALL_VARIANTS=ON` for portability.
- Supports a generous subset of NVIDIA GPUs: see `DCMAKE_CUDA_ARCHITECTURES` in `flake.nix` and https://developer.nvidia.com/cuda/gpus

## Building the Package

To build the `llama-cpp` package with CUDA support:

```bash
nix build .#llama-cpp
```

## Building the Container

To build the OCI container image:

```bash
nix build .#container
```

The container is configured to listen on port 8000 by default.

Load it into podman (or use docker):

```bash
podman load < result
```

The image tag is derived from `config.json`, following the pattern `ghcr.io/bowmanjd/llama-cpp-cuda:<llama-tag>-cuda<version>`.

## Publishing to GHCR

Ensure you are logged into GHCR first:

```bash
echo $classic_github_container_token | podman login ghcr.io -u USERNAME --password-stdin
```

Use the provided `publish.sh` script (requires `podman`):

```bash
./publish.sh
```

