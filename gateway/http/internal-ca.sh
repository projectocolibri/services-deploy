#!/bin/sh
# ============================================================================
# Internal certificate authority
#
# Purpose:       Issues TLS certificates for internal domains (e.g.
#                *.colibri.dev.deltafil.lan), which no public CA can sign.
# Role:          Creates a private CA once (certs/internal-ca/ca.crt and
#                ca.key) and signs a certificate with it in
#                certs/<name>/fullchain.pem and privkey.pem, the layout the
#                HTTP gateway expects. Run again with the same name to renew or
#                to add host names; the CA is reused, so clients keep trusting
#                it. Then reload nginx:
#                  docker compose exec http nginx -s reload
# Prerequisites: - openssl
#                - Every client that opens the sites trusts
#                  certs/internal-ca/ca.crt (import it as a trusted root CA:
#                  Windows certmgr "Trusted Root Certification Authorities",
#                  macOS Keychain "Always Trust", Linux
#                  /usr/local/share/ca-certificates + update-ca-certificates).
#                  Never share ca.key: whoever has it can sign any site.
# Usage:         ./internal-ca.sh <name> <host> [<host> ...]
#                  ./internal-ca.sh dev.deltafil.lan \
#                    '*.colibri.dev.deltafil.lan' \
#                    '*.avencas.dev.deltafil.lan' \
#                    '*.pos.dev.deltafil.lan'
#                A wildcard covers one level only: *.colibri.dev.deltafil.lan
#                matches api.colibri.dev.deltafil.lan, not
#                a.b.colibri.dev.deltafil.lan.
# Variables:     None.
# ============================================================================
set -eu

if [ "$#" -lt 2 ]; then
    sed -n '/^# Usage:/,/^# Variables:/p' "$0" | sed '$d'
    exit 1
fi

name=$1
shift

dir=$(cd "$(dirname "$0")" && pwd)/certs
ca_dir=$dir/internal-ca
out_dir=$dir/$name

# ----------------------------------------------------------------------------
# Certificate authority (created once, valid 10 years)
# ----------------------------------------------------------------------------
mkdir -p "$ca_dir"
if [ ! -f "$ca_dir/ca.key" ]; then
    openssl req -x509 -new -nodes -newkey rsa:4096 -sha256 -days 3650 \
        -subj "/CN=Internal CA ($name)" \
        -addext "basicConstraints=critical,CA:TRUE" \
        -addext "keyUsage=critical,keyCertSign,cRLSign" \
        -keyout "$ca_dir/ca.key" -out "$ca_dir/ca.crt"
    chmod 600 "$ca_dir/ca.key"
    echo "Created CA: $ca_dir/ca.crt (install it on every client as a trusted root)"
fi

# ----------------------------------------------------------------------------
# Server certificate (825 days: the longest Apple devices accept)
# ----------------------------------------------------------------------------
san=""
for host in "$@"; do
    san="${san:+$san,}DNS:$host"
done

mkdir -p "$out_dir"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

openssl req -new -nodes -newkey rsa:2048 -sha256 \
    -subj "/CN=$1" \
    -keyout "$out_dir/privkey.pem" -out "$tmp/req.csr"
chmod 600 "$out_dir/privkey.pem"

cat > "$tmp/ext.cnf" <<EOF
basicConstraints=CA:FALSE
keyUsage=critical,digitalSignature,keyEncipherment
extendedKeyUsage=serverAuth
subjectAltName=$san
EOF

openssl x509 -req -in "$tmp/req.csr" -sha256 -days 825 \
    -CA "$ca_dir/ca.crt" -CAkey "$ca_dir/ca.key" -CAcreateserial \
    -extfile "$tmp/ext.cnf" -out "$tmp/cert.pem"

# nginx expects the server certificate followed by the CA.
cat "$tmp/cert.pem" "$ca_dir/ca.crt" > "$out_dir/fullchain.pem"

echo "Issued $out_dir/fullchain.pem for: $*"
