{ 
      pkgs,
      ...
}:
let
    cudaSupport = true;

    python = pkgs.python313.override {
        packageOverrides = final: prev: {
            shap = prev.shap.overridePythonAttrs (old: {
                nativeBuildInputs =
                    (old.nativeBuildInputs or [])
                    ++ pkgs.lib.optionals cudaSupport [
                        pkgs.cudaPackages.cuda_nvcc
                    ];
                buildInputs =
                    (old.buildInputs or [])
                    ++ pkgs.lib.optionals cudaSupport [
                        pkgs.cudaPackages.cudatoolkit
                    ];
                env = (old.env or {}) // pkgs.lib.optionalAttrs cudaSupport {
                    CUDAHOME = "${pkgs.cudaPackages.cudatoolkit}";
                };
                cmakeFlags = (old.cmakeFlags or []) ++ [
                    "SHAP_ENABLE_CUDA=1=ON"
                ];
            });
        };
    };

    env_ML = extraPkgs: 
        pkgs.python313Packages.python.withPackages (ps: [
            ps.scikit-learn
            ps.xgboost

            ps.skorch
            ps.torch

            ps.shap

            ps.pandas
            ps.numpy

            ps.matplotlib
            ps.seaborn

            ps.joblib
            ps.tqdm

            ps.jupyter
            ps.ipykernel
            ps.ipywidgets
        ] ++ extraPkgs ps);
in {
    base = env_ML (_: []); 
    extend = env_ML; 
}