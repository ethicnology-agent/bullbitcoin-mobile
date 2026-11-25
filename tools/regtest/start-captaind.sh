#!/bin/sh
# scuttle's captaind, with its database in the ark-postgres service.
set -eu
export RUST_LOG=info
config=/root/captaind/captaind.toml
# Postgres may still be starting: create retries until it answers.
until [ -f /data/captaind/mnemonic ]; do
    captaind --config "$config" create || sleep 2
done
exec captaind --config "$config" start
