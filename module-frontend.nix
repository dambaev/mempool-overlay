{config, pkgs, options, lib, ...}:
let
  mempool-source-set = import ./mempool-sources-set.nix;
  mempool-source = pkgs.fetchzip mempool-source-set;
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

    # create mempool systemd service
    systemd.services.mempool-frontend =
    let
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
        CURRENT_FRONTEND=$(cat /etc/mempool/frontend || echo "")
        if [ ! -d "/var/lib/containers/$CURRENT_FRONTEND" ]; then
           # sources' commit is the same, but frontend is forced to be rebuilt as it is not exist
           CURRENT_FRONTEND=""
        fi

        if [ "$CURRENT_FRONTEND" == "" ]; then
          echo "no mempool frontend had been built yet, exiting. The successful build will start this service automatically"
          exit 0
        fi
        cd "/var/lib/containers/$CURRENT_FRONTEND/etc/mempool/frontend"
        npm run start
      '';
    };
    # define containers, in which the actual build will be running in an isolated filesystem, but with Internet access
    containers.${mempool-frontend-build-container-name} = {
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
          # move the result of the build out of container's root
          mv "/var/lib/containers/${mempool-frontend-build-container-name}/etc/mempool/frontend" "/var/lib/containers/${mempool-frontend-build-container-name}-tmp"
          # remove build's fs
          chattr -i "/var/lib/containers/${mempool-frontend-build-container-name}/var/empty" || true
          rm -rf "/var/lib/containers/${mempool-frontend-build-container-name}"
          # move the result back
          mkdir -p "/var/lib/containers/${mempool-frontend-build-container-name}/etc/mempool"
          mv "/var/lib/containers/${mempool-frontend-build-container-name}-tmp" "/var/lib/containers/${mempool-frontend-build-container-name}/etc/mempool/frontend"
          # replace current frontend with new one
          echo "${mempool-frontend-build-container-name}" > /etc/mempool/frontend
          # restart mempool-frontend service
          systemctl restart mempool-frontend
          # cleanup old /etc/mempool/frontend's target
          rm -rf "/var/lib/container/$CURRENT_FRONTEND"
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