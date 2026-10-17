{ pkgs, ... }:
let
    app = import ./fints/package.nix { inherit pkgs; };
in {
    command = "${app}/bin/fints-mcp";
    args = [ ];

    env = {
        FINTS_ENROLL_CMD = "fints-enroll";

        FINANCE_LABEL_MODEL = "Gemma4-E4B";
        HERMES_GATEWAY = "http://127.0.0.1:8080/v1";

        FINTS_BLZ = "\${FINTS_BLZ}";
        FINTS_ENDPOINT = "\${FINTS_ENDPOINT}";
        FINTS_USER_ID = "\${FINTS_USER_ID}";
        FINTS_PIN = "\${FINTS_PIN}";
        FINTS_PRODUCT_ID = "\${FINTS_PRODUCT_ID}";
    };

    meta = {
        description = "FINTS-based mcp for accessing Sparkasse Online Banking (read-only). Experimental";
        requires.envVars = [ "FINTS_BLZ" "FINTS_ENDPOINT" "FINTS_USER_ID" "FINTS_PIN" "FINTS_PRODUCT_ID" ];
    };
}
