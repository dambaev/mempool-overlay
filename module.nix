{config, pkgs, options, lib, ...}:
let
  overlay = (import ./overlay.nix);
  cfg = config.services.mempool;
in
{
  options.services.mempool = {
    enable = lib.mkEnableOption "Mempool service";
    config = lib.mkOption {
      type = lib.types.str;
      default = "";
      example = ''
        {
          "ELECTRUM": {
            "HOST": "127.0.0.1",
            "PORT": 50002,
            "TLS_ENABLED": true,
          }
        }
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    nixpkgs.overlays = [ overlay ]; # here we include our mempool 'overlay' contents, which will bring 'mempool-*' derivations into context
    environment.systemPackages = with pkgs; [
      mempool-backend # and now we can use 'mempool-backend' derivation by importing overlay above.
      electrs # one of mempool's dependencies
    ];
    services.bitcoind.mempool = {
      enable = true;
      extraConfig = ''
        txindex = 1
      '';
      rpc.users = {
        mempool = {
          name = "mempool";
          passwordHMAC = "e85b8cd1bbfd7a4500053b4159092990$7941d89fc530a2a40faaa2073f6355f7e17821fac438827d62fd5e78b48938a9";
        };
      };
    };
    # enable mysql and declare mempool DB
    services.mysql = {
      enable = true;
      package = pkgs.mariadb; # there is no default value for this option, so we define one
      initialDatabases = [
        { name = "mempool";
          schema = "${pkgs.mempool-backend}/backend/mariadb-structure.sql";
        }
      ];
      # this script defines password for mysql user 'mempool'
      initialScript = "${pkgs.mempool-backend}/backend/initial_script.sql";
      ensureUsers = [
        { name = "mempool";
          ensurePermissions = {
            "mempool.*" = "ALL PRIVILEGES";
          };
        }
      ];
    };
    # enable electrs service
    services.electrs.enable = true;

    # create mempool systemd service
    systemd.services.mempool-backend =
    let
      mempool_config = pkgs.writeText "mempool-backend.json" cfg.config; # this renders config and stores in /nix/store
    in {
      wantedBy = [ "multi-user.target" ];
      after = [ "network-setup.service" "electrs.service" "bitcoin-mempool.service" ];
      requires = [ "network-setup.service" "electrs.service" ];
      serviceConfig = {
        Type = "simple";
      };
      path = with pkgs; [ mempool-backend nodejs ];
      script = ''
        cd ${pkgs.mempool-backend}/backend/
        npm run start -- -c ${mempool_config}
      '';
    };
  };
}