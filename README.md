# llama.cpp with CUDA 13

This flake provides an optimized build of `llama.cpp` using CUDA 13.0 support, based on tag `b8762`.

It incorporates several optimizations and features used in the `caleb-nix` configuration:
- **CUDA 13 Support**: Uses `cudaPackages_13` (13.0.2).
- **HTTPS Support**: Enabled via OpenSSL and internal httplib.
- **LLGuidance Support**: Integrated with the pre-built Rust `llguidance` package.
- **Multi-variant CPU support**: Built with `GGML_CPU_ALL_VARIANTS=ON` for portability.
- **Dynamic Backend**: Built with `GGML_BACKEND_DL=ON`.

## Building the Package

To build the `llama-cpp` package with CUDA 13 support:

```bash
nix build .#llama-cpp
```

## Building the Container

To build the OCI container image (optimized for GHCR):

```bash
nix build .#container
```

The container is configured to listen on **port 8000** by default.

Load it into podman:

```bash
podman load < result
```

The image is tagged as `ghcr.io/bowmanjd/llama-cpp-cuda:b8762-cuda13`.

## Publishing to GHCR

Use the provided `publish.sh` script (requires `podman`):

```bash
./publish.sh
```

Ensure you are logged into GHCR first:

```bash
echo $classic_github_container_token | podman login ghcr.io -u USERNAME --password-stdin
```
