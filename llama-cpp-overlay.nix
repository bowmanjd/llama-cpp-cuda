# File: ./llama-cpp-overlay.nix
#
# Nixpkgs overlay for customizing llama-cpp packages with CUDA,
# llguidance, HTTPS support, and other options.
{
  inputs,
  lib,
  config ? {},
  llamaPackages ? null,
  ...
}: final: prev: let
  system = prev.stdenv.hostPlatform.system;

  # Use provided llamaPackages or evaluate upstream overlay if not passed
  resolvedLlamaPackages =
    if llamaPackages != null then llamaPackages
    else (inputs.llama-cpp.overlays.default final prev).llamaPackages;

  # Source override
  llamaCppSrc =
    if config ? llamaCppSrc && config.llamaCppSrc != null then
      config.llamaCppSrc
    else if config ? llamaCppTag && config.llamaCppTag != null && config ? llamaCppHash && config.llamaCppHash != null then
      prev.fetchFromGitHub {
        owner = "ggml-org";
        repo = "llama.cpp";
        rev = config.llamaCppTag;
        hash = config.llamaCppHash;
      }
    else
      null;

  withSrc = pkg:
    if llamaCppSrc != null then
      pkg.overrideAttrs (old: {
        src = llamaCppSrc;
        version =
          if config ? llamaCppTag && config.llamaCppTag != null
          then config.llamaCppTag
          else old.version + "-custom";
      })
    else
      pkg;

  # CUDA package resolution
  cudaPkgAttrFromVersion = if config ? cudaVersion && config.cudaVersion != null then
    "cudaPackages_" + (lib.replaceStrings ["."] ["_"] config.cudaVersion)
    else null;

  resolvedCudaPackages =
    if config ? cudaPackages && config.cudaPackages != null then
      config.cudaPackages
    else if config ? cudaPkgAttr && config.cudaPkgAttr != null && prev ? ${config.cudaPkgAttr} then
      prev.${config.cudaPkgAttr}
    else if cudaPkgAttrFromVersion != null && prev ? ${cudaPkgAttrFromVersion} then
      prev.${cudaPkgAttrFromVersion}
    else
      prev.cudaPackages or null;

  # ROCm package resolution
  rocmMajorVersion = if config ? rocmVersion && config.rocmVersion != null then
    builtins.head (lib.splitString "." config.rocmVersion)
    else null;

  rocmPkgAttrFromVersion = if rocmMajorVersion != null then
    "rocmPackages_${rocmMajorVersion}"
    else null;

  resolvedRocmPackages =
    if config ? rocmPackages && config.rocmPackages != null then
      config.rocmPackages
    else if config ? rocmPkgAttr && config.rocmPkgAttr != null && prev ? ${config.rocmPkgAttr} then
      prev.${config.rocmPkgAttr}
    else if rocmPkgAttrFromVersion != null && prev ? ${rocmPkgAttrFromVersion} then
      prev.${rocmPkgAttrFromVersion}
    else
      prev.rocmPackages or null;

  # Native CPU optimization helper
  withNativeCpu = pkg:
    pkg.overrideAttrs (old: {
      pname = old.pname + "-native";
      cmakeFlags =
        (lib.lists.filter (flag: flag != "-DGGML_NATIVE=false") old.cmakeFlags)
        ++ [
          "-DGGML_NATIVE=ON"
        ];
      NIX_CFLAGS_COMPILE = (old.NIX_CFLAGS_COMPILE or "") + " -O3 -march=native -mtune=native";
      NIX_CXXSTDLIB_COMPILE = (old.NIX_CXXSTDLIB_COMPILE or "") + " -O3 -march=native -mtune=native";
    });

  # Enable HTTPS support
  withHttps = pkg:
    pkg.overrideAttrs (old: {
      nativeBuildInputs = (old.nativeBuildInputs or [ ]) ++ [ prev.pkg-config ];
      buildInputs = (old.buildInputs or [ ]) ++ [ prev.openssl ];
      cmakeFlags = (old.cmakeFlags or [ ]) ++ [
        "-DLLAMA_OPENSSL=ON"
        "-DLLAMA_HTTPLIB=ON"
      ];
    });

  # Build llguidance as a proper Rust package
  llguidance = prev.rustPlatform.buildRustPackage rec {
    pname = "llguidance";
    version = "1.0.1";

    src = prev.fetchFromGitHub {
      owner = "guidance-ai";
      repo = "llguidance";
      rev = "d795912fedc7d393de740177ea9ea761e7905774";
      hash = "sha256-LiardZnaXD5kc+p9c+UYBbtBb7+2ycWqEGCp3aaqHBs=";
    };

    cargoHash = "sha256-VyLTa+1iEY/Z3/4DUIAcjHH0MxLMGtlpcsy2zvmg3b8=";

    nativeBuildInputs = [prev.pkg-config];
    buildInputs = [prev.oniguruma prev.openssl];

    env = {
      RUSTONIG_SYSTEM_LIBONIG = true;
    };

    buildAndTestSubdir = ".";
    cargoBuildFlags = ["--package" "llguidance"];

    postInstall = ''
      mkdir -p $out/include
      cp parser/llguidance.h $out/include/
    '';

    doCheck = false;
  };

  # Enable llguidance support
  withLlguidance = pkg:
    pkg.overrideAttrs (old: {
      pname = old.pname + "-llguidance";
      buildInputs = (old.buildInputs or []) ++ [llguidance];
      cmakeFlags = (old.cmakeFlags or []) ++ ["-DLLAMA_LLGUIDANCE=ON"];

      postPatch = (old.postPatch or "") + ''
        # Replace the entire LLAMA_LLGUIDANCE block with one using pre-built llguidance from Nix
        sed -i '/^if (LLAMA_LLGUIDANCE)/,/^endif()/{
          /^if (LLAMA_LLGUIDANCE)/c\
if (LLAMA_LLGUIDANCE)\
    # Use pre-built llguidance from Nix\
    add_library(llguidance STATIC IMPORTED)\
    set_target_properties(llguidance PROPERTIES IMPORTED_LOCATION ${llguidance}/lib/libllguidance.a)\
    target_include_directories(''${TARGET} PRIVATE ${llguidance}/include)\
    target_link_libraries(''${TARGET} PRIVATE llguidance)\
    target_compile_definitions(''${TARGET} PUBLIC LLAMA_USE_LLGUIDANCE)\
    if (WIN32)\
        target_link_libraries(''${TARGET} PRIVATE ws2_32 userenv ntdll bcrypt)\
    endif()
          /^if (LLAMA_LLGUIDANCE)/!{/^endif()/!d}
        }' common/CMakeLists.txt
      '';
    });

  # ROCm performance optimizations
  withRocmOptimizations = rocmPkgs: pkg:
    pkg.overrideAttrs (old: {
      cmakeFlags = (old.cmakeFlags or []) ++ [
        "-DGGML_HIP_GRAPHS=ON"
        "-DGGML_BACKEND_DL=ON"
        "-DGGML_CPU_ALL_VARIANTS=ON"
      ];
    });

  # Dual GPU support (CUDA + ROCm with dynamic backend loading)
  withDualGpu = {
    cudaPkgs,
    rocmPkgs,
    cudaArchitectures ? ["86"],
    rocmArchitectures ? ["gfx906"],
  }: pkg:
    pkg.overrideAttrs (old: {
      pname = old.pname + "-dual";

      nativeBuildInputs = (old.nativeBuildInputs or [])
        ++ [ cudaPkgs.cuda_nvcc rocmPkgs.clr prev.cmake prev.ninja ];

      buildInputs = (old.buildInputs or [])
        ++ [ cudaPkgs.cuda_cudart cudaPkgs.cuda_nvcc cudaPkgs.libcublas cudaPkgs.cuda_cccl ]
        ++ [ rocmPkgs.clr rocmPkgs.hipblas rocmPkgs.rocblas ];

      cmakeFlags = (lib.lists.filter (f:
        !(lib.hasPrefix "-DGGML_CUDA" f) &&
        !(lib.hasPrefix "-DGGML_HIP" f) &&
        !(lib.hasPrefix "-DCMAKE_CUDA_ARCHITECTURES" f) &&
        !(lib.hasPrefix "-DCMAKE_HIP_ARCHITECTURES" f) &&
        !(lib.hasPrefix "-DAMDGPU_TARGETS" f)
      ) (old.cmakeFlags or [])) ++ [
        "-DGGML_BACKEND_DL=ON"
        "-DGGML_CUDA=ON"
        "-DGGML_HIP=ON"
        "-DGGML_HIP_GRAPHS=ON"
        "-DGGML_CPU_ALL_VARIANTS=ON"
        "-DCMAKE_CUDA_ARCHITECTURES=${lib.concatStringsSep ";" cudaArchitectures}"
        "-DCMAKE_HIP_ARCHITECTURES=${lib.concatStringsSep ";" rocmArchitectures}"
        "-DCMAKE_HIP_COMPILER=${rocmPkgs.clr.hipClangPath}/clang++"
      ];

      preConfigure = (old.preConfigure or "") + ''
        export HIPCXX="${rocmPkgs.clr.hipClangPath}/clang"
        export HIP_PATH="${rocmPkgs.clr}"
        export ROCM_PATH="${rocmPkgs.clr}"
      '';
    });

  # Parameterized builder function
  buildLlamaCpp = {
    accel ? "cpu",
    native ? true,
    guidance ? false,
    enableHttps ? true,
    customCudaPackages ? null,
    customRocmPackages ? null,
    customCudaCapabilities ? null,
    customRocmTargets ? null,
  }:
    let
      basePkg = withSrc resolvedLlamaPackages.llama-cpp;

      cudaPkgs = if customCudaPackages != null then customCudaPackages else resolvedCudaPackages;
      rocmPkgs = if customRocmPackages != null then customRocmPackages else resolvedRocmPackages;

      isDual = accel == "dual";

      accelOverrideAttrs =
        if accel == "cuda" then
          {
            useCuda = true;
            useRocm = false;
            useVulkan = false;
          }
          // (lib.optionalAttrs (cudaPkgs != null) { cudaPackages = cudaPkgs; })
        else if accel == "rocm" then
          {
            useRocm = true;
            useCuda = false;
            useVulkan = false;
          }
          // (lib.optionalAttrs (rocmPkgs != null) { rocmPackages = rocmPkgs; })
        else if accel == "vulkan" then
          {
            useVulkan = true;
            useCuda = false;
            useRocm = false;
          }
        else
          {
            useCuda = false;
            useRocm = false;
            useVulkan = false;
          };

      withCudaArch = arches: pkg:
        if arches != null then
          pkg.overrideAttrs (old: {
            cmakeFlags = (lib.lists.filter (f: !(lib.hasPrefix "-DCMAKE_CUDA_ARCHITECTURES" f)) (old.cmakeFlags or []))
              ++ ["-DCMAKE_CUDA_ARCHITECTURES=${lib.concatStringsSep ";" arches}"];
          })
        else pkg;

      withRocmArch = arches: pkg:
        if arches != null then
          pkg.overrideAttrs (old: {
            cmakeFlags = (lib.lists.filter (f:
              !(lib.hasPrefix "-DAMDGPU_TARGETS" f) && !(lib.hasPrefix "-DGPU_TARGETS" f)
            ) (old.cmakeFlags or []))
              ++ ["-DAMDGPU_TARGETS=${lib.concatStringsSep ";" arches}"];
          })
        else pkg;

      basePkgWithAccel =
        if isDual then
          withDualGpu {
            cudaPkgs = cudaPkgs;
            rocmPkgs = rocmPkgs;
            cudaArchitectures = if customCudaCapabilities != null then customCudaCapabilities else ["86"];
            rocmArchitectures = if customRocmTargets != null then customRocmTargets else ["gfx906"];
          } (basePkg.override { useCuda = false; useRocm = false; useVulkan = false; })
        else
          basePkg.override accelOverrideAttrs;

      pkgWithAccel =
        if accel == "cuda" then withCudaArch customCudaCapabilities basePkgWithAccel
        else if accel == "rocm" then withRocmArch customRocmTargets basePkgWithAccel
        else basePkgWithAccel;

      pkgWithRocmOpts =
        if accel == "rocm" then withRocmOptimizations rocmPkgs pkgWithAccel
        else pkgWithAccel;

      pkgWithHttps = if enableHttps then withHttps pkgWithRocmOpts else pkgWithRocmOpts;
      pkgWithNative = if native then withNativeCpu pkgWithHttps else pkgWithHttps;
      pkgWithGuidance = if guidance then withLlguidance pkgWithNative else pkgWithNative;
    in
    pkgWithGuidance;

  customLlamaCpp = buildLlamaCpp {
    accel = config.acceleration or "cpu";
    native = config.nativeCpu or true;
    guidance = config.llguidance or false;
    enableHttps = config.https or true;
    customCudaCapabilities = config.cudaCapabilities or null;
    customRocmTargets = config.rocmTargets or null;
  };
in {
  # Standard variants
  llama-cpp-cpu = withHttps (withSrc resolvedLlamaPackages.llama-cpp);
  llama-cpp-vulkan = withHttps ((withSrc resolvedLlamaPackages.llama-cpp).override { useVulkan = true; useRocm = false; useCuda = false; });
  llama-cpp-cuda = withHttps ((withSrc resolvedLlamaPackages.llama-cpp).override ({ useCuda = true; useRocm = false; useVulkan = false; } // (lib.optionalAttrs (resolvedCudaPackages != null) { cudaPackages = resolvedCudaPackages; })));
  llama-cpp-rocm = withRocmOptimizations resolvedRocmPackages (withHttps ((withSrc resolvedLlamaPackages.llama-cpp).override ({ useRocm = true; useCuda = false; useVulkan = false; } // (lib.optionalAttrs (resolvedRocmPackages != null) { rocmPackages = resolvedRocmPackages; }))));

  # Native optimised
  llama-cpp-cpu-native = withNativeCpu final.llama-cpp-cpu;
  llama-cpp-vulkan-native = withNativeCpu final.llama-cpp-vulkan;
  llama-cpp-cuda-native = withNativeCpu final.llama-cpp-cuda;
  llama-cpp-rocm-native = withNativeCpu final.llama-cpp-rocm;

  # LLGuidance
  llama-cpp-cpu-llguidance = withLlguidance final.llama-cpp-cpu;
  llama-cpp-vulkan-llguidance = withLlguidance final.llama-cpp-vulkan;
  llama-cpp-cuda-llguidance = withLlguidance final.llama-cpp-cuda;
  llama-cpp-rocm-llguidance = withLlguidance final.llama-cpp-rocm;

  # Native + LLGuidance
  llama-cpp-cpu-native-llguidance = withLlguidance final.llama-cpp-cpu-native;
  llama-cpp-vulkan-native-llguidance = withLlguidance final.llama-cpp-vulkan-native;
  llama-cpp-cuda-native-llguidance = withLlguidance final.llama-cpp-cuda-native;
  llama-cpp-rocm-native-llguidance = withLlguidance final.llama-cpp-rocm-native;

  # Dual GPU
  llama-cpp-dual = withHttps (withDualGpu {
    cudaPkgs = resolvedCudaPackages;
    rocmPkgs = resolvedRocmPackages;
    cudaArchitectures = ["86"];
    rocmArchitectures = ["gfx906"];
  } (withSrc resolvedLlamaPackages.llama-cpp));

  llama-cpp-dual-native = withNativeCpu final.llama-cpp-dual;
  llama-cpp-dual-llguidance = withLlguidance final.llama-cpp-dual;
  llama-cpp-dual-native-llguidance = withLlguidance final.llama-cpp-dual-native;

  # Sensible targets
  llama-cpp = customLlamaCpp;
  llguidance = llguidance;
}
