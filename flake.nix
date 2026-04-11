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

          cudaPackages = pkgs.cudaPackages_13;

          # Build llguidance as a proper Rust package (matching caleb-nix pattern)
          llguidance = pkgs.rustPlatform.buildRustPackage rec {
            pname = "llguidance";
            version = "1.0.1";
            src = pkgs.fetchFromGitHub {
              owner = "guidance-ai";
              repo = "llguidance";
              rev = "d795912fedc7d393de740177ea9ea761e7905774";
              hash = "sha256-LiardZnaXD5kc+p9c+UYBbtBb7+2ycWqEGCp3aaqHBs=";
            };
            cargoHash = "sha256-VyLTa+1iEY/Z3/4DUIAcjHH0MxLMGtlpcsy2zvmg3b8=";
            nativeBuildInputs = [ pkgs.pkg-config ];
            buildInputs = [ pkgs.oniguruma pkgs.openssl ];
            env.RUSTONIG_SYSTEM_LIBONIG = true;
            buildAndTestSubdir = "parser";
            postInstall = ''
              mkdir -p $out/include
              cp parser/llguidance.h $out/include/
            '';
            doCheck = false;
          };

          llama-cpp-cuda =
            let
              # Helper to enable HTTPS support
              withHttps = pkg: pkg.overrideAttrs (old: {
                nativeBuildInputs = (old.nativeBuildInputs or []) ++ [ pkgs.pkg-config ];
                buildInputs = (old.buildInputs or []) ++ [ pkgs.openssl ];
                cmakeFlags = (old.cmakeFlags or []) ++ ["-DLLAMA_OPENSSL=ON" "-DLLAMA_HTTPLIB=ON"];
              });

              # Helper to enable llguidance support (matching caleb-nix pattern)
              withLlguidance = pkg: pkg.overrideAttrs (old: {
                pname = old.pname + "-llguidance";
                nativeBuildInputs = (old.nativeBuildInputs or []) ++ [ pkgs.python3 ];
                buildInputs = (old.buildInputs or []) ++ [ llguidance pkgs.oniguruma ];
                cmakeFlags = (old.cmakeFlags or []) ++ ["-DLLAMA_LLGUIDANCE=ON"];
                postPatch = (old.postPatch or "") + ''
                  python3 -c '
import re, sys

replacement = """
if (LLAMA_LLGUIDANCE)
    target_compile_definitions(''${TARGET} PUBLIC LLAMA_USE_LLGUIDANCE)
    add_library(llguidance STATIC IMPORTED)
    set_target_properties(llguidance PROPERTIES
        IMPORTED_LOCATION ${llguidance}/lib/libllguidance.a)
    target_include_directories(''${TARGET} PRIVATE ${llguidance}/include)
    target_link_libraries(''${TARGET} PRIVATE llguidance onig ssl crypto)
    if (WIN32)
        target_link_libraries(''${TARGET} PRIVATE ws2_32 userenv ntdll bcrypt)
    endif()
endif()
"""

path = "common/CMakeLists.txt"
text = open(path).read()

# Match the entire if(LLAMA_LLGUIDANCE)...endif() block
pattern = r"if \(LLAMA_LLGUIDANCE\).*?^endif\(\)$"
new_text, count = re.subn(pattern, replacement.strip(), text,
                           flags=re.DOTALL | re.MULTILINE)

if count != 1:
    print(f"ERROR: expected 1 replacement, got {count}", file=sys.stderr)
    sys.exit(1)

open(path, "w").write(new_text)
print("llguidance block replaced successfully")
'
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
                "-DLLAMA_BUILD_SERVER=ON"
                "-DLLAMA_BUILD_EXAMPLES=OFF"
                "-DLLAMA_BUILD_TOOLS=OFF"
                "-DLLAMA_BUILD_TESTS=OFF"
                "-DCMAKE_CUDA_ARCHITECTURES=75;80;86;89;90;100"
              ];
            })));

          # Slim version for container: only server and libraries
          # Note: CUDA runtime libraries (libcuda.so, libcublas.so, etc.) are NOT included
          # and must be provided by the host (e.g. via nvidia-container-toolkit)
          llama-cpp-cuda-slim = pkgs.runCommand "llama-cpp-cuda-slim" { } ''
            mkdir -p $out/bin $out/lib
            cp ${llama-cpp-cuda}/bin/llama-server $out/bin/
            # Collect all shared libraries from bin and lib
            find ${llama-cpp-cuda} -name "*.so*" -exec cp -P {} $out/lib/ \;
          '';

          docker-image = pkgs.dockerTools.buildLayeredImage {
            name = "ghcr.io/bowmanjd/llama-cpp-cuda";
            tag = "b8744-cuda13";
            contents = [
              llama-cpp-cuda-slim
              pkgs.dockerTools.binSh
              pkgs.dockerTools.caCertificates
            ];
            config = {
              Entrypoint = [ "/bin/llama-server" "--host" "0.0.0.0" "--port" "8000" ];
              Env = [
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
          cudaPackages = pkgs.cudaPackages_13;
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
