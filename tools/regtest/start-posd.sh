#!/bin/sh
# posd, with the token of its own barkd (posd-barkd), which barkd writes on
# first start.
set -eu
export RUST_LOG=info
until [ -s /data/posd-barkd/.bark/auth_token ]; do sleep 1; done
POSD__BARKD__TOKEN="$(cat /data/posd-barkd/.bark/auth_token)"
export POSD__BARKD__TOKEN
exec posd --config /root/posd/posd.toml start
