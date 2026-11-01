# Default recipe: list available commands
default:
    @just --list

# Format all code (Nix + Markdown + YAML + justfile)
#
# No Scheme formatter: see nix/treefmt.nix. `just lint` and `just whitespace` are the
# Scheme checks.
fmt:
    treefmt --excludes 'tests/fixtures/**'

# Check formatting
fmt-check:
    treefmt --fail-on-change --no-cache --excludes 'tests/fixtures/**'

# Regenerate the module graph the Nix build splits on
#
# One derivation per module needs to know which module imports which, and the sources
# already say so. Run this after adding, removing or renaming an import; `just ci` fails
# if the committed copy is stale.
gen-deps:
    guile -s nix/gen-deps.scm > nix/deps.json

# Fail if nix/deps.json does not match the sources
deps-check:
    #!/usr/bin/env bash
    set -euo pipefail
    out=$(mktemp)
    trap 'rm -f "$out"' EXIT
    guile -s nix/gen-deps.scm > "$out"
    if ! diff -u nix/deps.json "$out"; then
        echo "nix/deps.json is stale: run 'just gen-deps'" >&2
        exit 1
    fi

# Lint every module with the Guile compiler
lint:
    #!/usr/bin/env bash
    set -uo pipefail
    # Output goes to a scratch tree, not /dev/null: guild writes atomically via mkstemp,
    # so a non-regular output path fails before it compiles anything.
    tmp=$(mktemp -d)
    trap 'rm -rf "$tmp"' EXIT
    status=0
    while IFS= read -r f; do
        # guild exits 0 on a warning, so the diagnostics themselves are the signal. An
        # unbound variable is a runtime crash waiting for the branch that calls it.
        #
        # `;;; note: source file ... is newer than compiled ...` is not a diagnostic: it
        # is Guile noticing a stale entry in the auto-compile cache, which any branch
        # switch produces.
        out=$(guild compile -L src -O1 \
            -Wunbound-variable -Wmacro-use-before-definition \
            -Warity-mismatch -Wformat \
            -o "$tmp/$(echo "${f#src/}" | tr / _)o" "$f" 2>&1 >/dev/null \
            | grep -v '^;;;')
        if [ -n "$out" ]; then echo "$out"; status=1; fi
    done < <(find src -name '*.scm')
    exit $status

# Check whitespace hygiene in Scheme sources
#
# Stands in for a Scheme formatter: treefmt-nix has no module for one and the nixpkgs
# candidate mangles Guile's define-module headers.
whitespace:
    #!/usr/bin/env bash
    set -uo pipefail
    status=0
    while IFS= read -r f; do
        if grep -nP '\t' "$f"; then echo "  ^ tab in $f"; status=1; fi
        if grep -nP ' +$' "$f"; then echo "  ^ trailing space in $f"; status=1; fi
        if [ -s "$f" ] && [ -n "$(tail -c1 "$f")" ]; then
            echo "$f: no newline at end of file"; status=1
        fi
    done < <(find src tests -type f -name '*.scm')
    exit $status

# Run the test suite
test:
    #!/usr/bin/env bash
    set -euo pipefail
    cache=$(mktemp -d)
    trap 'rm -rf "$cache"' EXIT
    XDG_CACHE_HOME="$cache" guile -L src -L tests -s tests/run-tests.scm

# Run a single suite, e.g. `just test-one http`
test-one NAME:
    #!/usr/bin/env bash
    set -euo pipefail
    cache=$(mktemp -d)
    trap 'rm -rf "$cache"' EXIT
    XDG_CACHE_HOME="$cache" guile -L src -L tests -s tests/run-tests.scm {{ NAME }}

# Compile every module to bytecode under build/
build:
    #!/usr/bin/env bash
    set -euo pipefail
    while IFS= read -r f; do
        out="build/ccache/${f#src/}"
        mkdir -p "$(dirname "${out%.scm}.go")"
        guild compile -L src -O1 -o "${out%.scm}.go" "$f"
    done < <(find src -name '*.scm')

secretspec_reason := "kagi-api-scm live API test suite"

# Run the live suite against the real API
#
# The live suite is skipped unless KAGI_LIVE=1, so `just test` never spends money. This
# recipe turns it on and resolves KAGI_API_KEY through secretspec.
[doc("Run the live search tests, with credentials from secretspec")]
live-test *args='':
    secretspec run --reason {{ quote(secretspec_reason) }} -- \
        env KAGI_LIVE=1 guile -L src -L tests -s tests/run-tests.scm live {{ args }}

# Report which live-test credentials are missing from the configured provider
secrets-check:
    secretspec check --reason {{ quote(secretspec_reason) }}

# A Guile REPL with the client on the load path
repl:
    guile -L src

# Run CI checks locally
ci: fmt-check whitespace deps-check lint test build
    @echo "All CI checks passed!"

# Clean build artifacts
clean:
    rm -rf build
    find src tests -name '*.go' -delete
