{ ... }:
{
  perSystem =
    { pkgs, lib, ... }:
    let
      package = pkgs.callPackage ./_package.nix {
        guileLibs = import ./_guile-libs.nix pkgs;
        inherit (pkgs) buildEnv;
        graph = builtins.fromJSON (builtins.readFile ./deps.json);
      };

      tests = import ./_tests.nix {
        inherit package lib;
        inherit (pkgs)
          stdenv
          guile_3_0
          symlinkJoin
          ;
        guileLibs = import ./_guile-libs.nix pkgs;
      };
    in
    rec {
      packages.default = package;

      # The package has to build, and every suite has to pass. Each suite is its own
      # check, so `nix flake check` runs them in parallel and names the one that failed;
      # `tests` is all of them behind one path.
      checks = {
        kagi-api-scm = packages.default;
        tests = tests.aggregate;
      }
      // tests.all;
    };
}
