#!/bin/sh
set -eu
export PATH="/usr/lib/postgresql/16/bin:$PATH"
export RUST_LOG=info
PGDATA=/var/lib/postgresql/data
mkdir -p "$PGDATA" /run/postgresql
chmod 0700 "$PGDATA"
chown postgres:postgres "$PGDATA" /run/postgresql

if [ ! -f "$PGDATA/PG_VERSION" ]; then
    su postgres -s /bin/sh -c "initdb '$PGDATA'" >/dev/null
fi

server_pid=
cleanup() {
    if [ -n "$server_pid" ]; then
        kill -TERM "$server_pid" 2>/dev/null || :
        wait "$server_pid" 2>/dev/null || :
    fi
    su postgres -s /bin/sh -c "pg_ctl stop -m fast -D '$PGDATA'" >/dev/null 2>&1 || :
}
trap cleanup EXIT
trap 'exit 143' TERM
trap 'exit 130' INT

su postgres -s /bin/sh -c "pg_ctl start -w -D '$PGDATA' -l /var/lib/postgresql/startup.log -o '-c listen_addresses=127.0.0.1'" >/dev/null
if [ ! -f /data/captaind/mnemonic ]; then
    # Public credentials for this isolated regtest database.
    su postgres -s /bin/sh -c "psql -c \"ALTER USER postgres WITH PASSWORD 'postgres';\"" >/dev/null
    captaind --config /root/captaind/captaind.toml create
fi
captaind --config /root/captaind/captaind.toml start &
server_pid=$!
wait "$server_pid"
