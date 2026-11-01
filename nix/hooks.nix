{ inputs, ... }:
{
  imports = [ inputs.hk-nix.flakeModules.default ];
  perSystem =
    {
      config,
      pkgs,
      lib,
      ...
    }:
    let
      # Uses tools by absolute store path: the `nix flake check` hk-check sandbox runs
      # hooks without the devshell PATH, so a relative `treefmt` is not found.
      treefmt = lib.getExe config.treefmt.build.wrapper;

      guileEnv = pkgs.buildEnv {
        name = "kagi-guile-env";
        paths = [ pkgs.guile_3_0 ] ++ import ./_guile-libs.nix pkgs;
      };

      # Guile's compiler is the linter: it resolves every toplevel and checks arities and
      # format strings. The loop is required because `guild compile -o` names one output.
      guild-lint = pkgs.writeShellScript "kagi-guild-lint" ''
        export GUILE_LOAD_PATH="$PWD/src:${guileEnv}/share/guile/site/3.0"
        export GUILE_AUTO_COMPILE=0
        # Output goes to a scratch tree, not /dev/null: guild writes atomically via
        # mkstemp, so a non-regular output path fails before it compiles anything.
        tmp=$(mktemp -d)
        trap 'rm -rf "$tmp"' EXIT
        status=0
        for f in "$@"; do
          # guild exits 0 on a warning, so the diagnostics themselves are the signal.
          # `;;; note:` lines are Guile reporting a stale auto-compile cache entry, not a
          # problem in the file.
          out=$(${guileEnv}/bin/guild compile -L "$PWD/src" -O1 \
            -Wunbound-variable -Wmacro-use-before-definition \
            -Warity-mismatch -Wformat \
            -o "$tmp/$(echo "$f" | tr / _).go" "$f" 2>&1 >/dev/null \
            | grep -v '^;;;')
          if [ -n "$out" ]; then echo "$out"; status=1; fi
        done
        exit $status
      '';

      whitespace = pkgs.writeShellScript "kagi-whitespace" ''
        status=0
        for f in "$@"; do
          case "$f" in *.scm) ;; *) continue ;; esac
          if ${pkgs.gnugrep}/bin/grep -nP '\t' "$f"; then
            echo "  ^ tab in $f"; status=1
          fi
          if ${pkgs.gnugrep}/bin/grep -nP ' +$' "$f"; then
            echo "  ^ trailing space in $f"; status=1
          fi
          if [ -s "$f" ] && [ -n "$(tail -c1 "$f")" ]; then
            echo "$f: no newline at end of file"; status=1
          fi
        done
        exit $status
      '';

      run-tests = pkgs.writeShellScript "kagi-run-tests" ''
        export GUILE_LOAD_PATH="${guileEnv}/share/guile/site/3.0"
        export GUILE_AUTO_COMPILE=0
        cache=$(mktemp -d)
        trap 'rm -rf "$cache"' EXIT
        XDG_CACHE_HOME="$cache" ${guileEnv}/bin/guile -L "$PWD/src" -L "$PWD/tests" -s "$PWD/tests/run-tests.scm"
      '';
    in
    {
      hk-nix.settings.hooks = {
        "pre-commit" = {
          fix = true;
          stash = "git";
          steps = {
            treefmt.check = "${treefmt} --fail-on-change --no-cache --excludes 'tests/fixtures/**' {{files}}";
            treefmt.fix = "${treefmt} --excludes 'tests/fixtures/**' {{files}}";
            whitespace.check = "${whitespace} {{files}}";
          };
        };

        "pre-push".steps = {
          deadnix.glob = "*.nix";
          deadnix.check = "${lib.getExe pkgs.deadnix} --fail {{files}}";
          guild.glob = "src/**/*.scm";
          guild.check = "${guild-lint} {{files}}";
          test.check = "${run-tests}";
        };

        "commit-msg".steps.conventional.builtin = config.hk-nix.builtins.check_conventional_commit;
      };
    };
}
