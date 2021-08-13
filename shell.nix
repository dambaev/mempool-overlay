let
  pkgs = import <nixpkgs> {
    config = {};
  };
  shell = pkgs.mkShell {
    buildInputs = with pkgs; [
      nodejs
    ];
  };

in shell
