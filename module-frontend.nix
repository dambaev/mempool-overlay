{config, pkgs, options, lib, ...}:
let
  mempool-source-set = import ./mempool-sources-set.nix;
  mempool-source = pkgs.fetchzip mempool-source-set;
  mempool-frontend-nginx-configs-overlay = import ./mempool-frontend-nginx-configs-overlay.nix; # this overlay contains nginx configs provided by mempool developers, but prepared to be used in nixos
  mempool-frontend-build-container-name = "mempoolfrontendbuild${lib.substring 0 8 mempool-source-set.sha256}";
  mempool-frontend-build-script = pkgs.writeScriptBin "mempool-frontend-build-script" ''
    set -ex
    mkdir -p /etc/mempool/
    cp -r ${mempool-source}/frontend /etc/mempool/frontend
    cd /etc/mempool/frontend
    npm install # using clean-install instead of install, as it is more stricter
    echo "return code $?"
    npm run build
  '';

  cfg = config.services.mempool-frontend;
in
{
  options.services.mempool-frontend = {
    enable = lib.mkEnableOption "Mempool service";
  };

  config = lib.mkIf cfg.enable {
    nixpkgs.overlays = [
      mempool-frontend-nginx-configs-overlay # bring nginx-mempool-configs into the context
    ];
    environment.systemPackages = with pkgs; [
      mempool-frontend-nginx-server-config
      mempool-frontend-nginx-events-config
      mempool-frontend-nginx-append-config
      mempool-frontend-nginx-common-config
      mempool-frontend-nginx-config
    ];
    services.nginx = {
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
        root = "/etc/mempool/frontend_www";
        extraConfig = ''
          # include the nginx config, which had been adopted to fit nixos-based nginx config
          include ${pkgs.mempool-frontend-nginx-server-config}/nginx.conf;
        '';
      };
    };

    # define containers, in which the actual build will be running in an isolated filesystem, but with Internet access
    containers.${mempool-frontend-build-container-name} = {
      config = {
        # those options will help to speedup evaluation of container's configurate
        documentation.doc.enable = false;
        documentation.enable = false;
        documentation.info.enable = false;
        documentation.man.enable = false;
        documentation.nixos.enable = false;
        environment.systemPackages = with pkgs; [
          nodejs
        ];
      };
    };

    # this service will check if the build is needed and will start a build in a container
    systemd.services.mempool-frontend-build = {
      wantedBy = [ "multi-user.target" ];
      after = [
        "network-setup.service"
      ];
      requires = [ "network-setup.service" ];
      serviceConfig = {
        Type = "simple";
      };
      path = with pkgs; [
        coreutils
        systemd
        bashInteractive
        mempool-frontend-build-script
        nixos-container
        e2fsprogs
      ];
      script = ''
        set -ex # echo and fail on errors

        # ensure, that /etc/mempool dir exists, at it will be used later
        mkdir -p /etc/mempool/

        CURRENT_FRONTEND=$(cat /etc/mempool/frontend || echo "there-is-no-frontend-yet")
        if [ ! -d "/var/lib/containers/$CURRENT_FRONTEND" ]; then
           # sources' commit is the same, but frontend is forced to be rebuilt as it is not exist
           CURRENT_FRONTEND="there-is-no-frontend-yet"
        fi
        # first of all, cleanup old builds, that may had been interrupted
        for FAILED_BUILD in $(ls -1 /var/lib/containers | grep "mempoolfrontendbuild" | grep -v "$CURRENT_FRONTEND" || echo "");
        do
          # stop if the build haven't been shutted down
          systemctl stop "container@$FAILED_BUILD" || true
          # remove the container's fs
          chattr -i "/var/lib/containers/$FAILED_BUILD/var/empty" || true
          rm -rf "/var/lib/containers/$FAILED_BUILD" || true
        done

        if [ "$CURRENT_FRONTEND" == "${mempool-frontend-build-container-name}" ]; then
          echo "${mempool-frontend-build-container-name} is already active frontend, do nothing"
          exit 0
        fi

        # we are here, because $CURRENT_FRONTEND is not ${mempool-frontend-build-container-name}

        # remove the build container dir, just in case if it exists already
        systemctl stop "container@${mempool-frontend-build-container-name}" || true
        chattr -i "/var/lib/container/${mempool-frontend-build-container-name}/var/empty" || true
        rm -rf "/var/lib/container/${mempool-frontend-build-container-name}"

        # start build container
        systemctl start container@${mempool-frontend-build-container-name}
        # wait until it will shutdown
        nixos-container run "${mempool-frontend-build-container-name}" -- "${mempool-frontend-build-script}/bin/mempool-frontend-build-script" 2>&1 > /etc/mempool/frontend-lastlog && {
          # if build was successfull
          # stop the container as it is not needed anymore
          systemctl stop "container@${mempool-frontend-build-container-name}" || true
          # delete possible leftovers from previous builds
          rm -rf "/var/lib/containers/${mempool-frontend-build-container-name}-tmp"
          # move the result of the build out of container's root
          mv "/var/lib/containers/${mempool-frontend-build-container-name}/etc/mempool/frontend/dist/mempool/browser" "/var/lib/containers/${mempool-frontend-build-container-name}-tmp"
          # remove build's fs
          chattr -i "/var/lib/containers/${mempool-frontend-build-container-name}/var/empty" || true
          rm -rf "/var/lib/containers/${mempool-frontend-build-container-name}"
          # move the result back
          mkdir -p "/var/lib/containers/${mempool-frontend-build-container-name}/etc"
          mv "/var/lib/containers/${mempool-frontend-build-container-name}-tmp" "/var/lib/containers/${mempool-frontend-build-container-name}/etc/mempool"
          # replace current frontend with new one
          echo "${mempool-frontend-build-container-name}" > /etc/mempool/frontend
          # restart mempool-frontend service
          ln -svf "/var/lib/containers/${mempool-frontend-build-container-name}/etc/mempool" "/etc/mempool/frontend_www"
          systemctl restart nginx
          # cleanup old /etc/mempool/frontend's target
          rm -rf "/var/lib/container/$CURRENT_FRONTEND"
        }
        # else - just fail
      '';
    };
  };
}