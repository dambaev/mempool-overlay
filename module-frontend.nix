{config, pkgs, options, lib, ...}@args:
let
  mempool-source-set = import ./mempool-sources-set.nix;
  mempool-source = pkgs.fetchzip mempool-source-set;
  mempool-frontend-nginx-configs-overlay = import ./mempool-frontend-nginx-configs-overlay.nix; # this overlay contains nginx configs provided by mempool developers, but prepared to be used in nixos
  mempool-overlay = import ./overlay.nix;

  cfg = config.services.mempool-frontend;
  frontend_args = {
    testnet_enabled = cfg.testnet_enabled;
    signet_enabled = cfg.signet_enabled;
  };
in
{
  options.services.mempool-frontend = {
    enable = lib.mkEnableOption "Mempool service";
    testnet_enabled = lib.mkOption {
      type = lib.types.bool;
      example = false;
      default = false;
      description = ''
        If enabled, frontend will have a dropdown list, from which it will be possible to switch to testnet network
      '';
    };
    signet_enabled = lib.mkOption {
      type = lib.types.bool;
      example = false;
      default = false;
      description = ''
        If enabled, frontend will have a dropdown list, from which it will be possible to switch to signet network
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    nixpkgs.overlays = [
      mempool-frontend-nginx-configs-overlay # bring nginx-mempool-configs into the context
      mempool-overlay # add mempool-frontend into context
    ];
    environment.systemPackages = with pkgs; [
      mempool-frontend-nginx-server-config
      mempool-frontend-nginx-events-config
      mempool-frontend-nginx-append-config
      mempool-frontend-nginx-common-config
      mempool-frontend-nginx-config
      (mempool-frontend frontend_args)
    ];
    services.nginx =
      let
        testnet_locations =
          if cfg.testnet_enabled
          then ''
            location = /testnet/api {
              try_files $uri $uri/ /en-US/index.html =404;
            }
            location = /testnet/api/ {
              try_files $uri $uri/ /en-US/index.html =404;
            }
            # testnet API
            location /testnet/api/v1/ws {
              proxy_pass http://127.0.0.1:8997/;
              proxy_http_version 1.1;
              proxy_set_header Upgrade $http_upgrade;
              proxy_set_header Connection "Upgrade";
            }
            location /testnet/api/v1 {
              proxy_pass http://127.0.0.1:8997/api/v1;
            }
            location /testnet/api/ {
              proxy_pass http://127.0.0.1:60001/;
            }
          ''
        else ''
        '';
        signet_locations =
          if cfg.signet_enabled
          then ''
            location = /signet/api {
              try_files $uri $uri/ /en-US/index.html =404;
            }
            location = /signet/api/ {
              try_files $uri $uri/ /en-US/index.html =404;
            }
            # signet API
            location /signet/api/v1/ws {
              proxy_pass http://127.0.0.1:8995/;
              proxy_http_version 1.1;
              proxy_set_header Upgrade $http_upgrade;
              proxy_set_header Connection "Upgrade";
            }
            location /signet/api/v1 {
              proxy_pass http://127.0.0.1:8995/api/v1;
            }
            location /signet/api/ {
              proxy_pass http://127.0.0.1:60601/;
            }
          ''
        else ''
        '';
      in {
      enable = true;
      appendConfig = "include ${pkgs.mempool-frontend-nginx-append-config}/nginx.conf;";
      eventsConfig = "include ${pkgs.mempool-frontend-nginx-events-config}/nginx.conf;";
      serverTokens =
        let
          server_tokens_str = builtins.readFile "${pkgs.mempool-frontend-nginx-config}/server_tokens.txt";
        in
        if server_tokens_str == "on" then true else false;
      clientMaxBodySize = builtins.readFile "${pkgs.mempool-frontend-nginx-config}/client_max_body_size.txt";
      commonHttpConfig = "include ${pkgs.mempool-frontend-nginx-common-config}/nginx.conf;";
      virtualHosts.mempool = {
        root = "${pkgs.mempool-frontend frontend_args}";
        extraConfig = ''
          # include the nginx config, which had been adopted to fit nixos-based nginx config
          include ${pkgs.mempool-frontend-nginx-server-config}/nginx.conf;
          # here we include possible options to route testnet-related requests.
          ${testnet_locations}
          # here we include possible options to route signet-related requests.
          ${signet_locations}
        '';
      };
    };
  };
}