# llama.cpp with CUDA support

This flake provides an optimized build of `llama.cpp` with CUDA support.

Version configuration is managed in `config.json` — update `llamaCppTag` there to track a new llama.cpp release.

It incorporates several optimizations and features:
- CUDA Support
- HTTPS Support: Enabled via OpenSSL and internal httplib.
- LLGuidance Support: Integrated with the pre-built Rust `llguidance` package.
- Multi-variant CPU support: Built with `GGML_CPU_ALL_VARIANTS=ON` for portability.
- Supports a generous subset of NVIDIA GPUs: see `DCMAKE_CUDA_ARCHITECTURES` in `flake.nix` and https://developer.nvidia.com/cuda/gpus

## Building

You can build specific versions using their Nix attributes:

```bash
# Build llama.cpp binary for CUDA 12.9
nix build .#llama-cpp-12-9

# Build container for CUDA 13.0
nix build .#container-13-0
```

By default, `nix build .#container` or `nix build .#llama-cpp` will build the first version listed in `config.json`.

The container is configured to listen on port 8000 by default. Load it into podman (or use docker):

```bash
podman load < result
```

## Configuration

Versions and build options are managed in `config.json`:

```json
{
  "llamaCppTag": "b9133",
  "cudaVersions": {
    "13.0": {
      "pkgAttr": "cudaPackages_13_0",
      "architectures": "75;80;86;89;90;100"
    },
    "12.9": {
      "pkgAttr": "cudaPackages_12_9",
      "architectures": "75;80;86;89;90"
    }
  }
}
```

- `llamaCppTag`: The `llama.cpp` tag/branch to build.
- `cudaVersions`: A map of CUDA versions to their configuration.
  - `pkgAttr`: The Nixpkgs attribute for the CUDA package set.
  - `architectures`: Semi-colon separated list of CUDA architectures to target (e.g., `80` for A100, `89` for L4/L40S).

## Building

You can build specific versions using their Nix attributes:

```bash
# Build llama.cpp binary for CUDA 12.9
nix build .#llama-cpp-12-9

# Build container for CUDA 13.0
nix build .#container-13-0
```

## Publishing to GHCR

Ensure you are logged into GHCR first:

```bash
echo $classic_github_container_token | podman login ghcr.io -u USERNAME --password-stdin
```

Use the provided `publish.sh` script with the desired CUDA version (requires `podman`):

```bash
./publish.sh 13.0
```

