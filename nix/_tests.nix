# One derivation per test suite.
#
# A single check phase running tests/run-tests.scm walks the suites one at a time, so the
# check costs the sum of them. Here each suite is a derivation of its own and Nix runs
# several at once. The list of suites is the directory, not a hand-written one: adding
# tests/foo-test.scm adds a check.
{
  lib,
  stdenv,
  guile_3_0,
  guileLibs,
  symlinkJoin,
  package,
  srcRoot ? ../.,
}:
let
  testDir = srcRoot + "/tests";

  suiteNames = map (lib.removeSuffix "-test.scm") (
    builtins.filter (lib.hasSuffix "-test.scm") (builtins.attrNames (builtins.readDir testDir))
  );

  # The suites load modules from source. README.md is here because the live suite does not
  # read it, but keeping it makes the tree the same shape as a checkout for no cost.
  src = lib.fileset.toSource {
    root = srcRoot;
    fileset = lib.fileset.unions [
      (srcRoot + "/src")
      (srcRoot + "/tests")
      (srcRoot + "/README.md")
    ];
  };

  suite =
    name:
    stdenv.mkDerivation {
      pname = "kagi-api-scm-test-${name}";
      version = "0.1.0";
      inherit src;

      nativeBuildInputs = [ guile_3_0 ];
      # The package as well as the sources. Guile's setup hook puts its
      # lib/guile/3.0/site-ccache on GUILE_LOAD_COMPILED_PATH, so a suite loads the shipped
      # .go files instead of compiling every module it imports.
      buildInputs = [
        guile_3_0
        package
      ]
      ++ guileLibs;

      dontConfigure = true;
      # Run in the store path rather than a copy of it. A suite only reads the tree;
      # everything it writes goes to TMPDIR.
      dontUnpack = true;

      # --no-auto-compile, as run-tests.scm invokes a suite, so a suite here and a suite
      # under `just test-one` are the same run. Live tests skip unless KAGI_LIVE=1: the
      # sandbox has neither a route out nor the key.
      buildPhase = ''
        runHook preBuild
        cd "$src"
        export XDG_CACHE_HOME=$(mktemp -d)
        export GUILE_AUTO_COMPILE=0
        guile --no-auto-compile -L src -L tests -s "tests/${name}-test.scm"
        runHook postBuild
      '';

      installPhase = ''
        runHook preInstall
        mkdir -p $out
        runHook postInstall
      '';
    };
in
rec {
  inherit suiteNames suite;

  # Every suite, so `nix flake check` names the one that failed.
  all = lib.genAttrs suiteNames suite;

  # One path to build, so a single `nix build .#checks.x86_64-linux.tests` runs every
  # suite in parallel and gives one answer.
  aggregate = symlinkJoin {
    name = "kagi-api-scm-tests";
    paths = lib.attrValues all;
  };
}
