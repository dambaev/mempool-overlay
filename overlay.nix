self: super: {
  mempool = self.callPackage ./derivation.nix {};
}
