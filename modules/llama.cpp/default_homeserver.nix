{
    ...
}: {
    imports = [
        ./huggingface-models.nix

        ./llama-chat.nix
        ./llama-coder.nix

        ./llama-proxy.nix
        ./model-gateway.nix
    ];
}