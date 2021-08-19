self: super:
let
  mempool-frontend-nginx-configs = self.callPackage ./mempool-frontend-nginx-configs.nix {};
in
{
  mempool-frontend-nginx-events-config = mempool-frontend-nginx-configs.mempool-frontend-nginx-events-config;
  mempool-frontend-nginx-server-config = mempool-frontend-nginx-configs.mempool-frontend-nginx-server-config;
}

