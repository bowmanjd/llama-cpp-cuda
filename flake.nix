{
  description = "llama.cpp with CUDA support and optimized features";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    llama-cpp = {
      # NOTE: Keep this URL in sync with llamaCppTag in config.json
      url = "github:ggml-org/llama.cpp/b10066";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = {
    self,
    nixpkgs,
    llama-cpp,
  }@inputs: let
    cfg = builtins.fromJSON (builtins.readFile ./config.json);

    # Validation: Ensure flake input matches config.json
    inputTag = llama-cpp.original.ref or "unknown";
    _ =
      if inputTag != cfg.llamaCppTag
      then builtins.trace "WARNING: flake.nix input tag (${inputTag}) does not match config.json (${cfg.llamaCppTag})" null
      else null;

    supportedSystems = ["x86_64-linux" "aarch64-linux"];
    forAllSystems = nixpkgs.lib.genAttrs supportedSystems;

    # Helper to convert version string like "13.0" to attribute-safe slug "13-0"
    toSlug = v: builtins.replaceStrings ["."] ["-"] v;
  in {
    # Expose overlays (default and configurable)
    overlays = {
      default = final: prev:
        let
          upstream = llama-cpp.overlays.default final prev;
          customOverlay = import ./llama-cpp-overlay.nix {
            inherit inputs;
            lib = nixpkgs.lib;
            config = {
              llamaCppTag = cfg.llamaCppTag;
            };
            llamaPackages = upstream.llamaPackages;
          };
          customPackages = customOverlay final prev;
        in
        upstream // customPackages;

      configure = configAttrs: final: prev:
        let
          upstream = llama-cpp.overlays.default final prev;
          customOverlay = import ./llama-cpp-overlay.nix {
            inherit inputs;
            lib = nixpkgs.lib;
            config = configAttrs;
            llamaPackages = upstream.llamaPackages;
          };
          customPackages = customOverlay final prev;
        in
        upstream // customPackages;
    };

    packages = forAllSystems (system: let
      # Standard pkgs using our default overlay
      pkgs = import nixpkgs {
        inherit system;
        config.allowUnfree = true;
        config.cudaSupport = true;
        overlays = [
          self.overlays.default
        ];
      };

      # Import container helper for this system's pkgs
      containerUtils = import ./container.nix {
        inherit pkgs;
        lib = nixpkgs.lib;
        config = {
          includeModal = true;
        };
      };

      makeLlamaPackages = {
        cudaVersion,
        cudaPkgAttr,
        architectures,
      }: let
        cudaPkgs = pkgs.${cudaPkgAttr} // (
          if pkgs.${cudaPkgAttr} ? cccl
          then { cuda_cccl = pkgs.${cudaPkgAttr}.cccl; }
          else {}
        );

        # Generate custom llama-cpp package override for this specific CUDA version
        llama-cpp-cuda = let
          configuredPkgs = import nixpkgs {
            inherit system;
            config.allowUnfree = true;
            config.cudaSupport = true;
            overlays = [
              (self.overlays.configure {
                acceleration = "cuda";
                nativeCpu = false;
                llguidance = true;
                https = true;
                cudaPackages = cudaPkgs;
                cudaCapabilities = nixpkgs.lib.splitString ";" architectures;
              })
            ];
          };
        in
          configuredPkgs.llama-cpp;

        # Build slim and OCI container
        containerPair = containerUtils.makeContainerPair {
          llamaPackage = llama-cpp-cuda;
          cudaPackages = cudaPkgs;
          imageTag = "${cfg.llamaCppTag}-cuda${cudaVersion}";
        };
      in {
        llama-cpp = llama-cpp-cuda;
        slim = containerPair.slim;
        container = containerPair.container;
      };

      # Map over all CUDA versions in config.json
      versionedPackages = pkgs.lib.mapAttrs (version: vcfg:
        makeLlamaPackages {
          cudaVersion = version;
          cudaPkgAttr = vcfg.pkgAttr;
          architectures = vcfg.architectures;
        })
      cfg.cudaVersions;

      # Flatten the versioned packages into a single attribute set
      # e.g., container-13-0, llama-cpp-13-0, container-12-9, etc.
      flattenedPackages = pkgs.lib.concatMapAttrs (version: packages: let
        slug = toSlug version;
      in {
        "llama-cpp-${slug}" = packages.llama-cpp;
        "slim-${slug}" = packages.slim;
        "container-${slug}" = packages.container;
      })
      versionedPackages;

      # Default points to the first one in the list
      defaultVersion = builtins.elemAt (builtins.attrNames cfg.cudaVersions) 0;
      defaultSlug = toSlug defaultVersion;
    in
      flattenedPackages
      // {
        default = flattenedPackages."llama-cpp-${defaultSlug}";
        llama-cpp = flattenedPackages."llama-cpp-${defaultSlug}";
        llguidance = pkgs.llguidance;
        container = flattenedPackages."container-${defaultSlug}";
      });
  };
}
