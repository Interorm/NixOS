{
    pkgs, lib,
    # Compute capability of the target card, without the trailing "a" variant
    # suffix: upstream's CMake adds `a` itself for the one W4A4 translation
    # unit and refuses anything below 75.  "120" = RTX 50 (Blackwell consumer).
    cudaArchitectures ? "120",
    ...
}: let
    # Upstream's own flake pins CUDA 13.0 with a comment that 13.2.0/13.2.1
    # miscompile for sm_120, so this does NOT follow the 13.2 used by the
    # ninfer module -- the version is load-bearing, not incidental.
    cudaPackages = pkgs.cudaPackages_13_0;
    stdenv = cudaPackages.backendStdenv;

    # CMakeLists.txt takes ggml from a llama.cpp checkout given as
    # -DSTRATA_GGML_DIR, and otherwise FetchContent-clones this exact commit at
    # configure time.  The Nix sandbox has no network during the build, so the
    # checkout has to be a fixed-output fetch handed in by path.
    llamaCppSrc = pkgs.fetchFromGitHub {
        owner = "ggml-org";
        repo = "llama.cpp";
        rev = "3cf03257f219afbe7334045ff7c6a06ac68c627d";
        hash = "sha256-SRGoXa+4ACBCB3eaG9XFYhMN1i0FyPEy9Rrer+dFGYI=";
    };

    # The engine. Python is deliberately NOT part of this derivation: the
    # `strata` binary is a self-contained C++/CUDA program, and the Python half
    # (serve/server.py) is packaged separately below so the two can be wired
    # together without a venv.
    strata-engine = stdenv.mkDerivation (finalAttrs: {
        pname = "strata-engine";
        version = "0.2.3";

        src = pkgs.fetchFromGitHub {
            owner = "Niko1221";
            repo = "Strata";
            rev = "v${finalAttrs.version}";
            hash = "sha256-mBtfFfyUNv1joh54MwxSOZPpY2Pt8qmnn5f5aMxPjPo=";
        };

        nativeBuildInputs = with pkgs; [
            cmake
            ninja
            pkg-config
            cudaPackages.cuda_nvcc
            autoAddDriverRunpath
        ];

        buildInputs = (with pkgs; [
            curl
            zlib
        ]) ++ (with cudaPackages; [
            cuda_cudart
            cccl
            libcublas
            cuda_nvtx
        ]);

        cmakeFlags = [
            "-DCMAKE_BUILD_TYPE=Release"
            "-DSTRATA_ENABLE_CUDA=ON"
            "-DCMAKE_CUDA_ARCHITECTURES=${cudaArchitectures}"
            # Point ggml at the vendored checkout instead of letting
            # FetchContent reach for the network mid-configure.
            "-DSTRATA_GGML_DIR=${llamaCppSrc}"
            # STRATA_BUILD_TESTS: the published tarball ships no
            # tests/CMakeLists.txt, so this is already the computed default;
            # set explicitly so a future tarball that *does* ship them cannot
            # silently add ~200 test binaries to the build.
            "-DSTRATA_BUILD_TESTS=OFF"
            # Build for a known ISA floor rather than the builder's own CPU:
            # a Nix build host need not be the machine that runs the result.
            "-DSTRATA_PORTABLE=OFF"
            # NOTE: STRATA_PREFILL_MMQ is a HIP-only path and CMake hard-fails
            # with "requires STRATA_ENABLE_HIP=ON" if it is set on CUDA.
            # STRATA_MMQ_KQUANTS, STRATA_Q6K_EXPERTS and STRATA_NATIVE_EXPERTS
            # all already default to ON, so none of them is set here.
        ];

        # ggml's CMake probes the host CPU with -march=native unless told
        # otherwise; keep that off so the artifact is not tied to the builder.
        preConfigure = ''
            cmakeFlagsArray+=( "-DGGML_NATIVE=OFF" "-DGGML_AVX2=ON" "-DGGML_FMA=ON" "-DGGML_F16C=ON" )
        '';

        # Upstream has no install target (the setup script runs the binaries
        # straight out of the build tree), so the generic installPhase would
        # leave $out empty -- same situation as the ninfer derivation.
        installPhase = ''
            runHook preInstall
            install -Dm755 strata "$out/bin/strata"
            for extra in strata-vision strata-gguf strata-dequant strata-plan; do
                [ -f "$extra" ] && install -Dm755 "$extra" "$out/bin/$extra"
            done
            runHook postInstall
        '';

        meta = {
            description = "MoE inference engine streaming experts between VRAM, RAM and NVMe";
            homepage = "https://github.com/Niko1221/Strata";
            license = lib.licenses.mit;
            platforms = [ "x86_64-linux" ];
            mainProgram = "strata";
        };
    });

    # The HTTP server: upstream's setup.sh builds a venv from requirements.txt,
    # which is exactly the thing a Nix module should not do at runtime.  The
    # pinned versions there are reproducibility pins for pip users, so taking
    # nixpkgs' equivalents is the intended substitution rather than a downgrade.
    pythonEnv = pkgs.python3.withPackages (ps: with ps; [
        numpy jinja2 regex pyyaml tqdm requests pillow psutil
    ]);

    # serve/ imports `strata_control` and `serve.*` as top-level packages and
    # reads data/ and its chat template relative to the repo root, so the whole
    # source tree is installed and PYTHONPATH points at it.
    #
    # tools/_paths.py resolves llama.cpp's gguf-py from $STRATA_GGUF_PY, then
    # from <root>/third_party/llama.cpp/gguf-py (what upstream's setup.py
    # clones), and `sys.exit`s if neither exists -- so the vendored checkout's
    # gguf-py is placed at exactly that second location.  `gguf-py` is then
    # found with no environment variable set at all, and the module exposes the
    # path as a read-only option rather than guessing it.
    strata-serve = pkgs.stdenvNoCC.mkDerivation {
        pname = "strata-serve";
        inherit (strata-engine) version src;

        nativeBuildInputs = [ pkgs.makeWrapper ];

        installPhase = ''
            runHook preInstall
            mkdir -p "$out/share/strata"
            cp -r serve strata_control strata_cli tools data "$out/share/strata/"
            cp strata.py chat.py "$out/share/strata/" 2>/dev/null || true

            # The gguf-py the packing tools need, at the path they look in.
            mkdir -p "$out/share/strata/third_party/llama.cpp"
            cp -r ${llamaCppSrc}/gguf-py "$out/share/strata/third_party/llama.cpp/gguf-py"

            makeWrapper ${pythonEnv}/bin/python "$out/bin/strata-serve" \
                --add-flags "$out/share/strata/serve/server.py" \
                --set PYTHONPATH "$out/share/strata" \
                --set PYTHONDONTWRITEBYTECODE 1
            runHook postInstall
        '';

        passthru.ggufPy = "share/strata/third_party/llama.cpp/gguf-py";

        meta = strata-engine.meta // {
            description = "OpenAI/Anthropic-compatible HTTP server for the Strata engine";
            mainProgram = "strata-serve";
        };
    };
in {
    inherit strata-engine strata-serve pythonEnv;
}
