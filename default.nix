let
  pkgs = import <nixpkgs> {
    config = {};
    overlays = [
      (import ./overlay.nix)
    ];
  };

in {
  mempool-backend = pkgs.mempool-backend;
}
