{
  flake.overlays.default = final: _prev: {
    kagi-api-scm = final.callPackage ./_package.nix {
      guileLibs = import ./_guile-libs.nix final;
      inherit (final) buildEnv;
      graph = builtins.fromJSON (builtins.readFile ./deps.json);
    };
  };
}
