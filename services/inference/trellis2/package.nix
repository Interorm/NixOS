{
    pkgs, lib,
    cudaPackages,
    # CUDA architecture as an integer, e.g. 61 = Pascal (GTX 10xx).  ggml's CUDA
    # kernels and trellis.cpp's own kernels are compiled for exactly this one.
    cudaArchitecture,
    ...
}: let
    # ------------------------------------------------------------------
    # Pins.  trellis.cpp pins its ggml fork as a git submodule; the GitHub
    # tarball does not contain submodules, so both are fetched and the
    # submodule commit (`git ls-tree <rev> thirdparty/ggml`) is copied in.
    # Bumping trellis.cpp means: new rev + hash, then re-read that ls-tree line.
    # ------------------------------------------------------------------
    trellisCppRev = "7c600c64b547fddb989c66df0b1cb045add788ed";     # main, 2026-11-24
    ggmlRev = "f8697b33795db2ee6a2569b40853ca6aaa69f9b9";           # thirdparty/ggml at the commit above

    src = pkgs.fetchFromGitHub {
        owner = "pwilkin";
        repo = "trellis.cpp";
        rev = trellisCppRev;
        hash = "sha256-Pd3sg0256+/Co4SHZX4EjkWE3ifEmILhjSxqNT0UpuI=";
    };
    ggml = pkgs.fetchFromGitHub {
        owner = "pwilkin";
        repo = "ggml";
        rev = ggmlRev;
        hash = "sha256-ev7n0YK/h9JF8EYTARywLWtcOu1klI0LCMSj5lHwQYU=";
    };

    # CUDA 12.x only: nvcc from CUDA 13 cannot target Pascal.
    trellis-server = cudaPackages.backendStdenv.mkDerivation {
        pname = "trellis-cpp";
        version = "0.8.1-unstable-2026-11-24";
        inherit src;

        postUnpack = ''
            rmdir "$sourceRoot/thirdparty/ggml" 2>/dev/null || true
            cp -r --no-preserve=mode ${ggml} "$sourceRoot/thirdparty/ggml"
        '';

        nativeBuildInputs = [
            pkgs.cmake
            pkgs.ninja
            cudaPackages.cuda_nvcc
            pkgs.autoAddDriverRunpath
        ];
        buildInputs = with cudaPackages; [ cuda_cudart cccl libcublas ];

        cmakeFlags = [
            (lib.cmakeBool "GGML_CUDA" true)
            (lib.cmakeBool "GGML_NATIVE" false)         # no -march=native: the store path must not depend on the build machine
            (lib.cmakeBool "GGML_CUDA_F16" false)       # Pascal has no useful fp16 throughput (same as services.llama-cpp)
            (lib.cmakeFeature "CMAKE_CUDA_ARCHITECTURES" (toString cudaArchitecture))
            # Geometry-only: GLB textures (WebP) are not needed, and the option
            # would FetchContent libwebp from the network inside the sandbox.
            (lib.cmakeBool "TRELLIS_WEBP" false)
            (lib.cmakeBool "TRELLIS_RETOPO_MATCHING" false)
            (lib.cmakeBool "TRELLIS_RETOPO_COLLISION" false)
        ];

        # Only the server; the CMake project also defines ~40 test/tool binaries.
        # -j4: each ggml-cuda translation unit is a multi-GB nvcc/cicc process
        # (the previous torch-extension build OOM'd this 31 GB box at 3 x 8 jobs).
        ninjaFlags = [ "-j4" "trellis-server" ];

        installPhase = ''
            runHook preInstall
            install -Dm755 trellis-server -t $out/bin
            mkdir -p $out/lib
            cp -P lib*.so* $out/lib/
            runHook postInstall
        '';

        # The files are copied by hand (the project has no install rules), so
        # CMake never rewrote their build-tree RPATH: it still lists /build/...,
        # which Nix rejects.  Drop those entries; the executable sits in bin/
        # while the libs live in ../lib, so point it there.  Must run before
        # fixup: the forbidden-reference check is part of it.
        preFixup = ''
            for f in $out/bin/trellis-server $out/lib/*.so*; do
                [ -L "$f" ] && continue
                patchelf --set-rpath "$(patchelf --print-rpath "$f" | tr ':' '\n' | grep -v '^/build/' | paste -sd:)" "$f"
            done
            patchelf --add-rpath $out/lib $out/bin/trellis-server
        '';

        meta = {
            description = "TRELLIS.2 image-to-3D in C++/ggml (CUDA), with a resident HTTP server";
            homepage = "https://github.com/pwilkin/trellis.cpp";
            license = lib.licenses.mit;
            mainProgram = "trellis-server";
        };
    };

    # trellis-server answers with a GLB (glTF is Y-up).  Slicers want Z-up STL,
    # so the client rotates +90 deg about X: (x, y, z) -> (x, -z, y).
    convert = pkgs.writers.writePython3 "glb-to-stl" {
        libraries = [ pkgs.python3Packages.trimesh pkgs.python3Packages.numpy ];
        flakeIgnore = [ "E501" ];
    } ''
        import math
        import sys

        import trimesh

        glb, stl = sys.argv[1], sys.argv[2]
        mesh = trimesh.load(glb, force="mesh")
        mesh.apply_transform(trimesh.transformations.rotation_matrix(math.pi / 2, [1, 0, 0]))
        mesh.export(stl)
        print(f"{stl}: {len(mesh.faces):,} faces, watertight={mesh.is_watertight}")
    '';

    client = pkgs.writeShellApplication {
        name = "trellis2-stl";
        runtimeInputs = [ pkgs.curl pkgs.coreutils ];
        text = ''
            usage() {
                echo "usage: trellis2-stl [-u URL] [-r 512|1024] [-s SEED] [-f MAX_FACES] IMAGE [OUT.stl]" >&2
                echo "  Needs the service up: systemctl start trellis2  (stops the GPU's other model)" >&2
                exit 2
            }
            url=''${TRELLIS2_URL:-http://127.0.0.1:7860}
            extra=()
            while getopts "u:r:s:f:h" opt; do
                case $opt in
                    u) url=$OPTARG ;;
                    r) extra+=(-F "resolution=$OPTARG") ;;
                    s) extra+=(-F "seed=$OPTARG") ;;
                    f) extra+=(-F "faces=$OPTARG") ;;
                    *) usage ;;
                esac
            done
            shift $((OPTIND - 1))
            [ $# -ge 1 ] || usage
            image=$1
            out=''${2:-''${image%.*}.stl}

            glb=$(mktemp --suffix=.glb)
            trap 'rm -f "$glb"' EXIT
            # A run takes minutes; /generate holds the connection until it is done.
            curl --fail-with-body --silent --show-error --max-time 3600 \
                -F "image=@$image" -F texture=off "''${extra[@]}" \
                -o "$glb" "$url/generate"
            ${convert} "$glb" "$out"
        '';
    };
in
    pkgs.symlinkJoin {
        name = "trellis2";
        paths = [ trellis-server client ];
        passthru = { inherit trellis-server client; };
        meta.mainProgram = "trellis-server";
    }
