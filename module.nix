{config, pkgs, options, lib, ...}:
let
  mempool-source-set = {
    url = "https://github.com/mempool/mempool/archive/refs/tags/v2.2.0.tar.gz";
    sha256 = "1h2vf54rjsajiy7lh0md8ymdipn04qpbxzqqwfr3b13fzfk29wng";
  };
  mempool-source = pkgs.fetchzip mempool-source-set;
  mempool-backend-build-container-name = "mempoolbackendbuild${lib.substring 0 8 mempool-source-set.sha256}";
  initial_script = pkgs.writeText "initial_script.sql" ''
    CREATE USER IF NOT EXISTS mempool@localhost IDENTIFIED BY 'mempool';
    ALTER USER mempool@localhost IDENTIFIED BY 'mempool';
    flush privileges;
  '';
  mempool-backend-build-script = pkgs.writeScriptBin "mempool-backend-build-script" ''
    set -ex
    mkdir -p /etc/mempool/
    cp -r ${mempool-source}/backend /etc/mempool/backend
    cd /etc/mempool/backend
    npm install # using clean-install instead of install, as it is more stricter
    echo "return code $?"
    npm run build
  '';

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
    # enable mysql and declare mempool DB
    services.mysql = {
      enable = true;
      package = pkgs.mariadb; # there is no default value for this option, so we define one
      initialDatabases = [
        { name = "mempool";
          schema = "${mempool-source}/mariadb-structure.sql";
        }
      ];
      # this script defines password for mysql user 'mempool'
      initialScript = "${initial_script}";
      ensureUsers = [
        { name = "mempool";
          ensurePermissions = {
            "mempool.*" = "ALL PRIVILEGES";
          };
        }
      ];
    };

    # create mempool systemd service
    systemd.services.mempool-backend =
    let
      mempool_config = pkgs.writeText "mempool-backend.json" cfg.config; # this renders config and stores in /nix/store
    in {
      wantedBy = [ "multi-user.target" ];
      after = [
        "network-setup.service"
        "electrs.service"
        # TODO: enable in production, on a test VM it consumes all the space
        # "bitcoin-mempool.service"
      ];
      requires = [ "network-setup.service" "electrs.service" ];
      serviceConfig = {
        Type = "simple";
      };
      path = with pkgs; [
        nodejs
        bashInteractive
      ];
      script = ''
        CURRENT_BACKEND=$(cat /etc/mempool/backend | echo "")

        if [ "$CURRENT_BACKEND" == "" ]; then
          echo "no mempool backend had been built yet, exiting. The successful build will start this service automatically"
          exit 0
        fi
        cd "/var/lib/containers/$CURRENT_BACKEND/etc/mempool/backend"
        # deploy the config
        cp "${mempool_config}" ./
        npm run start
      '';
    };
    # define containers, in which the actual build will be running in an isolated filesystem, but with Internet access
    containers.${mempool-backend-build-container-name} = {
      privateNetwork = true;
      hostAddress = "192.168.254.1";
      localAddress = "192.168.254.2";
      config = {
        # those options will help to speedup evaluation of container's configurate
        documentation.doc.enable = false;
        documentation.enable = false;
        documentation.info.enable = false;
        documentation.man.enable = false;
        documentation.nixos.enable = false;
        # DNS
        networking.nameservers = [
          "8.8.8.8"
          "8.8.4.4"
        ];
        environment.systemPackages = with pkgs; [
          nodejs
          python3
          make
        ];
        networking.hostName = "mempoolbackendbuilder";
      };
    };

    # this service will check if the build is needed and will start a build in a container
    systemd.services.mempool-backend-build = {
      wantedBy = [ "multi-user.target" ];
      after = [
        "network-setup.service"
      ];
      requires = [ "network-setup.service" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = "yes"; # this allows to run rebuilds only when either service's config or mempool's sources had been changed
      };
      path = with pkgs; [
        coreutils
        systemd
        nodejs
        bashInteractive
        mempool-backend-build-script
        nixos-container
        e2fsprogs
      ];
      script = ''
        set -ex # echo and fail on errors

        # ensure, that /etc/mempool dir exists, at it will be used later
        mkdir -p /etc/mempool/

        CURRENT_BACKEND=$(cat /etc/mempool/backend || echo "there-is-no-backend-yet")
        # first of all, cleanup old builds, that may had been interrupted
        for FAILED_BUILD in $(ls -1 /var/lib/containers | grep "mempoolbackendbuild" | grep -v "$CURRENT_BACKEND" || echo "");
        do
          # stop if the build haven't been shutted down
          systemctl stop "container@$FAILED_BUILD" || true
          # remove the container's fs
          chattr -i "/var/lib/containers/$FAILED_BUILD/var/empty" || true
          rm -rf "/var/lib/containers/$FAILED_BUILD" || true
        done

        if [ "$CURRENT_BACKEND" == "${mempool-backend-build-container-name}" ]; then
          echo "${mempool-backend-build-container-name} is already active backend, do nothing"
          exit 0
        fi

        # we are here, because $CURRENT_BACKEND is not ${mempool-backend-build-container-name}

        # remove the build container dir, just in case if it exists already
        systemctl stop "container@${mempool-backend-build-container-name}" || true
        chattr -i "/var/lib/container/${mempool-backend-build-container-name}/var/empty" || true
        rm -rf "/var/lib/container/${mempool-backend-build-container-name}"

        # start build container
        systemctl start container@${mempool-backend-build-container-name}
        # wait until it will shutdown
        nixos-container run "${mempool-backend-build-container-name}" -- "${mempool-backend-build-script}/bin/mempool-backend-build-script" 2>&1 > /etc/mempool/backend-lastlog && {
          # if build was successfull
          # stop the container as it is not needed anymore
          systemctl stop "container@${mempool-backend-build-container-name}" || true
          # move the result of the build out of container's root
          mv "/var/lib/containers/${mempool-backend-build-container-name}/etc/mempool/backend" "/var/lib/containers/${mempool-backend-build-container-name}-tmp"
          # remove build's fs
          chattr -i "/var/lib/containers/${mempool-backend-build-container-name}/var/empty" || true
          rm -rf "/var/lib/containers/${mempool-backend-build-container-name}"
          # move the result back
          mkdir -p "/var/lib/containers/${mempool-backend-build-container-name}/etc/mempool"
          mv "/var/lib/containers/${mempool-backend-build-container-name}-tmp" "/var/lib/containers/${mempool-backend-build-container-name}/etc/mempool/backend"
          # replace current backend with new one
          echo "${mempool-backend-build-container-name}" > /etc/mempool/backend
          # restart mempool-backend service
          systemctl restart mempool-backend
          # cleanup old /etc/mempool/backend's target
          rm -rf "/var/lib/container/$CURRENT_BACKEND"
        }
        # else - just fail
      '';
    };
    # this configuration enables network for containers
    networking.firewall.trustedInterfaces = [ "ve-+" ];
    networking.nat.enable = true;
    networking.nat.extraCommands = ''
      iptables -t nat -A POSTROUTING -s 192.168.254.0/24 -j MASQUERADE
    '';
  };
}