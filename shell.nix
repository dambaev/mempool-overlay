let
#  nixpkgs = import <nixpkgs>;
  pkgs = import <nixpkgs> {
    config = {};
    overlays = [
      (import ./overlay.nix)
    ];
  };
  shell = pkgs.mkShell {
    buildInputs = pkgs.mempool-backend.buildInputs
      ++ [
        # your development tools like debugger / profiler should be listed here
      ];
  };

in shell
