{
    pkgs, lib,
    cudaPackages,
    # "6.1" = Pascal (GTX 10xx).  Every CUDA extension below is compiled for
    # exactly this capability, nothing else.
    cudaCapability,
    ...
}: let
    # ------------------------------------------------------------------
    # Pins.  TRELLIS.2 "main" is pinned to a commit; bumping it means
    # changing rev + hash, and pascal.patch fails loudly at build time if
    # upstream moved the lines it touches.
    # ------------------------------------------------------------------
    trellisRev = "75fbf0183001ed9876c8dbb35de6b68552ee08bd";    # main, 2026-06-05

    # PyTorch only ships Maxwell/Pascal cubins in its CUDA 12.6 wheels
    # (verified for this wheel: sm_50 + sm_60 ELF images in libtorch_cuda.so;
    # sm_60 code runs on sm_61).  nixpkgs' torch-bin uses cu130 = sm_75+,
    # and the source build defaults to CUDA 13 as well.  Versions match the
    # nixpkgs torch-bin / torchvision-bin they override.
    wheels = {
        torch = {
            version = "2.13.0";
            hash = "sha256-r/07SaTkiu+JX/2eGWGBvVBUItfDe0pvmvp2iZ0qzT0=";
        };
        torchvision = {
            version = "0.28.0";
            hash = "sha256-SgoZHJIyWhE2YsrXWdluTpby/PTyDRad6ceTMQjuUME=";
        };
    };

    trellisSrc = pkgs.applyPatches {
        name = "trellis2-src-${builtins.substring 0 7 trellisRev}";
        src = pkgs.fetchFromGitHub {
            owner = "microsoft";
            repo = "TRELLIS.2";
            rev = trellisRev;
            fetchSubmodules = true;           # o-voxel/third_party/eigen
            hash = "sha256-VNwtZxsTPs7qHp1AHPq8wDpSpC9n1ObHNJThD4fYDHI=";
        };
        # sdpa attention backend for GPUs without flash-attn/xformers, lazy
        # nvdiffrast import in o_voxel, and a loud warning instead of silently
        # random layers when a checkpoint does not match the model.
        patches = [ ./pascal.patch ];
    };

    py = pkgs.python3Packages;
    python = py.python;
    pyTag = "cp" + builtins.replaceStrings [ "." ] [ "" ] python.pythonVersion;
    # The store name must keep the "+cu126" local version: fetchurl would derive
    # it from the URL and mangle "%2B" into "-2B", after which the wheel's
    # filename no longer parses to version 2.13.0+cu126 and the installer looks
    # for a torch-2.13.0.dist-info that does not exist.  (nixpkgs' own
    # binary-hashes.nix sets `name` for the same reason.)
    fetchWheel = pname: v: pkgs.fetchurl {
        name = "${pname}-${v.version}+cu126-${pyTag}-${pyTag}-manylinux_2_28_x86_64.whl";
        url = "https://download.pytorch.org/whl/cu126/${pname}-${v.version}%2Bcu126-${pyTag}-${pyTag}-manylinux_2_28_x86_64.whl";
        inherit (v) hash;
    };

    # Targeted overrides rather than python.override { packageOverrides }: a
    # set-wide torch swap also invalidates every package that merely *tests*
    # against torch (safetensors, transformers, gradio + its npm frontend, ...)
    # and turns cache hits into local builds.  Only timm and kornia need torch
    # at runtime; everything else in the env comes straight from the cache.
    # NCCL and NVSHMEM straight from the pip wheels this torch wheel was built
    # against (Requires-Dist pins).  nixpkgs builds both from source: NCCL with
    # device kernels for every default capability (7.5-12.1, none of them the
    # card this runs on; hours of nvcc), NVSHMEM with an openmpi/ucx/pmix chain.
    # torch only needs the two host libraries below at load time; both link
    # nothing beyond libc/libstdc++.  Single-GPU inference never calls either.
    pipLib = { pname, version, url, hash, lib }: pkgs.stdenv.mkDerivation {
        inherit pname version;
        src = pkgs.fetchurl { inherit url hash; };
        nativeBuildInputs = [ pkgs.unzip pkgs.autoPatchelfHook ];
        buildInputs = [ pkgs.stdenv.cc.cc.lib ];
        unpackPhase = "unzip -q $src ${lib}";
        installPhase = "install -Dm755 ${lib} -t $out/lib";
    };
    nccl = pipLib {
        pname = "nccl-cu12-bin";
        version = "2.29.3";
        url = "https://files.pythonhosted.org/packages/31/5a/cac7d231f322b66caa16fd4b136ebc8e4b18b2805811c2d58dc47210cdea/nvidia_nccl_cu12-2.29.3-py3-none-manylinux_2_18_x86_64.whl";
        hash = "sha256-Na1C59XXIqg8NqOkeOKBwgpWRjg96vG57Rqat9Yb7VM=";
        lib = "nvidia/nccl/lib/libnccl.so.2";
    };
    nvshmem = pipLib {
        pname = "nvshmem-cu12-bin";
        version = "3.4.5";
        url = "https://files.pythonhosted.org/packages/b5/09/6ea3ea725f82e1e76684f0708bbedd871fc96da89945adeba65c3835a64c/nvidia_nvshmem_cu12-3.4.5-py3-none-manylinux2014_x86_64.manylinux_2_17_x86_64.whl";
        hash = "sha256-BC8lAPJMAh24oGxe7CU5An1XRg4cGnYgVaZVT3LDab0=";
        lib = "nvidia/nvshmem/lib/libnvshmem_host.so.3";
    };

    torch = (py.torch-bin.override { inherit cudaPackages; }).overridePythonAttrs (old: {
        inherit (wheels.torch) version;
        src = fetchWheel "torch" wheels.torch;
        # cu12 wheel names; the libraries come from cudaPackages instead.
        pythonRemoveDeps = old.pythonRemoveDeps ++ [
            "nvidia-cudnn-cu12" "nvidia-cusparselt-cu12" "nvidia-nccl-cu12" "nvidia-nvshmem-cu12"
            "cuda-bindings"
        ];
        # cuda-bindings is optional for torch: every import in this wheel is a
        # `try: from cuda.bindings import ... except ImportError` (CUDA-graph
        # annotations, UVM, CUPTI profiler, sm_80+ CuTe-DSL kernels -- none used
        # here).  Dropping it avoids building nixpkgs' cuda-bindings at 12.9.x,
        # whose pyproject pins cython<3.3 against nixpkgs' 3.3.0.
        dependencies = builtins.filter (d: (d.pname or "") != "cuda-bindings") old.dependencies;
        # nixpkgs flags torch-bin as broken when cuda-bindings < 13 -- right for
        # its cu130 wheel, moot here (cu126, and cuda-bindings is dropped).
        meta = old.meta // { problems = { }; };
        buildInputs = builtins.filter (d: d != cudaPackages.nccl && d != cudaPackages.libnvshmem) old.buildInputs
            ++ [ nccl nvshmem ];
    });

    torchvision = (py.torchvision-bin.override {
        inherit cudaPackages;
        torch-bin = torch;
    }).overridePythonAttrs (old: {
        inherit (wheels.torchvision) version;
        src = fetchWheel "torchvision" wheels.torchvision;
    });

    # RMBG-2.0 (BiRefNet) remote code needs these.  Their test suites would run
    # torch on CPU for every rebuild, so skip them.
    timm = (py.timm.override { inherit torch torchvision; }).overridePythonAttrs { doCheck = false; };
    kornia = (py.kornia.override { inherit torch; }).overridePythonAttrs { doCheck = false; };

    # torch.utils.cpp_extension CUDA builds, compiled for one capability only.
    torchCudaExtension = attrs: py.buildPythonPackage.override { stdenv = cudaPackages.backendStdenv; } ({
        version = "0-unstable";
        pyproject = true;

        build-system = [ py.setuptools py.wheel torch ];
        nativeBuildInputs = [
            cudaPackages.cuda_nvcc
            pkgs.ninja
            pkgs.writableTmpDirAsHomeHook
        ];
        buildInputs = with cudaPackages; [ cuda_cudart cccl ];

        # ninja is only here for cpp_extension's parallel compile; it must not
        # take over the Python build/install phases.
        dontUseNinjaBuild = true;
        dontUseNinjaInstall = true;
        dontUseNinjaCheck = true;

        env = {
            TORCH_CUDA_ARCH_LIST = cudaCapability;
            BUILD_TARGET = "cuda";
            FORCE_CUDA = "1";
        };
        preBuild = ''
            # NOT $NIX_BUILD_CORES: with cores = 0 that is all 8 CPUs, and Nix
            # builds cumesh/flex_gemm/o_voxel side by side (max-jobs = 8), so
            # 3 x 8 nvcc/cicc processes at 1-3 GB each exhausted the 31 GB box
            # (llama-server etc. already hold ~11 GB).  2 each = at most 6.
            export MAX_JOBS=2
        '';
    } // attrs);

    cumesh = torchCudaExtension {
        pname = "cumesh";
        src = pkgs.fetchFromGitHub {
            owner = "JeffreyXiang";
            repo = "CuMesh";
            rev = "12289e1062f0603f2f0d0771b02e1395d247f26f";
            fetchSubmodules = true;           # cubvh (+ eigen), xatlas
            hash = "sha256-mmBU+1jVZopxGQ/Hwvb9ZvsKoJGhsH0QnPCnJN8Dlpw=";
        };
        dependencies = [ torch py.tqdm ];
        pythonImportsCheck = [ "cumesh" ];
    };

    flex-gemm = torchCudaExtension {
        pname = "flex_gemm";
        src = pkgs.fetchFromGitHub {
            owner = "JeffreyXiang";
            repo = "FlexGEMM";
            rev = "6dd94a859c26ee8246888502eada3dd8ad85532e";
            hash = "sha256-iyHR8WXGdeWf6l6V3QLBQ4BQLAB8G/9dfHgz++0EIEc=";
        };
        # The CUDA part (hashmaps, neighbour maps) builds for sm_61.  The Triton
        # GEMM kernels do not run on Pascal (Triton needs sm_70+); the service
        # selects flex_gemm's torch "explicit_gemm" path, which never calls them.
        dependencies = [ torch torch.triton py.filelock ];
        pythonImportsCheck = [ "flex_gemm" ];
    };

    o-voxel = torchCudaExtension {
        pname = "o_voxel";
        src = "${trellisSrc}/o-voxel";
        dependencies = [
            torch py.numpy py.plyfile py.trimesh py.tqdm py.zstandard py.easydict
            cumesh flex-gemm
        ];
        pythonImportsCheck = [ "o_voxel" ];
    };

    # The repo has no setup.py for the `trellis2` package itself; upstream runs
    # it from the checkout.  Install the package directory as-is.
    trellis2 = py.buildPythonPackage {
        pname = "trellis2";
        version = "0-unstable-2026-06-05";
        format = "other";
        src = trellisSrc;

        dontBuild = true;
        installPhase = ''
            runHook preInstall
            mkdir -p "$out/${python.sitePackages}"
            cp -r trellis2 "$out/${python.sitePackages}/"
            runHook postInstall
        '';

        dependencies = [
            torch torchvision py.numpy py.pillow py.easydict py.tqdm
            py.transformers py.huggingface-hub py.safetensors
            py.opencv-python-headless py.trimesh py.plyfile
            # RMBG-2.0 / BiRefNet remote code
            timm kornia py.einops
            cumesh flex-gemm o-voxel
        ];

        # Proves on CPU, at build time, that the sdpa varlen path from
        # pascal.patch matches a naive per-sequence softmax attention.
        doCheck = true;
        checkPhase = ''
            runHook preCheck
            export HOME=$TMPDIR ATTN_BACKEND=sdpa
            PYTHONPATH="$out/${python.sitePackages}:$PYTHONPATH" python ${./check_sdpa.py}
            runHook postCheck
        '';
        pythonImportsCheck = [ "trellis2.pipelines.trellis2_image_to_3d" ];
    };

    env = python.withPackages (_: [ trellis2 py.fastapi py.uvicorn py.python-multipart ]);

    # three.js for the in-browser STL preview, pinned and served by the app
    # itself (no CDN at runtime).
    three = v: file: hash: { name = baseNameOf file; path = pkgs.fetchurl { url = "https://cdn.jsdelivr.net/npm/three@${v}/${file}"; inherit hash; }; };
    static = pkgs.linkFarm "trellis2-stl-static" [
        (three "0.170.0" "build/three.module.js" "sha256-zh+kGN4WoZSVqfcklVgOMBXXdFwpbTzgSFiX+QLd7fs=")
        (three "0.170.0" "examples/jsm/loaders/STLLoader.js" "sha256-oKg8iLJpyU4ltpD653DTUMRyjIGFMZUYaXa+evD4o7M=")
        (three "0.170.0" "examples/jsm/controls/OrbitControls.js" "sha256-gO+q3qT4pjamX7C9CL/vYvPZOgu5Ti51APIxdsXAf04=")
    ];
in
    pkgs.writeShellApplication {
        name = "trellis2-stl";
        text = ''
            export TRELLIS2_STATIC=${static}
            exec ${env}/bin/python ${./server.py} "$@"
        '';
        derivationArgs.passthru = { inherit env static torch torchvision timm kornia nccl nvshmem trellis2 cumesh flex-gemm o-voxel trellisSrc; };
    }
