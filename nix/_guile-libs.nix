# The Guile libraries this client links against, shared by the devshell, the lint hook
# and the package. Kept separate so adding one is a one-line change in one place.
#
# guile-json decodes and encodes the request and response bodies. guile-gnutls is what
# (web client) uses for HTTPS, so a package without it can only reach plain HTTP.
pkgs: with pkgs; [
  guile-json
  guile-gnutls
]
