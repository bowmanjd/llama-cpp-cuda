# File: ./container.nix
#
# Container building utilities for llama-cpp-cuda packages.
# Creates slim, portable packages and OCI container images.
{
  pkgs,
  lib,
  config ? {},
}: let
  # Container configuration with defaults
  containerConfig = {
    includeModal = config.includeModal or false;
    imageName = config.imageName or "ghcr.io/bowmanjd/llama-cpp-cuda";
    imageTag = config.imageTag or null;
  };

  # Detect acceleration type from package name
  getAccelType = pkg:
    let name = pkg.pname or pkg.name or "";
    in
      if lib.hasInfix "cuda" name then "cuda"
      else if lib.hasInfix "rocm" name then "rocm"
      else if lib.hasInfix "vulkan" name then "vulkan"
      else if lib.hasInfix "dual" name then "dual"
      else "cpu";

  # Build a slim, portable package from any llama-cpp variant
  makeSlimPackage = {
    llamaPackage,
    cudaPackages ? pkgs.cudaPackages,
    rocmPackages ? pkgs.rocmPackages or null,
    includeModal ? containerConfig.includeModal,
  }: let
    accelType = getAccelType llamaPackage;

    # Core runtime libraries (always needed)
    glibc = pkgs.glibc;
    gcc-lib = pkgs.stdenv.cc.cc.lib;
    openssl = pkgs.openssl.out;
    oniguruma = pkgs.oniguruma.lib;

    # CUDA runtime libraries
    cudaLibs = lib.optionals (accelType == "cuda" || accelType == "dual") [
      cudaPackages.cuda_cudart
      cudaPackages.libcublas.lib
    ];

    # ROCm runtime libraries
    rocmLibs = lib.optionals ((accelType == "rocm" || accelType == "dual") && rocmPackages != null) [
      rocmPackages.clr
      rocmPackages.rocblas
      rocmPackages.hipblas
    ];

    # Vulkan runtime libraries
    vulkanLibs = lib.optionals (accelType == "vulkan") [
      pkgs.vulkan-loader
    ];

    # Python for Modal support
    pythonBase = pkgs.python3;
    pyVer = pythonBase.pythonVersion;
    pythonEnv = pkgs.python3.withPackages (ps: with ps; [
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

    # Additional Python dependencies
    pythonRuntimeLibs = [
      pkgs.zlib.out
      pkgs.ncurses.out
      pkgs.libffi.out
      pkgs.expat.out
      pkgs.mpdecimal.out
      pkgs.sqlite.out
      pkgs.readline.out
      pkgs.bzip2.out
      pkgs.xz.out
      pkgs.util-linuxMinimal.lib
    ];

    # Build store paths list for reference removal
    allStorePaths = [llamaPackage glibc gcc-lib openssl oniguruma]
      ++ cudaLibs
      ++ rocmLibs
      ++ vulkanLibs
      ++ (lib.optionals includeModal ([pythonBase pythonEnv] ++ pythonRuntimeLibs));

    storePathsStr = lib.concatStringsSep " " (map toString allStorePaths);
  in
    pkgs.runCommand "llama-cpp-slim-${accelType}" {
      nativeBuildInputs = [pkgs.patchelf pkgs.removeReferencesTo pythonBase];
      passthru = {
        inherit accelType llamaPackage;
        isSlim = true;
      };
    } ''
      mkdir -p $out/bin $out/lib

      # Copy llama-server and backend plugins / shared libraries
      cp ${llamaPackage}/bin/llama-server $out/bin/
      cp -P ${llamaPackage}/bin/*.so* $out/bin/ 2>/dev/null || true
      cp -P ${llamaPackage}/bin/*.so* $out/lib/ 2>/dev/null || true
      cp -P ${llamaPackage}/lib/*.so* $out/lib/ 2>/dev/null || true
      cp -P ${llamaPackage}/lib/*.so* $out/bin/ 2>/dev/null || true
      if [ -d ${llamaPackage}/lib64 ]; then
        cp -P ${llamaPackage}/lib64/*.so* $out/lib/ 2>/dev/null || true
        cp -P ${llamaPackage}/lib64/*.so* $out/bin/ 2>/dev/null || true
      fi


      # Copy core runtime libraries
      for lib in libc.so.6 libm.so.6 libdl.so.2 libpthread.so.0 librt.so.1 ld-linux-x86-64.so.2 libnss_dns.so.2 libnss_files.so.2 libresolv.so.2; do
        cp -n ${glibc}/lib/$lib $out/lib/ 2>/dev/null || true
      done
      for lib in libstdc++.so.6 libgcc_s.so.1 libgomp.so.1; do
        cp -n ${gcc-lib}/lib/$lib $out/lib/ 2>/dev/null || true
      done
      cp -P ${openssl}/lib/libssl.so* $out/lib/ 2>/dev/null || true
      cp -P ${openssl}/lib/libcrypto.so* $out/lib/ 2>/dev/null || true
      cp -P ${oniguruma}/lib/libonig.so* $out/lib/ 2>/dev/null || true

      ${lib.optionalString (accelType == "cuda" || accelType == "dual") ''
        # CUDA runtime libraries
        cp -P ${cudaPackages.cuda_cudart}/lib/libcudart.so* $out/lib/ 2>/dev/null || true
        cp -P ${cudaPackages.libcublas.lib}/lib/libcublas.so* $out/lib/ 2>/dev/null || true
        cp -P ${cudaPackages.libcublas.lib}/lib/libcublasLt.so* $out/lib/ 2>/dev/null || true
      ''}

      ${lib.optionalString ((accelType == "rocm" || accelType == "dual") && rocmPackages != null) ''
        # ROCm runtime libraries
        cp -P ${rocmPackages.clr}/lib/libamdhip64.so* $out/lib/ 2>/dev/null || true
        cp -P ${rocmPackages.rocblas}/lib/librocblas.so* $out/lib/ 2>/dev/null || true
        cp -P ${rocmPackages.hipblas}/lib/libhipblas.so* $out/lib/ 2>/dev/null || true
      ''}

      ${lib.optionalString (accelType == "vulkan") ''
        # Vulkan runtime libraries
        cp -P ${pkgs.vulkan-loader}/lib/libvulkan.so* $out/lib/ 2>/dev/null || true
      ''}

      ${lib.optionalString includeModal ''
        # Python binaries (raw ELFs, not Nix wrapper scripts)
        cp -L ${pythonBase}/bin/python3 $out/bin/
        cp -L ${pythonBase}/bin/python $out/bin/
        cp -P ${pythonBase}/lib/libpython3*.so* $out/lib/ 2>/dev/null || true

        # Python standard library
        mkdir -p $out/lib/python${pyVer}
        cp -a ${pythonBase}/lib/python${pyVer}/* $out/lib/python${pyVer}/ 2>/dev/null || true
        chmod -R u+w $out/lib/python${pyVer} 2>/dev/null || true

        # Layer pythonEnv site-packages
        mkdir -p $out/lib/python${pyVer}/site-packages
        cp -RL ${pythonEnv}/lib/python${pyVer}/site-packages/. $out/lib/python${pyVer}/site-packages/ 2>/dev/null || true
        chmod -R u+w $out/lib/python${pyVer} 2>/dev/null || true

        # Clean up Python
        rm -rf $out/lib/python${pyVer}/test 2>/dev/null || true
        find $out/lib/python${pyVer} -name "__pycache__" -type d -exec rm -rf {} + 2>/dev/null || true

        # Python runtime dependencies
        cp -P ${pkgs.zlib.out}/lib/libz.so* $out/lib/ 2>/dev/null || true
        cp -P ${pkgs.ncurses.out}/lib/libncursesw.so* $out/lib/ 2>/dev/null || true
        cp -P ${pkgs.libffi.out}/lib/libffi.so* $out/lib/ 2>/dev/null || true
        cp -P ${pkgs.expat.out}/lib/libexpat.so* $out/lib/ 2>/dev/null || true
        cp -P ${pkgs.mpdecimal.out}/lib/libmpdec.so* $out/lib/ 2>/dev/null || true
        cp -P ${pkgs.sqlite.out}/lib/libsqlite3.so* $out/lib/ 2>/dev/null || true
        cp -P ${pkgs.readline.out}/lib/libreadline.so* $out/lib/ 2>/dev/null || true
        cp -P ${pkgs.bzip2.out}/lib/libbz2.so* $out/lib/ 2>/dev/null || true
        cp -P ${pkgs.xz.out}/lib/liblzma.so* $out/lib/ 2>/dev/null || true
        cp -P ${pkgs.util-linuxMinimal.lib}/lib/libuuid.so* $out/lib/ 2>/dev/null || true
      ''}

      # Make everything writable for patchelf
      chmod -R u+w $out

      # Patch ELF files
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

        # Remove references to store paths
        for store_path in ${storePathsStr}; do
          remove-references-to -t "$store_path" "$f" 2>/dev/null || true
        done
      done

      # Scrub remaining /nix/store references from binaries
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

      # Set ELF interpreter to container root
      patchelf --set-interpreter /lib/ld-linux-x86-64.so.2 $out/bin/llama-server

      ${lib.optionalString includeModal ''
        patchelf --set-interpreter /lib/ld-linux-x86-64.so.2 $out/bin/python3
        patchelf --set-interpreter /lib/ld-linux-x86-64.so.2 $out/bin/python
      ''}
    '';

  # Build a container image from a slim package
  makeContainerImage = {
    slimPackage,
    imageName ? containerConfig.imageName,
    imageTag ? null,
    includeModal ? containerConfig.includeModal,
    extraEnv ? [],
    extraContents ? [],
  }: let
    accelType = slimPackage.accelType or (getAccelType slimPackage);
    llamaPackage = slimPackage.llamaPackage or slimPackage;
    pyVer = pkgs.python3.pythonVersion;

    # Generate tag from package version and accel type
    version = llamaPackage.version or "latest";
    defaultTag = "${version}-${accelType}";
    finalTag = if imageTag != null then imageTag else defaultTag;

    # GPU-specific environment variables
    gpuEnv = lib.optionals (accelType == "cuda" || accelType == "dual") [
      "NVIDIA_VISIBLE_DEVICES=all"
      "NVIDIA_DRIVER_CAPABILITIES=compute,utility"
    ] ++ lib.optionals (accelType == "rocm" || accelType == "dual") [
      "HSA_OVERRIDE_GFX_VERSION=10.3.0"
    ];

    # Python environment variables
    pythonEnv = lib.optionals includeModal [
      "PYTHONHOME=/"
      "PYTHONPATH=/lib/python${pyVer}/site-packages"
    ];
  in
    pkgs.dockerTools.buildLayeredImage {
      name = imageName;
      tag = finalTag;

      contents = [
        slimPackage
        pkgs.dockerTools.caCertificates
        pkgs.busybox
      ] ++ extraContents;

      fakeRootCommands = ''
        mkdir -p ./usr/bin ./bin ./tmp ./lib64
        chmod 1777 ./tmp

        # Standard shebangs
        ln -s /bin/env ./usr/bin/env
        ${lib.optionalString includeModal "ln -s /bin/python3 ./usr/bin/python"}

        # Standard library path for injected binaries
        ln -s /lib/ld-linux-x86-64.so.2 ./lib64/ld-linux-x86-64.so.2
      '';

      config = {
        Env = [
          "PATH=/usr/local/bin:/usr/bin:/bin"
          "LD_LIBRARY_PATH=/lib:/usr/lib64"
        ] ++ gpuEnv ++ pythonEnv ++ extraEnv;

        ExposedPorts = {"8000/tcp" = {};};
      };

      passthru = {
        inherit accelType slimPackage;
        isContainer = true;
      };
    };

in {
  inherit makeSlimPackage makeContainerImage;

  # Convenience function to build both slim and container in one call
  makeContainerPair = args@{
    llamaPackage,
    cudaPackages ? pkgs.cudaPackages,
    rocmPackages ? pkgs.rocmPackages or null,
    includeModal ? containerConfig.includeModal,
    imageName ? containerConfig.imageName,
    imageTag ? null,
    extraEnv ? [],
    extraContents ? [],
  }: let
    slim = makeSlimPackage {
      inherit llamaPackage cudaPackages rocmPackages includeModal;
    };
    container = makeContainerImage {
      slimPackage = slim;
      inherit imageName imageTag includeModal extraEnv extraContents;
    };
  in {
    inherit slim container;
  };
}
