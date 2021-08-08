{config, pkgs, options, lib, ...}:
let
  overlay = (import ./overlay.nix);
  cfg = config.services.mempool;
in
{
  options.services.mempool = {
    enable = lib.mkEnableOption "Mempool service";
  };

  config = lib.mkIf cfg.enable {
    nixpkgs.overlays = [ overlay ]; # here we include our mempool 'overlay' contents, which will bring 'mempool-*' derivations into context
    environment.systemPackages = with pkgs; [
      mempool-backend # and now we can use 'mempool-backend' derivation by importing overlay above.
    ];
#    services.bitcoind.mempool = {
#     
#    };
    # enable mysql and declare mempool DB
    services.mysql = {
      enable = true;
      package = pkgs.mariadb; # there is no default value for this option, so we define one
      initialDatabases = [
        { name = "mempool";
          schema = "${pkgs.mempool-backend}/backend/mariadb-structure.sql";
        }
      ];
      ensureUsers = [
        { name = "mempool";
          ensurePermissions = {
            "mempool.*" = "ALL PRIVILEGES";
          };
        };
      ];
    };
  };
}