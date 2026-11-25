#!/bin/sh
# scuttle's watchmand. It derives its keys from captaind's seed and needs a
# sweep address, which stack.py bootstrap writes from the bull-regtest wallet.
set -eu
export RUST_LOG=info
until [ -s /data/captaind/mnemonic ] && [ -s /data/watchmand/sweep_address ]; do sleep 2; done
umask 077
cp /data/captaind/mnemonic /data/watchmand/mnemonic
# A top-level key: it must come before the config's first table.
{ printf 'sweep_address = "%s"\n' "$(cat /data/watchmand/sweep_address)"; cat /root/watchmand/watchmand.toml; } > /tmp/watchmand.toml
exec watchmand --config /tmp/watchmand.toml start
