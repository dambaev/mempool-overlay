# derivations for node.js-based applications in NixOS are supposed to be generated by node2nix
{ stdenv, pkgs, fetchurl }:
let
  source = fetchurl {
    url = "https://github.com/mempool/mempool/archive/refs/tags/v2.2.0.tar.gz";
    sha256 = "1gccza1s28ja78iyqv5h22ix5w21acbvffahsb5ifn27q4bq8mk3";
  };

  backend_derivation =
  let
    nodeDependencies = ( pkgs.callPackage ./mempool-backend.nix {}).shell.nodeDependencies;
    initial_script = pkgs.writeText "initial_script.sql" ''
      CREATE USER IF NOT EXISTS mempool@localhost IDENTIFIED BY 'mempool';
      ALTER USER mempool@localhost IDENTIFIED BY 'mempool';
      flush privileges;
    '';
  in stdenv.mkDerivation {
    name = "mempool-backend";

    src = source;
    buildInputs = with pkgs;
    [ nodejs
      python
    ];
    preConfigure = "cd backend";
    buildPhase = ''
      export PATH="${nodeDependencies}/bin:$PATH"
      # if there is no HOME var, then npm will try to write to root dir, for which it has no write permissions to, so we provide HOME var
      export HOME=./home

      # and create this dir as well
      mkdir $HOME

      # copy contents of the node_modules, following symlinks, such that current build/install will be able to modify local copies
      cp -Lr ${nodeDependencies}/lib/node_modules ./node_modules
      # allow user to write. the build will try to write into ./node_modules/@types/node
      chmod -R u+w ./node_modules
      # we already have populated node_modules dir, so we don't need to run `npm install`
      npm run build
    '';
    installPhase = ''
      mkdir -p $out/backend
      cp -r ./node_modules $out/backend
      cp -r dist $out/backend
      cp package.json $out/backend/ # needed for `npm run start`
      cp ../mariadb-structure.sql $out/backend # this schema will be useful for a module.nix file, which will populate the db from it.
      cp ${initial_script} $out/backend/initial_script.sql # script, which should setup DB user
    '';
    patches = [
      ./start_with_config_argument.patch # this patch adds support for '-c'/'--config' argument, so we can run `npm run start -- -c /path/to/config` later.
    ];
  };
  frontend_derivation =
  let
    nodeDependencies = ( pkgs.callPackage ./mempool-frontend.nix {}).shell.nodeDependencies;
  in stdenv.mkDerivation {
    name = "mempool-frontend";

    src = source;
    buildInputs = with pkgs;
    [ nodejs
      python
    ];
    preConfigure = ''
      cd frontend
      export NG_CLI_ANALYTICS=ci
    '';
    buildPhase = ''
      export PATH="${nodeDependencies}/bin:$PATH"
      # if there is no HOME var, then npm will try to write to root dir, for which it has no write permissions to, so we provide HOME var
      export HOME=./home

      # and create this dir as well
      mkdir $HOME

      export NG_CLI_ANALYTICS=ci
      # copy contents of the node_modules, following symlinks, such that current build/install will be able to modify local copies
      cp -Lr ${nodeDependencies}/lib/node_modules ./node_modules
      # allow user to write
      chmod -R u+w ./node_modules
      ng analytics off
      # we already have populated node_modules dir, so we don't need to run `npm install`
      npm run build
    '';
    installPhase = ''
      mkdir -p $out/frontend
      cp -r ./node_modules $out/frontend
      cp -r dist $out/frontend
      cp package.json $out/frontend/ # needed for `npm run start`
    '';
    patches = [
    ];
  };
in
{ mempool-backend = backend_derivation;
  mempool-frontend = frontend_derivation;
}