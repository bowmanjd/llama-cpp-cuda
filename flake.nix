{
  description = "llama.cpp with CUDA support and optimized features";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.11";
    llama-cpp = {
      # NOTE: Keep this URL in sync with llamaCppTag in config.json
      url = "github:ggml-org/llama.cpp/b8793";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, llama-cpp }:
    let
      cfg = builtins.fromJSON (builtins.readFile ./config.json);

      # Validation: Ensure flake input matches config.json
      # This helps maintain the "single source of truth" goal despite flake limitations.
      inputTag = llama-cpp.original.ref or "unknown";
      _ = if inputTag != cfg.llamaCppTag then
        builtins.trace "WARNING: flake.nix input tag (${inputTag}) does not match config.json (${cfg.llamaCppTag})" null
      else null;

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

          cudaPackages = pkgs.${cfg.cudaPkgAttr};

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
                llamaVersion = cfg.llamaCppTag;
              };
            in
            withLlguidance (withHttps (base.overrideAttrs (old: {
              cmakeFlags = (old.cmakeFlags or []) ++ [
                "-DGGML_BACKEND_DL=ON"
                "-DLLAMA_BUILD_SERVER=ON"
                "-DLLAMA_BUILD_EXAMPLES=OFF"
                "-DLLAMA_BUILD_TOOLS=ON"
                "-DLLAMA_BUILD_TESTS=OFF"
                "-DCMAKE_CUDA_ARCHITECTURES=75;80;86;89;90;100"
              ];
            })));

          # Slim version for container: server, backend plugins, and runtime deps only
          # Bundles all needed shared libs and rewrites RPATHs to break nix store references
          # Note: libcuda.so.1 (the driver API) is NOT included and must be provided by the host
          llama-cpp-cuda-slim =
            let
              glibc = pkgs.glibc;
              gcc-lib = pkgs.stdenv.cc.cc.lib;
              gcc-libgcc = pkgs.gccForLibs.lib;
              libidn2 = pkgs.libidn2.out;
              libunistring = pkgs.libunistring.out;
              openssl = pkgs.openssl.out;
              oniguruma = pkgs.oniguruma.lib;
              cudart = cudaPackages.cuda_cudart;
              cublas = cudaPackages.libcublas.lib;
            in
            pkgs.runCommand "llama-cpp-cuda-slim" {
              nativeBuildInputs = [ pkgs.patchelf pkgs.removeReferencesTo pkgs.python3 ];
            } ''
            mkdir -p $out/bin $out/lib

            # Copy llama-server and backend plugins
            cp ${llama-cpp-cuda}/bin/llama-server $out/bin/
            cp -P ${llama-cpp-cuda}/bin/*.so $out/bin/ 2>/dev/null || true
            cp -P ${llama-cpp-cuda}/lib/*.so* $out/lib/

            # Copy only the runtime shared libraries we actually need
            # glibc core
            for lib in libc.so.6 libm.so.6 libdl.so.2 libpthread.so.0 librt.so.1 ld-linux-x86-64.so.2 libnss_dns.so.2 libnss_files.so.2 libresolv.so.2; do
              cp -n ${glibc}/lib/$lib $out/lib/ 2>/dev/null || true
            done
            # gcc runtime (only libstdc++, libgcc_s, libgomp)
            for lib in libstdc++.so.6 libgcc_s.so.1 libgomp.so.1; do
              cp -n ${gcc-lib}/lib/$lib $out/lib/ 2>/dev/null || true
            done
            # openssl
            cp -P ${openssl}/lib/libssl.so* $out/lib/
            cp -P ${openssl}/lib/libcrypto.so* $out/lib/
            # oniguruma
            cp -P ${oniguruma}/lib/libonig.so* $out/lib/
            # CUDA runtime libs (bundled so nvidia-container-toolkit isn't needed for these)
            cp -P ${cudart}/lib/libcudart.so* $out/lib/
            cp -P ${cublas}/lib/libcublas.so* $out/lib/
            cp -P ${cublas}/lib/libcublasLt.so* $out/lib/

            # Make everything writable for patchelf
            chmod -R u+w $out

            # Rewrite RPATHs to /lib (the container root path) and strip nix store refs.
            # glibc core files must not be touched by patchelf because it corrupts ld-linux (segfault).
            # We no longer skip them for remove-references-to because we DO want to strip glibc refs.
            glibc_skip_patchelf="ld-linux-x86-64.so.2 libc.so.6 libm.so.6 libdl.so.2 libpthread.so.0 librt.so.1 libnss_dns.so.2 libnss_files.so.2 libresolv.so.2"
            for f in $out/bin/llama-server $out/bin/*.so $out/lib/*.so*; do
              if [ -f "$f" ] && ! [ -L "$f" ]; then
                basename_f=$(basename "$f")
                is_glibc_patchelf=false
                for s in $glibc_skip_patchelf; do
                  if [ "$basename_f" = "$s" ]; then is_glibc_patchelf=true; break; fi
                done
                if [ "$is_glibc_patchelf" != "true" ]; then
                  patchelf --set-rpath "/lib" "$f" 2>/dev/null || true
                fi
                remove-references-to -t ${llama-cpp-cuda} "$f"
                remove-references-to -t ${glibc} "$f"
                remove-references-to -t ${gcc-lib} "$f"
                remove-references-to -t ${openssl} "$f"
                remove-references-to -t ${oniguruma} "$f"
                remove-references-to -t ${cudart} "$f"
                remove-references-to -t ${cublas} "$f"
                remove-references-to -t ${gcc-libgcc} "$f"
                remove-references-to -t ${libidn2} "$f"
                remove-references-to -t ${libunistring} "$f"
              fi
            done

            # Scrub remaining /nix/store references from binaries.
            # We NO LONGER skip glibc internals because we DO want to strip glibc refs,
            # and since we copied the NSS libraries into /lib, libc.so.6 will find them.
            own_hash=$(basename $out | cut -c1-32)
            python3 -c "
import os, re, sys
own_hash = sys.argv[1].encode()
root = sys.argv[2]
pattern = re.compile(rb'/nix/store/([a-z0-9]{32})-')
for dirpath, _, filenames in os.walk(root):
    for fn in filenames:
        fp = os.path.join(dirpath, fn)
        if os.path.islink(fp):
            continue
        with open(fp, 'rb') as f:
            data = f.read()
        new_data = data
        for m in set(pattern.findall(data)):
            if m != own_hash and m != b'eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee':
                new_data = new_data.replace(m, b'eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee')
        if new_data != data:
            with open(fp, 'wb') as f:
                f.write(new_data)
            print(f'Scrubbed references in {fp}')
" "$own_hash" "$out"

            # Set the ELF interpreter to /lib (container root), not $out/lib
            patchelf --set-interpreter /lib/ld-linux-x86-64.so.2 $out/bin/llama-server
          '';

          docker-image = pkgs.dockerTools.buildLayeredImage {
            name = "ghcr.io/bowmanjd/llama-cpp-cuda";
            tag = "${cfg.llamaCppTag}-cuda${cfg.cudaVersion}";
            contents = [
              llama-cpp-cuda-slim
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
          python3 = pkgs.python3;
          inherit llguidance;
        });
    };
}
