# Brief

This repo contains NixOS overlay for https://github.com/mempool/mempool
The purpose of this repo is to produce a support for running backend and frontend on NixOS.

# Development

It is supposed, that you are doing the development of backend/frontend the usual way as you always do.
In case if you are using NixOS for development, you can setup your development environment with

```
nix-shell -p shell.nix
```

then, you can build and run as usually:

```
cd backend
npm run install
npm run build
npm run start
```

or

```
cd frontend
npm run install
npm run build
npm run start
<browse http://localhost:4200>
```

So, NixOS adds quite little to the development process.

# Deployment

## Highlevel API

Mempool is basically a frontend, which requires one or more backend services. As there is no strong requirement on keeping backend instances alongside to frontend, there are 2 different
config endpoints which allow to use frontend separately from backend on a specific node.

- `services.mempool-backend.*` - for using backend services;
- `services.mempool-frontend.*` - for using frontend service;

### Frontend service

In order to enable frontend service, you need to add:

```
services.mempool-frontend = {
  enable = true;
  testned_enabled = true; # default is false
  signet_enabled = true; # default is false
};
```

where:

- `services.mempool-frontend.enable = true`- enables the frontend service on the host.
- `services.mempool-frontend.testnet_enabled = true` - enables compile-time switch to enable testnet-related part of the frontend
- `services.mempool-frontend.signet_enabled = true` - enables compile-time switch to enable signet-related part of the frontend

Please, refer `module-frontend.nix` for reference of the definition.

### Backend services

As there are multiple networks supported by Mempool, there can be multiple backends running in parallel, serving different network types. In order to provide multiple parallel instances, we are using a set of options do define backends. In terms of NixOS such type is called 'submodules'. You can refer `module-backend.nix`/`mempoolInstanceOpt` for definition of such 'submodule'. Example of usage:

```
  services.mempool-backend = {
    mainnet = {
      db_name = "mempool";
      db_user = "mempool";
      db_psk = "secret";
      config = ''
            "MEMPOOL": {
              "NETWORK": "mainnet",
              "BACKEND": "electrum",
            },
            "ELECTRUM": {
              "HOST": "127.0.0.1",
              "PORT": 50001,
              "TLS_ENABLED": true,
      '';
    };
    testnet = {
      db_name = "tmempool";
      db_user = "tmempool";
      db_psk = "tsecret";
      config = ''
            "MEMPOOL": {
              "NETWORK": "testnet",
              "BACKEND": "electrum",
            },
            "ELECTRUM": {
              "HOST": "127.0.0.1",
              "PORT": 60001,
              "TLS_ENABLED": true,
            }
      '';
    };
  };
  services.electrs = {
    mainnet = {
      db_dir = "/path/to/electrs/mainnet/datadir";
      cookie_file = "/path/to/bitcoind/mainnet/data/dir/.cookie";
      blocks_dir = "/path/to/bitcoind/mainnet/data/dir/blocks";
    };
    testnet = { # testnet instance
      db_dir = "/path/to/electrs/testnet/data/dir";
      cookie_file = "/path/to/bitcoind/testnet/data/dir/.cookie";
      blocks_dir = "/path/to/bitcoind/testnet/data/dir/blocks";
      network = "testnet";
      rpc_listen = "127.0.0.1:60001";
    };
  };
  services.bitcoind = {
    mainnet = {
      enable = true;
      dataDir = "/path/to/bitcoin/mainnet/data/dir"; # move the data into a separate volume, see hardware-configuration.nix for mount points
      extraConfig = ''
        txindex = 1
      '';
      rpc.users = {
        mempool = {
          name = "mempool";
          passwordHMAC = "<bitcoind-mainnet-rpc-pskhmac>";
        };
      };
    };
    testnet = { # bitcoind testnet instance
      enable = true;
      dataDir = "/path/to/bitcoind/testnet/data/dir";
      testnet = true;
      extraConfig = ''
        txindex = 1
      '';
      rpc.users = {
        tmempool = {
          name = "tmempool";
          passwordHMAC = "<bitcoind-testnet-rpc-pskhmac>";
        };
      };
    };
  };
```

in this example, there are:
- 2 instances of mempool-backend: mainnet and testnet;
- 2 instances of electrs (mainnet and testnet);
- 2 instances of bitcoind (mainnet and testnet).

As you can see, currently, we don't provide strict dependency on the electrs, bitcoind or mempool-backend instances, as those can be running on a different node. That is why things like rpc ports should be specified manually. In the future, though, we can introduce an option to define all the chain of mempool-frontend->{mempool-backend-> electrs -> bitcoind} dependencies which will make possible to define such shared details (like RPC Ports) under the hood instead of manually keeping track of it.

## Implementation details

Canonical NixOS services relies on a nix-derivations and pinning to specific channel commit for building 100% reproducible environments. Although, we are following the same goal, we have fund, that:
1. mempool backend/frontend relies on a huge amount of node.js libraries;
2. `node2nix` is not able to fully reproduce the same environment as `npm`;
3. `node2nix` does not handles some steps, that are being performed by `npm run build` of the frontend;
4. mempool-backend expects to have it's config file stored in the root dir of the mempool-backend, which means, that in case of canonical nix-derivation, changing the config will trigger derivation to be rebuilt (although, this behavior can be patched).

All of that made us think, that currently, replacing `npm` with `nix` by using `node2nix` requires too much manual work and it will be enough to rely on `npm` as a package manage (instead of using both `nix` and `npm`, as both are package managers), but keeping following assumptions:
1. mempool's devs pin node.js packages accurately enough to provide environment, that is 'reproducible enough';
2. based on assumption 1, we assume, that running `npm run build` in an environment, which has access to Internet is still okay.

So this repo, at the moment, does not provides nix-expressions in a canonical way, ie, which can be included in a binary cache and sent to different nodes.

Instead, we decided, that we will provide a clean environment with Internet access available to run the build process for backend and frontend and use the result of such build process for running the service.

Implementation of such non-canonical way relies on:
1. `mempool-backend-build` systemd-service, which goal is to be started after any sucessful `nixos-rebuild switch` execution and checking if rebuilding process of the mempool-backend should be started;
2. `mempoolbackendbuild<hash>` container, which goal is to provide an isolated filesystem with only node.js available in the PATH. In this container the actual build process is being done. This container has access to the Internet and only relying on `npm` to run the build;
3. `mempool-frontend-build` systemd-service, which goal, by analogy to `mempool-backend-build` service, to be started after any sucessful `nixos-rebuild switch` execution and to check if the rebuilding process should be started;
4. `mempoolfrontendbuild<hash>` container, which goal is to run the actual build process of the frontend in an isolated filesystem with only node.js available. Internet is available in this container as well.

In order to be able to run build process of the 'new' backend/frontend instances alongside with running 'previous' backend/frontend, such services relies on a storing hash of the 'current' instances in the `/etc/mempool` directory. Any sucessful build will overwrite such hashes in `/etc/mempool` directory and restart the services to switch to the new version of instances.


# Difference with mempool's production how-to

