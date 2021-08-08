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
    nixpkgs.overlays = [ overlay ]; # here we include our mempool 'overlay' contents, which will bring 'mempool' derivation into context
    environment.systemPackages = with pkgs; [
      mempool # and now we can use 'mempool' derivation by importing overlay above.
    ];
#    services.bitcoind.mempool = {
#     
#    };
    # enable mysql and declare mempool DB
    services.mysql = {
      enable = true;
      initialDatabases = [
        { name = "mempool";
          schema = "${pkgs.mempool}/lib/mariadb-structure.sql";
        }
      ];
    };
  };
}