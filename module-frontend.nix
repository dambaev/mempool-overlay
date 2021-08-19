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
    services.nginx = {
      enable = true;
      appendConfig = ''
        worker_processes auto;
        worker_rlimit_nofile 100000;
      '';
      eventsConfig = ''
        worker_connections 9000;
        multi_accept on;
      '';
      serverTokens = false;
      clientMaxBodySize = "10m";
      commonHttpConfig = ''
        sendfile on;
        tcp_nopush on;
        tcp_nodelay on;

        server_name_in_redirect off;

        # reset timed out connections freeing ram
        reset_timedout_connection on;
        # maximum time between packets the client can pause when sending nginx any data
        client_body_timeout 10s;
        # maximum time the client has to send the entire header to nginx
        client_header_timeout 10s;
        # timeout which a single keep-alive client connection will stay open
        keepalive_timeout 69s;
        # maximum time between packets nginx is allowed to pause when sending the client data
        send_timeout 10s;

        # number of requests per connection, does not affect SPDY
        keepalive_requests 100;

        # enable gzip compression
        gzip on;
        gzip_vary on;
        gzip_comp_level 6;
        gzip_min_length 1000;
        gzip_proxied expired no-cache no-store private auth;
        # text/html is always compressed by gzip module
        gzip_types application/javascript application/json application/ld+json application/manifest+json application/x-font-ttf application/x-web-app-manifest+json application/xhtml+xml application/xml font/opentype image/bmp image/svg+xml image/x-icon text/cache-manifest text/css text/plain text/vcard;

        # proxy cache
        proxy_cache off;
        proxy_cache_path /var/cache/nginx keys_zone=cache:20m levels=1:2 inactive=600s max_size=500m;
        types_hash_max_size 2048;

        # exempt localhost from rate limit
        geo $limited_ip {
          default		1;
          127.0.0.1	0;
        }
        map $limited_ip $limited_ip_key {
          1 $binary_remote_addr;
          0 \'\';
        }

        # rate limit requests
        limit_req_zone $limited_ip_key zone=api:5m rate=200r/m;
        limit_req_zone $limited_ip_key zone=electrs:5m rate=2000r/m;
        limit_req_status 429;

        # rate limit connections
        limit_conn_zone $limited_ip_key zone=websocket:10m;
        limit_conn_status 429;

        map $http_accept_language $header_lang {
          default en-US;
          ~*^en-US en-US;
          ~*^en en-US;
                ~*^ar ar;
                ~*^ca ca;
                ~*^cs cs;
                ~*^de de;
                ~*^es es;
                ~*^fa fa;
                ~*^fr fr;
                ~*^ko ko;
                ~*^it it;
                ~*^he he;
                ~*^ka ka;
                ~*^hu hu;
                ~*^nl nl;
                ~*^ja ja;
                ~*^nb nb;
                ~*^pl pl;
                ~*^pt pt;
                ~*^ru ru;
                ~*^sl sl;
                ~*^fi fi;
                ~*^sv sv;
                ~*^tr tr;
                ~*^uk uk;
                ~*^vi vi;
                ~*^zh zh;
                ~*^hi hi;
        }

        map $cookie_lang $lang {
          default $header_lang;
          ~*^en-US en-US;
          ~*^en en-US;
                ~*^ar ar;
                ~*^ca ca;
                ~*^cs cs;
                ~*^de de;
                ~*^es es;
                ~*^fa fa;
                ~*^fr fr;
                ~*^ko ko;
                ~*^it it;
                ~*^he he;
                ~*^ka ka;
                ~*^hu hu;
                ~*^nl nl;
                ~*^ja ja;
                ~*^nb nb;
                ~*^pl pl;
                ~*^pt pt;
                ~*^ru ru;
                ~*^sl sl;
                ~*^fi fi;
                ~*^sv sv;
                ~*^tr tr;
                ~*^uk uk;
                ~*^vi vi;
                ~*^zh zh;
                ~*^hi hi;
        }
      '';

      virtualHosts.mempool = {
        root = "/etc/mempool/frontend_www";
        extraConfig = ''
          index index.html;

          # enable browser and proxy caching
          add_header Cache-Control "public, no-transform";

          # vary cache if user changes language preference
          add_header Vary Accept-Language;
          add_header Vary Cookie;

          # fallback for all URLs i.e. /address/foo /tx/foo /block/000
          location / {
            try_files /$lang/$uri /$lang/$uri/ $uri $uri/ /en-US/$uri @index-redirect;
            expires 10m;
          }
          location /resources {
            try_files /$lang/$uri /$lang/$uri/ $uri $uri/ /en-US/$uri @index-redirect;
            expires 1h;
          }
          location @index-redirect {
            rewrite (.*) /$lang/index.html;
          }

          # location block using regex are matched in order

          # used to rewrite resources from /<lang>/ to /en-US/
          location ~ ^/(ar|bg|bs|ca|cs|da|de|et|el|es|eo|eu|fa|fr|gl|ko|hr|id|it|he|ka|lv|lt|hu|mk|ms|nl|ja|nb|nn|pl|pt|pt-BR|ro|ru|sk|sl|sr|sh|fi|sv|th|tr|uk|vi|zh|hi)/resources/ {
            rewrite ^/[a-zA-Z-]*/resources/(.*) /en-US/resources/$1;
          }
          # used for cookie override
          location ~ ^/(ar|bg|bs|ca|cs|da|de|et|el|es|eo|eu|fa|fr|gl|ko|hr|id|it|he|ka|lv|lt|hu|mk|ms|nl|ja|nb|nn|pl|pt|pt-BR|ro|ru|sk|sl|sr|sh|fi|sv|th|tr|uk|vi|zh|hi)/ {
            try_files $uri $uri/ /$1/index.html =404;
          }

          # static API docs
          location = /api {
            try_files $uri $uri/ /en-US/index.html =404;
          }
          location = /api/ {
            try_files $uri $uri/ /en-US/index.html =404;
          }

          # mainnet API
          location /api/v1/donations {
            proxy_pass https://mempool.space;
          }
          location /api/v1/donations/images {
            proxy_pass https://mempool.space;
          }
          location /api/v1/contributors {
            proxy_pass https://mempool.space;
          }
          location /api/v1/contributors/images {
            proxy_pass https://mempool.space;
          }
          location /api/v1/ws {
            proxy_pass http://127.0.0.1:8999/;
            proxy_http_version 1.1;
            proxy_set_header Upgrade $http_upgrade;
            proxy_set_header Connection "Upgrade";
          }
          location /api/v1 {
            proxy_pass http://127.0.0.1:8999/api/v1;
          }
          location /api/ {
            proxy_pass http://127.0.0.1:8999/api/v1/;
          }

          # mainnet API
          location /ws {
            proxy_pass http://127.0.0.1:8999/;
            proxy_http_version 1.1;
            proxy_set_header Upgrade $http_upgrade;
            proxy_set_header Connection "Upgrade";
          }
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