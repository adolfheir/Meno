#!/bin/bash
set -euo pipefail
umask 077

config_dir=/etc/meno-sync
ip=$(cat "$config_dir/address")
if [[ -s "$config_dir/server.crt" && -s "$config_dir/server.key" ]] &&
   openssl x509 -checkend $((45 * 86400)) -noout -in "$config_dir/server.crt" >/dev/null; then
    exit 0
fi

work=$(mktemp -d "$config_dir/.tls.XXXXXX")
trap 'rm -rf "$work"' EXIT
openssl req -new -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes \
    -keyout "$work/server.key" -out "$work/server.csr" -subj "/CN=$ip"
cat > "$work/extensions" <<EOF
basicConstraints=critical,CA:FALSE
keyUsage=critical,digitalSignature
extendedKeyUsage=serverAuth
subjectAltName=IP:$ip
EOF
openssl x509 -req -sha256 -days 365 -in "$work/server.csr" \
    -CA "$config_dir/root.crt" -CAkey "$config_dir/root.key" \
    -CAserial "$config_dir/root.srl" -CAcreateserial \
    -extfile "$work/extensions" -out "$work/server.crt"
openssl verify -CAfile "$config_dir/root.crt" -verify_ip "$ip" "$work/server.crt"
install -m 0600 "$work/server.key" "$config_dir/server.key"
install -m 0644 "$work/server.crt" "$config_dir/server.crt"
systemctl try-restart meno-sync.service
