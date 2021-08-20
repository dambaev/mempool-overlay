self: super:
let
  mempool-frontend-nginx-configs = self.callPackage ./mempool-frontend-nginx-configs.nix {};
in
{
  mempool-frontend-nginx-common-config = mempool-frontend-nginx-configs.mempool-frontend-nginx-common-config;
  mempool-frontend-nginx-append-config = mempool-frontend-nginx-configs.mempool-frontend-nginx-append-config;
  mempool-frontend-nginx-events-config = mempool-frontend-nginx-configs.mempool-frontend-nginx-events-config;
  mempool-frontend-nginx-server-config = mempool-frontend-nginx-configs.mempool-frontend-nginx-server-config;
  mempool-frontend-nginx-config = mempool-frontend-nginx-configs.mempool-frontend-nginx-config;
}

