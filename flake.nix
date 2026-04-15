{
  description = "llama.cpp with CUDA support and optimized features";

  inputs = {
    # Switched to nixos-unstable as suggested to ensure synchronicity and latest python packages are available natively
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    llama-cpp = {
      # NOTE: Keep this URL in sync with llamaCppTag in config.json
      url = "github:ggml-org/llama.cpp/b8793";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = {
    self,
    nixpkgs,
    llama-cpp,
  }: let
    cfg = builtins.fromJSON (builtins.readFile ./config.json);

    # Validation: Ensure flake input matches config.json
    inputTag = llama-cpp.original.ref or "unknown";
    _ =
      if inputTag != cfg.llamaCppTag
      then builtins.trace "WARNING: flake.nix input tag (${inputTag}) does not match config.json (${cfg.llamaCppTag})" null
      else null;

    supportedSystems = ["x86_64-linux" "aarch64-linux"];
    forAllSystems = nixpkgs.lib.genAttrs supportedSystems;
  in {
    packages = forAllSystems (system: let
      pkgs = import nixpkgs {
        inherit system;
        config.allowUnfree = true;
        config.cudaSupport = true;
      };

      cudaPackages = pkgs.${cfg.cudaPkgAttr};

      # Build llguidance as a proper Rust package
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
        nativeBuildInputs = [pkgs.pkg-config];
        buildInputs = [pkgs.oniguruma pkgs.openssl];
        env.RUSTONIG_SYSTEM_LIBONIG = true;
        buildAndTestSubdir = "parser";
        postInstall = ''
          mkdir -p $out/include
          cp parser/llguidance.h $out/include/
        '';
        doCheck = false;
      };

      # ---> HERE is where llama-cpp-cuda is defined <---
      llama-cpp-cuda = let
        # Helper to enable HTTPS support
        withHttps = pkg:
          pkg.overrideAttrs (old: {
            nativeBuildInputs = (old.nativeBuildInputs or []) ++ [pkgs.pkg-config];
            buildInputs = (old.buildInputs or []) ++ [pkgs.openssl];
            cmakeFlags = (old.cmakeFlags or []) ++ ["-DLLAMA_OPENSSL=ON" "-DLLAMA_HTTPLIB=ON"];
          });

        # Helper to enable llguidance support
        withLlguidance = pkg:
          pkg.overrideAttrs (old: {
            pname = old.pname + "-llguidance";
            nativeBuildInputs = (old.nativeBuildInputs or []) ++ [pkgs.python3];
            buildInputs = (old.buildInputs or []) ++ [llguidance pkgs.oniguruma];
            cmakeFlags = (old.cmakeFlags or []) ++ ["-DLLAMA_LLGUIDANCE=ON"];
            postPatch =
              (old.postPatch or "")
              + ''
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
          cmakeFlags =
            (old.cmakeFlags or [])
            ++ [
              "-DGGML_BACKEND_DL=ON"
              "-DLLAMA_BUILD_SERVER=ON"
              "-DLLAMA_BUILD_EXAMPLES=OFF"
              "-DLLAMA_BUILD_TOOLS=ON"
              "-DLLAMA_BUILD_TESTS=OFF"
              "-DCMAKE_CUDA_ARCHITECTURES=75;80;86;89;90;100"
            ];
        })));

      # Slim version for container: server, backend plugins, and runtime deps only
      llama-cpp-cuda-slim = let
        glibc = pkgs.glibc;
        gcc-lib = pkgs.stdenv.cc.cc.lib;
        gcc-libgcc = pkgs.gccForLibs.lib;
        libidn2 = pkgs.libidn2.out;
        libunistring = pkgs.libunistring.out;
        openssl = pkgs.openssl.out;
        oniguruma = pkgs.oniguruma.lib;
        cudart = cudaPackages.cuda_cudart;
        cublas = cudaPackages.libcublas.lib;

        # 1. Base Python for standard library and shared objects
        pythonBase = pkgs.python3;

        # 2. Python environment populated with all Modal client dependencies natively via Nix
        pythonEnv = pkgs.python3.withPackages (ps:
          with ps; [
            protobuf
            grpcio
            grpclib
            synchronicity
            aiohttp
            certifi
            click
            toml
            typer
            fastapi
            watchfiles
            rich
          ]);

        zlib = pkgs.zlib.out;
        ncurses = pkgs.ncurses.out;
        libffi = pkgs.libffi.out;
        expat = pkgs.expat.out;
        mpdecimal = pkgs.mpdecimal.out;
        sqlite = pkgs.sqlite.out;
        readline = pkgs.readline.out;
        bzip2 = pkgs.bzip2.out;
        xz = pkgs.xz.out;
        util-linux = pkgs.util-linuxMinimal.lib;
      in
        pkgs.runCommand "llama-cpp-cuda-slim" {
          nativeBuildInputs = [pkgs.patchelf pkgs.removeReferencesTo pythonBase];
        } ''
          mkdir -p $out/bin $out/lib

          # Copy llama-server and backend plugins
          cp ${llama-cpp-cuda}/bin/llama-server $out/bin/
          cp -P ${llama-cpp-cuda}/bin/*.so $out/bin/ 2>/dev/null || true
          cp -P ${llama-cpp-cuda}/lib/*.so* $out/lib/

          # Copy python binaries from the pure base (Raw ELFs), avoiding the Nix wrapper script!
          cp -L ${pythonBase}/bin/python3 $out/bin/
          cp -L ${pythonBase}/bin/python $out/bin/

          cp -P ${pythonBase}/lib/libpython3.13.so* $out/lib/

          # Copy python standard library
          mkdir -p $out/lib/python3.13
          cp -a ${pythonBase}/lib/python3.13/* $out/lib/python3.13/
          chmod -R u+w $out/lib/python3.13

          # Layer the pythonEnv site-packages over the top
          # Use -RL to follow symlinks but NOT preserve the read-only permission from the store
          cp -RL ${pythonEnv}/lib/python3.13/site-packages/. $out/lib/python3.13/site-packages/
          chmod -R u+w $out/lib/python3.13

          rm -rf $out/lib/python3.13/test
          find $out/lib/python3.13 -name "__pycache__" -type d -exec rm -rf {} +

          # Copy only the runtime shared libraries we actually need
          for lib in libc.so.6 libm.so.6 libdl.so.2 libpthread.so.0 librt.so.1 ld-linux-x86-64.so.2 libnss_dns.so.2 libnss_files.so.2 libresolv.so.2; do
            cp -n ${glibc}/lib/$lib $out/lib/ 2>/dev/null || true
          done
          for lib in libstdc++.so.6 libgcc_s.so.1 libgomp.so.1; do
            cp -n ${gcc-lib}/lib/$lib $out/lib/ 2>/dev/null || true
          done
          cp -P ${openssl}/lib/libssl.so* $out/lib/
          cp -P ${openssl}/lib/libcrypto.so* $out/lib/
          cp -P ${oniguruma}/lib/libonig.so* $out/lib/
          cp -P ${cudart}/lib/libcudart.so* $out/lib/
          cp -P ${cublas}/lib/libcublas.so* $out/lib/
          cp -P ${cublas}/lib/libcublasLt.so* $out/lib/

          # Additional Python dependencies
          cp -P ${zlib}/lib/libz.so* $out/lib/
          cp -P ${ncurses}/lib/libncursesw.so* $out/lib/
          cp -P ${libffi}/lib/libffi.so* $out/lib/
          cp -P ${expat}/lib/libexpat.so* $out/lib/
          cp -P ${mpdecimal}/lib/libmpdec.so* $out/lib/
          cp -P ${sqlite}/lib/libsqlite3.so* $out/lib/
          cp -P ${readline}/lib/libreadline.so* $out/lib/
          cp -P ${bzip2}/lib/libbz2.so* $out/lib/
          cp -P ${xz}/lib/liblzma.so* $out/lib/
          cp -P ${util-linux}/lib/libuuid.so* $out/lib/

          # Make everything writable for patchelf
          chmod -R u+w $out

          glibc_skip_patchelf="ld-linux-x86-64.so.2 libc.so.6 libm.so.6 libdl.so.2 libpthread.so.0 librt.so.1 libnss_dns.so.2 libnss_files.so.2 libresolv.so.2"

          find $out/bin $out/lib -type f -exec file {} + | grep "ELF" | cut -d: -f1 | while read f; do
            basename_f=$(basename "$f")
            is_glibc_patchelf=false
            for s in $glibc_skip_patchelf; do
              if [ "$basename_f" = "$s" ]; then is_glibc_patchelf=true; break; fi
            done
            if [ "$is_glibc_patchelf" != "true" ]; then
              patchelf --set-rpath "/lib" "$f" 2>/dev/null || true
            fi

            # Remove references to all known store paths
            for store_path in ${llama-cpp-cuda} ${glibc} ${gcc-lib} ${openssl} ${oniguruma} \
                             ${cudart} ${cublas} ${gcc-libgcc} ${libidn2} ${libunistring} \
                             ${pythonBase} ${pythonEnv} ${zlib} ${ncurses} ${libffi} ${expat} ${mpdecimal} \
                             ${sqlite} ${readline} ${bzip2} ${xz} ${util-linux}; do
              remove-references-to -t "$store_path" "$f"
            done
          done

          # Scrub remaining /nix/store references from binaries.
          own_hash=$(basename $out | cut -c1-32)
          ${pythonBase}/bin/python3 -c "
          import os, re, sys
          own_hash = sys.argv[1].encode()
          root = sys.argv[2]
          pattern = re.compile(rb'/nix/store/([a-z0-9]{32})-')
          for dirpath, _, filenames in os.walk(root):
              for fn in filenames:
                  fp = os.path.join(dirpath, fn)
                  if os.path.islink(fp):
                      continue
                  try:
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
                  except Exception as e:
                      print(f'Error scrubbing {fp}: {e}')
          " "$own_hash" "$out"

          # Set the ELF interpreter to /lib (container root)
          patchelf --set-interpreter /lib/ld-linux-x86-64.so.2 $out/bin/llama-server
          patchelf --set-interpreter /lib/ld-linux-x86-64.so.2 $out/bin/python3
          patchelf --set-interpreter /lib/ld-linux-x86-64.so.2 $out/bin/python
        '';

      docker-image = pkgs.dockerTools.buildLayeredImage {
        name = "ghcr.io/bowmanjd/llama-cpp-cuda";
        tag = "${cfg.llamaCppTag}-cuda${cfg.cudaVersion}";
        contents = [
          llama-cpp-cuda-slim
          pkgs.dockerTools.caCertificates
          pkgs.busybox
        ];

        fakeRootCommands = ''
          mkdir -p ./usr/bin ./bin ./tmp ./lib64
          chmod 1777 ./tmp

          # Satisfy Modal's standard shebangs
          ln -s /bin/env ./usr/bin/env
          ln -s /bin/python3 ./usr/bin/python

          # Satisfy standard binaries injected by Modal (like add_python)
          ln -s /lib/ld-linux-x86-64.so.2 ./lib64/ld-linux-x86-64.so.2
        '';

        config = {
          # Entrypoint removed so Modal can execute its own commands
          Env = [
            "PATH=/usr/local/bin:/usr/bin:/bin"
            "LD_LIBRARY_PATH=/lib:/usr/lib64"
            "PYTHONHOME=/"
            # CRITICAL: Tell python where to find the site-packages we just copied!
            "PYTHONPATH=/lib/python3.13/site-packages"
            # Required for nvidia-container-toolkit to mount GPU drivers into the container
            "NVIDIA_VISIBLE_DEVICES=all"
            "NVIDIA_DRIVER_CAPABILITIES=compute,utility"
          ];
          ExposedPorts = {"8000/tcp" = {};};
        };
      };
    in {
      default = llama-cpp-cuda;
      llama-cpp = llama-cpp-cuda;
      container = docker-image;
      llama-cpp-cuda-slim = llama-cpp-cuda-slim;
      inherit llguidance;
    });
  };
}
