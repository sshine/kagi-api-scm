{ inputs, ... }:
{
  imports = [ inputs.devshell.flakeModule ];
  perSystem =
    { config, pkgs, ... }:
    let
      guileEnv = pkgs.buildEnv {
        name = "kagi-guile-env";
        paths = [ pkgs.guile_3_0 ] ++ import ./_guile-libs.nix pkgs;
      };
    in
    {
      devshells.default = {
        packages = [
          guileEnv
          config.treefmt.build.wrapper
          config.hk-nix.package
          pkgs.deadnix
          pkgs.git
          pkgs.just
          pkgs.jq
          pkgs.curl
          pkgs.secretspec
        ];

        env = [
          # `nix shell` does not set these, and Guile finds neither its own modules nor
          # (json)/(gnutls) without them. $PRJ_ROOT/src comes first so the working tree
          # always wins over anything in the store: a module being edited must shadow any
          # copy of it in the store.
          {
            name = "GUILE_LOAD_PATH";
            prefix = "${guileEnv}/share/guile/site/3.0";
          }
          {
            name = "GUILE_LOAD_PATH";
            prefix = "$PRJ_ROOT/src";
          }
          {
            name = "GUILE_LOAD_COMPILED_PATH";
            prefix = "${guileEnv}/lib/guile/3.0/site-ccache";
          }
          # Running interpreted is correct here, not a compromise: a developer editing a
          # module should see the edit without a compile step.
          {
            name = "GUILE_AUTO_COMPILE";
            value = "0";
          }
        ];

        devshell.motd = "";
        devshell.startup.hk.text = config.hk-nix.shellHook;
      };
    };
}
