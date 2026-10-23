{
    pkgs, lib,
    cudaArchitectures ? "120",
    ...
}: let
    # Cuda 13.0 required, 13.2 breaks on 5090
    cudaPackages = pkgs.cudaPackages_13_0;
    stdenv = cudaPackages.backendStdenv;

    llamaCppSrc = pkgs.fetchFromGitHub {
        owner = "ggml-org";
        repo = "llama.cpp";
        rev = "3cf03257f219afbe7334045ff7c6a06ac68c627d";
        hash = "sha256-SRGoXa+4ACBCB3eaG9XFYhMN1i0FyPEy9Rrer+dFGYI=";
    };

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
            "-DCMAKE_GENERATOR=Ninja"
            "-DSTRATA_BUILD_TESTS=OFF"

            "-DSTRATA_ENABLE_CUDA=ON"
            "-DCMAKE_CUDA_ARCHITECTURES=${cudaArchitectures}"

            # Strata needs llamacpp as an template for ggml handling
            "-DSTRATA_GGML_DIR=${llamaCppSrc}"

            "-DSTRATA_BUILD_TESTS=OFF"
            "-DSTRATA_PORTABLE=ON"
        ];

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

    pythonEnv = pkgs.python3.withPackages (ps: with ps; [
        numpy jinja2 regex pyyaml tqdm requests pillow psutil
    ]);

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
