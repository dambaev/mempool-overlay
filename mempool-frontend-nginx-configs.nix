{ stdenv, pkgs, fetchzip, fetchpatch, fetchgit, fetchurl }:
let
  mempool-sources-set = import ./mempool-sources-set.nix;
  server-config = stdenv.mkDerivation {
    name = "mempool-frontend-nginx-server-config";
  
    src = fetchzip mempool-sources-set;
    buildInputs = with pkgs;
    [ gnused
    ];
    buildPhase = ''
      set -ex
      # we don't need to provide paths to logs explicitly
      sed -i '/^[	 ]*error_log/d' nginx-mempool.conf
      sed -i '/^[	 ]*access_log/d' nginx-mempool.conf
      # the root directive will be given by nixos config
      sed -i '/^[	 ]*root */d' nginx-mempool.conf
    '';
    installPhase = ''
      mkdir -p $out
      cp nginx-mempool.conf $out/nginx.conf
    '';
  };

  # the result of this derivation contains the 'events' part of original config
  events-config = stdenv.mkDerivation {
    name = "mempool-frontend-nginx-events-config";

    src = fetchzip mempool-sources-set;
    buildInputs = with pkgs;
    [ gnused
    ];
    buildPhase = "true"; # provide the empty build phase so evaluation will be successful
    installPhase = ''
      mkdir -p $out
      sed -n '/^events *{.*/,/.*}/p' ./nginx.conf  | head -n -1 | tail -n +2 > $out/nginx.conf
    '';
  };

  # the result of this derivation contains the 'events' part of original config
  append-config = stdenv.mkDerivation {
    name = "mempool-frontend-nginx-append-config";

    src = fetchzip mempool-sources-set;
    buildInputs = with pkgs;
    [ gnused
    ];
    buildPhase = ''
      sed -i '/^events *{.*/,/.*}/d' ./nginx.conf
      sed -i '/^http *{.*/,/^}/d' ./nginx.conf
      sed -i '/^user *.*/d' nginx.conf
      sed -i '/^pid *.*/d' nginx.conf
    '';
    installPhase = ''
      mkdir -p $out
      cp nginx.conf $out/
    '';
  };

  # the result of this derivation contains the 'http' part (except 'server' part) of the original config
  common-config = stdenv.mkDerivation {
    name = "mempool-frontend-nginx-common-config";

    src = fetchzip mempool-sources-set;
    buildInputs = with pkgs;
    [ gnused
    ];
    buildPhase = ''
      sed -n '/^http *{.*/,/^}/p' ./nginx.conf | head -n -1 | tail -n +2 > ./common.conf
      sed -i '/^[ ]*server[ ]*{/,/.*}/d' common.conf
      sed -i '/^[	 ]*access_log/d' common.conf
      sed -i '/^[	 ]*error_log/d' common.conf
      sed -i '/^[	 ]*include/d' common.conf
      
      sed -i '/^[	 ]*server_tokens/d' common.conf
      sed -i '/^[	 ]*default_type/d' common.conf
      sed -i '/^[	 ]*client_max_body_size/d' common.conf
    '';
    installPhase = ''
      mkdir -p $out
      cp common.conf $out/nginx.conf
    '';
  };

  # the result of this derivation contains the 'http' part (except 'server' part) of the original config
  all-config = stdenv.mkDerivation {
    name = "mempool-frontend-nginx-config";

    src = fetchzip mempool-sources-set;
    buildInputs = with pkgs;
    [ gnused
      gawk
    ];
    buildPhase = ''
      grep "client_max_body_size" ./nginx.conf | awk '{print $2}' | tr -d ';' > client_max_body_size.txt
      grep "server_tokens" ./nginx.conf | awk '{print $2}' | tr -d ';' > server_tokens.txt
    '';
    installPhase = ''
      mkdir -p $out
      cp client_max_body_size.txt $out/
      cp server_tokens.txt $out/
    '';
  };
in {
  mempool-frontend-nginx-server-config = server-config;
  mempool-frontend-nginx-events-config = events-config;
  mempool-frontend-nginx-append-config = append-config;
  mempool-frontend-nginx-common-config = common-config;
  mempool-frontend-nginx-config = all-config;
}
