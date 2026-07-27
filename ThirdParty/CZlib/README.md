# CZlib (vendored)

zlib 1.3.2 (https://zlib.net, zlib licence), deflate side only — enough to gzip
HTTP responses in PlumeServer. Vendored like CSQLite so the native server needs
no system zlib headers anywhere. Inflate/gz* file helpers are deliberately not
included; update by copying the same file set from a newer zlib release.
