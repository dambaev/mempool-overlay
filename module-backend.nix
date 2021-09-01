{config, pkgs, options, lib, ...}:
let
  mempool-source-set = import ./mempool-sources-set.nix;
  mempool-source = pkgs.fetchzip mempool-source-set;
  mempool-backend-build-container-name = "mempoolbackendbuild${lib.substring 0 8 mempool-source-set.sha256}";
  initial_script = cfg:
    pkgs.writeText "initial_script.sql" ''
    CREATE USER IF NOT EXISTS ${cfg.db_user}@localhost IDENTIFIED BY '${cfg.db_psk}';
    ALTER USER ${cfg.db_user}@localhost IDENTIFIED BY '${cfg.db_psk}';
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

  eachMempool = config.services.mempool-backend;
  mempoolInstanceOpts = args: {
    options = {
      db_name = lib.mkOption {
        default = null;
        type = lib.types.str;
        example = "mempool";
        description = "Database name of the instance";
      };
      db_user = lib.mkOption {
        default = null;
        type = lib.types.str;
        example = "mempool";
        description = "Username to access instance's database";
      };
      db_psk = lib.mkOption {
        type = lib.types.str;
        default = null;
        example = "your-secret-from-out-of-git-store";
        description = ''
          This value defines a password for database user, which will be used by mempool backend instance to access database.
        '';
      };
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
  };
in
{
  options.services.mempool-backend = lib.mkOption {
    type = lib.types.attrsOf (lib.types.submodule mempoolInstanceOpts);
    default = {};
    description = "One or more mempool-backends";
    example = {
      mainnet = {
        config = ''
          {
            "ELECTRUM": {
              "HOST": "127.0.0.1",
              "PORT": 50002,
              "TLS_ENABLED": true,
            }
        '';
      };
    };
  };

  config = lib.mkIf (eachMempool != {}) {
    # enable mysql and declare mempool DB
    services.mysql = {
      enable = true;
      package = pkgs.mariadb; # there is no default value for this option, so we define one
      initialDatabases = lib.mapAttrsToList (name: cfg:
        { name = "${cfg.db_name}";
          schema = "${mempool-source}/mariadb-structure.sql";
        }
      ) eachMempool;
      ensureUsers = lib.mapAttrsToList (name: cfg:
        { name = "${cfg.db_user}";
          ensurePermissions = {
            "${cfg.db_name}.*" = "ALL PRIVILEGES";
          };
        }
      ) eachMempool;
    };
    systemd.services = {
      mysql-mempool-users = {
        wantedBy = [ "multi-user.target" ];
        after = [
          "mysql.service"
        ];
        requires = [
          "mysql.service"
        ];
        serviceConfig = {
          Type = "simple";
        };
        path = with pkgs; [
          mariadb
        ];
        script = lib.foldl' (acc: i: acc + i) '''' ( lib.mapAttrsToList (name: cfg:
          ''cat "${initial_script cfg}" | mysql -uroot\n''
        ) eachMempool);
      };
    } // { # this service will check if the build is needed and will start a build in a container
      mempool-backend-build = {
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
          nodejs
          bashInteractive
          mempool-backend-build-script
          nixos-container
          e2fsprogs
        ];
        script =
          let
            # we have to render script to restart all the defined backend instances
            restart-mempool-backends-script = lib.foldl' (acc: i: acc+i) '''' (lib.mapAttrsToList (name: cfg:
            "systemctl restart mempool-backend-${name}\n"
            ) eachMempool);
          in
          ''
          set -ex # echo and fail on errors

          # ensure, that /etc/mempool dir exists, at it will be used later
          mkdir -p /etc/mempool/

          CURRENT_BACKEND=$(cat /etc/mempool/backend || echo "there-is-no-backend-yet")
          if [ ! -d "/var/lib/containers/$CURRENT_BACKEND" ]; then
            # sources' commit is the same, but backend is forced to be rebuilt as it is not exist
            CURRENT_BACKEND="there-is-no-backend-yet"
          fi
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
            # restart mempool-backend services
            ${restart-mempool-backends-script}
            # cleanup old /etc/mempool/backend's target
            rm -rf "/var/lib/container/$CURRENT_BACKEND"
          }
          # else - just fail
        '';
      };
    } //
    ( lib.mapAttrs' (name: cfg: lib.nameValuePair "mempool-backend-${name}" (
    let
      mempool_config = pkgs.writeText "mempool-backend.json" cfg.config; # this renders config and stores in /nix/store
    in {
      wantedBy = [ "multi-user.target" ];
      after = [
        "network-setup.service"
      ];
      requires = [ "network-setup.service" ];
      serviceConfig = {
        Type = "simple";
      };
      path = with pkgs; [
        nodejs
        bashInteractive
      ];
      script = ''
        set -ex
        CURRENT_BACKEND=$(cat /etc/mempool/backend || echo "")
        if [ ! -d "/var/lib/containers/$CURRENT_BACKEND/etc/mempool/backend" ]; then
           # sources' commit is the same, but backend is forced to be rebuilt as it is not exist
           CURRENT_BACKEND=""
        fi

        if [ "$CURRENT_BACKEND" == "" ]; then
          echo "no mempool backend had been built yet, exiting. The successful build will start this service automatically"
          exit 0
        fi
        if [ ! -d "/var/lib/containers/$CURRENT_BACKEND-${name}/etc/mempool/backend" ]; then
          # we know, that "/var/lib/containers/$CURRENT_BACKEND/etc/mempool/backend" exist 
          cp -r "/var/lib/containers/$CURRENT_BACKEND" "/var/lib/containers/$CURRENT_BACKEND-${name}"
        fi
        cd "/var/lib/containers/$CURRENT_BACKEND-${name}/etc/mempool/backend"
        # deploy the config
        cp "${mempool_config}" ./mempool-config.json
        npm run start-production
      '';
    })) eachMempool);
    # define containers, in which the actual build will be running in an isolated filesystem, but with Internet access
    containers.${mempool-backend-build-container-name} = {
      config = {
        # those options will help to speedup evaluation of container's configurate
        documentation.doc.enable = false;
        documentation.enable = false;
        documentation.info.enable = false;
        documentation.man.enable = false;
        documentation.nixos.enable = false;
        environment.systemPackages = with pkgs; [
          nodejs
          python3
          gnumake
          gcc
        ];
      };
    };

  };
}