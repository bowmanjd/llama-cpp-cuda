{
  description = "llama.cpp with CUDA 13 support and optimized features";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/cfa1f3da48ac9533e0114e90f20c0219612672a7";
    llama-cpp = {
      url = "github:ggml-org/llama.cpp/b8744";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, llama-cpp }:
    let
      supportedSystems = [ "x86_64-linux" "aarch64-linux" ];
      forAllSystems = nixpkgs.lib.genAttrs supportedSystems;
    in
    {
      packages = forAllSystems (system:
        let
          pkgs = import nixpkgs {
            inherit system;
            config.allowUnfree = true;
            config.cudaSupport = true;
          };

          # Use CUDA 13 specifically
          cudaPackages = pkgs.cudaPackages_13_0;
          lib = pkgs.lib;

          # Build llguidance as a proper Rust package (matching project's patterns)
          llguidance = pkgs.rustPlatform.buildRustPackage rec {
            pname = "llguidance";
            version = "1.0.1";
            src = pkgs.fetchFromGitHub {
              owner = "guidance-ai";
              repo = "llguidance";
              rev = "d795912fedc7d393de740177ea9ea761e7905774"; # v1.0.1
              hash = "sha256-LiardZnaXD5kc+p9c+UYBbtBb7+2ycWqEGCp3aaqHBs=";
            };
            cargoHash = "sha256-VyLTa+1iEY/Z3/4DUIAcjHH0MxLMGtlpcsy2zvmg3b8=";
            nativeBuildInputs = [ pkgs.pkg-config ];
            buildInputs = [ pkgs.oniguruma pkgs.openssl ];
            env.RUSTONIG_SYSTEM_LIBONIG = true;
            buildAndTestSubdir = ".";
            cargoBuildFlags = ["--package" "llguidance"];
            postInstall = ''
              mkdir -p $out/include
              cp parser/llguidance.h $out/include/
            '';
            doCheck = false;
          };

          # Build the final optimized CUDA package
          llama-cpp-cuda =
            let
              # Helper function to enable HTTPS support
              withHttps = pkg: pkg.overrideAttrs (old: {
                nativeBuildInputs = (old.nativeBuildInputs or []) ++ [ pkgs.pkg-config ];
                buildInputs = (old.buildInputs or []) ++ [ pkgs.openssl ];
                cmakeFlags = (old.cmakeFlags or []) ++ ["-DLLAMA_OPENSSL=ON" "-DLLAMA_HTTPLIB=ON"];
              });

              # Helper function to enable llguidance support
              withLlguidance = pkg: pkg.overrideAttrs (old: {
                pname = old.pname + "-llguidance";
                buildInputs = (old.buildInputs or []) ++ [ llguidance ];
                cmakeFlags = (old.cmakeFlags or []) ++ ["-DLLAMA_LLGUIDANCE=ON"];
                postPatch = (old.postPatch or "") + ''
                  sed -i '/^if (LLAMA_LLGUIDANCE)/,/^endif()/{
                    /^if (LLAMA_LLGUIDANCE)/c\
if (LLAMA_LLGUIDANCE)\
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

              base = pkgs.callPackage "${llama-cpp}/.devops/nix/package.nix" {
                inherit cudaPackages;
                useCuda = true;
                llamaVersion = "b8744";
              };
            in
            withLlguidance (withHttps (base.overrideAttrs (old: {
              cmakeFlags = (old.cmakeFlags or []) ++ [
                "-DGGML_BACKEND_DL=ON"
                "-DGGML_CPU_ALL_VARIANTS=ON"
                "-DLLAMA_BUILD_TESTS=OFF"
              ];
            })));

          # Container configuration
          docker-image = pkgs.dockerTools.buildLayeredImage {
            name = "ghcr.io/bowmanjd/llama-cpp-cuda";
            tag = "b8744-cuda13";
            contents = [
              llama-cpp-cuda
              pkgs.coreutils
              pkgs.dockerTools.binSh
              pkgs.dockerTools.caCertificates
            ];
            config = {
              Entrypoint = [ "/bin/llama-server" "--port" "8000" ];
              Env = [
                "LLAMA_ARG_HOST=0.0.0.0"
                "LD_LIBRARY_PATH=/lib"
              ];
              ExposedPorts = { "8000/tcp" = {}; };
            };
          };
        in
        {
          default = llama-cpp-cuda;
          llama-cpp = llama-cpp-cuda;
          container = docker-image;
          inherit llguidance;
        });

      devShells = forAllSystems (system:
        let
          pkgs = import nixpkgs {
            inherit system;
            config.allowUnfree = true;
            config.cudaSupport = true;
          };
          cudaPackages = pkgs.cudaPackages_13_0;
        in
        {
          default = pkgs.mkShell {
            buildInputs = with pkgs; [
              cmake
              ninja
              pkg-config
              git
              openssl
              cudaPackages.cuda_nvcc
              cudaPackages.cuda_cudart
              cudaPackages.libcublas
            ];
            shellHook = ''
              export CUDA_PATH=${cudaPackages.cuda_nvcc}
              export LD_LIBRARY_PATH=${pkgs.lib.makeLibraryPath [ cudaPackages.cuda_cudart cudaPackages.libcublas ]}:$LD_LIBRARY_PATH
            '';
          };
        });
    };
}
