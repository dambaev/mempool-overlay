let
  pkgs = import <nixpkgs> {
    config = {};
  };
  shell = pkgs.mkShell {
    buildInputs = [
      nodejs
    ];
  };

in shell
