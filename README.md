# kagi-api-scm

A Guile Scheme client for the [Kagi v1 Search API](https://kagi.com/api/docs), ported from
the Rust [`kagi-api`](../kagi-api-rs/crates/kagi-api) crate and built for use in
[Intron](../../intron/intron/). It is a separate repository with its own Nix flake, the same
per-module Scheme build, the same compiler-as-linter gate and the same live-test discipline.

The scope is deliberately narrow: **v1 Search only**. Extract, the v0 FastGPT, Summarizer
and Enrichment products, the CLI and the MCP server are not part of this port.

## What it mirrors

| Rust | Scheme |
| --- | --- |
| `Client` / `ClientBuilder` | `<client>` and `make-client` |
| `SearchRequest` and its builder | `<search-request>` and `make-search-request` |
| `Lens`, `SearchFilters`, `ExtractOptions`, `Personalizations` | records of the same names |
| `PageNumber`, `ResultLimit`, `SearchTimeout` | range checks in the constructors |
| `Region`, `Date`, `FileType` | validators run by the constructors |
| `SearchResponse`, `SearchData`, `SearchResult` | records and `search-data-ref` |
| `SearchOutput` | `<search-output>` with `json` or `markdown` |
| `Error` / `ApiError` | `<kagi-error>` with a `kind` and predicates |
| retries and `requests-made` | the same loop and counter |
| wiremock tests | `tests/fake-kagi.scm` and the HTTP suite |
| `#[ignore]` live tests | `tests/live-test.scm` behind `KAGI_LIVE=1` |

The one deliberate difference is that the Scheme client is synchronous. Guile's
`(web client)` is synchronous, and Intron's own HTTP layer is where fibers belong; a
library that returned a fiber would force that choice on every caller. The retry loop is
the same.

## Use

```scheme
(use-modules (kagi api))

(define client (make-client (getenv "KAGI_API_KEY")))

(define request
  (make-search-request "steve jobs"
                       #:limit 5
                       #:lens (make-lens #:sites-included '("en.wikipedia.org"))))

(define response (client-search-json client request))

(display (search-response-trace response))
(newline)

(for-each
 (lambda (result)
   (format #t "~a — ~a~%" (search-result-title result)
           (search-result-url result)))
 (search-data-results (search-response-data response)))
```

Categories are symbols, in the API's canonical order:

```scheme
(search-data-categories (search-response-data response))
;; => (search infobox related_search)

(vector-length (search-data-ref (search-response-data response) 'news))
;; => 0
```

A member this client has not been taught is kept in `search-data-other`. Its keys are
strings, because that is how guile-json decodes an object; known categories are symbols so
callers can pass them to `search-data-ref`.

Markdown is a separate shape, because the server decides which arrived:

```scheme
(define output
  (client-search client (make-search-request "steve jobs" #:format 'markdown)))

(search-output-markdown? output)   ; => #t
(search-output-trace output)       ; from X-Kagi-Trace
(search-output->json output)       ; raises unexpected-format-error
```

## Options

`make-search-request` accepts the whole documented v1 surface:

- `#:workflow` — `search`, `images`, `videos`, `news`, `podcasts`
- `#:format` — `json`, `markdown`
- `#:limit` — 1 to 1024
- `#:page` — 1 to 10
- `#:timeout` — 0.5 to 4 seconds
- `#:lens-id` — a saved lens identifier, ID or URL
- `#:lens` — `make-lens` with included and excluded sites and keywords, file type, dates,
  relative time and region
- `#:filters` — `make-filters` with region, dates and safe search (on by default)
- `#:extract` — `make-extract-options` with a count from 1 to 10 and a timeout
- `#:personalizations` — `make-personalizations` with domain and regex rules

Every value the API would reject is refused locally, so a billed request is not spent
finding out. The request body is available for inspection with
`search-request->json-string`.

## Errors

```scheme
(catch 'kagi-error
  (lambda () (client-search-json client request))
  (lambda (key err)
    (cond ((unauthorized-error? err)
           ;; Kagi reports a bad v1 token as 400 general.invalid_token, not 401.
           ...)
          ((validation-error? err)
           (api-error-location (kagi-error-body err)))
          ((rate-limited? err) ...)
          ((server-error? err) ...)
          (else (error->string err)))))
```

`parse-api-error` accepts the spec's `error` and the live server's `errors`, the v0 `msg`
and `ref` aliases, and a numeric code. A body that is not an error document keeps its text.

The client retries `429`s and `5xx`s. A `Retry-After` in seconds is honoured; an HTTP-date
falls back to exponential backoff, because the v1 endpoint does not send one.

## Nix

```bash
nix develop          # or: direnv allow
just                 # list the recipes
just test            # the mocked suites; no network, no key, no charge
just ci              # fmt-check, whitespace, deps-check, lint, test, build
nix flake check      # the package and every suite, one check per suite
```

The package installs modules under `share/guile/site/3.0/kagi/` and compiled `.go` files
under `lib/guile/3.0/site-ccache/kagi/`, so `(use-modules (kagi api))` works from a profile
as well as from the checkout.

### Use from Intron

Add the flake input and apply its overlay, then add the package to Intron's Guile library
list:

```nix
# flake.nix
kagi-api-scm.url = "github:sshine/kagi-api-scm";
```

```nix
# nix/pkgs.nix — alongside whatever other overlays Intron applies
_module.args.pkgs = import inputs.nixpkgs {
  inherit system;
  overlays = [
    inputs.kagi-api-scm.overlays.default
  ];
};
```

```nix
# nix/_guile-libs.nix
pkgs: with pkgs; [
  guile-json
  guile-fibers
  guile-gnutls
  guile-lib
  guile-promptui
  kagi-api-scm
]
```

Then `(use-modules (kagi api))` in any Intron module. The package brings its own compiled
bytecode, so no source path needs to be added.

## Testing

The mocked suites run in a normal check:

- `request-test.scm` — the body each option produces, and every local rejection.
- `response-test.scm` — categories, unknown categories, images, props, output shapes.
- `error-test.scm` — both error spellings, predicates, fallback text.
- `http-test.scm` — a real socket server from `tests/fake-kagi.scm`; bearer auth, the
  request body, JSON and markdown, 401, 400, 429 with `Retry-After`, 5xx retry, decode
  failure, transport failure and the request counter.

The live suite is skipped unless `KAGI_LIVE=1` and makes two billed searches:

```bash
secretspec config global init      # once: choose a provider
secretspec set KAGI_API_KEY
just secrets-check
just live-test
```

Set `KAGI_TEST_QUERY` to change the query. `just test` never spends money.

## Caveats

- Search costs money per query. There is no sandbox.
- Markdown output is experimental in the API, so do not parse it for structure you need to
  rely on.
- A JSON result must have a string `url` and `title`; a body without them is a decode error
  rather than a half-filled record.
- The client does not enforce a request timeout. Guile's `(web client)` has no timeout
  argument; a caller that needs one should wrap the call at its own layer. This is the one
  place the port is weaker than the Rust client, and it is called out rather than silently
  ignored.
- `Retry-After` is parsed as seconds only, not as an HTTP-date.

## License

MIT. See [LICENSE](LICENSE).
