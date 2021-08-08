self: super: {
  mempool-backend = (self.callPackage ./derivation.nix {}).mempool-backend;
  mempool-frontend = (self.callPackage ./derivation.nix {}).mempool-frontend;
}
