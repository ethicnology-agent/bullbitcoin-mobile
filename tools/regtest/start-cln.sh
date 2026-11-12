#!/bin/sh
set -eu
mkdir -p /root/.lightning/regtest
# Boltz pins TLS peer names to cln and hold, independent of DNS routing.
# Keep the image certificate generation, adding both authenticated identities.
sed -e '/DNS.2 = localhost/a DNS.3 = cln\nDNS.4 = hold' -e 's/^lightningd /exec lightningd /' /root/cln/start.sh > /tmp/start-cln.sh
certificate=/root/.lightning/regtest/hold/server.pem
if [ -f "$certificate" ] && ! openssl x509 -in "$certificate" -noout -ext subjectAltName | grep -q 'DNS:hold'; then
    rm -f /root/.lightning/regtest/generation.done
fi
exec sh /tmp/start-cln.sh
