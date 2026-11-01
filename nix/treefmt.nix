{ inputs, ... }:
{
  imports = [ inputs.treefmt-nix.flakeModule ];
  perSystem =
    { ... }:
    {
      treefmt = {
        projectRootFile = "flake.nix";

        # Fixtures are parser input, not prose.
        settings.global.excludes = [ "tests/fixtures/**" ];

        programs.nixfmt.enable = true;
        programs.just.enable = true;
        programs.mdformat = {
          enable = true;
          plugins = ps: [ ps.mdformat-frontmatter ];
          settings.number = true;
        };
        programs.yamlfmt = {
          enable = true;
          settings.formatter.retain_line_breaks_single = true;
        };

        # No Scheme formatter.
        #
        # treefmt-nix has no module for one, and the obvious candidate in nixpkgs,
        # schemat, formats generic S-expressions with no knowledge of Guile: it splits
        # every `#:use-module` from the module that follows it onto separate lines, which
        # mangles the header of every file. So Scheme is checked rather than formatted:
        # `just lint` compiles every module with warnings as the real correctness gate,
        # and `just whitespace` covers tabs, trailing space and the final newline.
      };
    };
}
