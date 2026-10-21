#!/bin/sh
# Creates a local certificate authority (once) and a localhost certificate signed
# by it. Run through `make certs`, inside a throwaway container with openssl:
#   /ca    -> ~/.local/share/mindzer-dev-ca (CA key stays outside the repo)
#   /certs -> dev/certs
set -eu

if [ ! -f /ca/rootCA.pem ]; then
  openssl req -x509 -new -nodes -newkey rsa:3072 -sha256 -days 3650 \
    -keyout /ca/rootCA-key.pem -out /ca/rootCA.pem \
    -subj "/O=Mindzer Systems local dev/CN=Mindzer Systems local dev CA" \
    -addext "basicConstraints=critical,CA:TRUE" \
    -addext "keyUsage=critical,keyCertSign,cRLSign"
  chmod 600 /ca/rootCA-key.pem
fi

cat > /tmp/leaf.ext <<'EOF'
basicConstraints = CA:FALSE
keyUsage = critical, digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth
subjectAltName = DNS:localhost, IP:127.0.0.1, IP:::1
EOF

openssl req -new -nodes -newkey rsa:2048 \
  -keyout /certs/localhost-key.pem -out /tmp/localhost.csr -subj "/CN=localhost"
# Browsers reject leaf certificates valid for more than ~13 months.
openssl x509 -req -in /tmp/localhost.csr -sha256 -days 397 \
  -CA /ca/rootCA.pem -CAkey /ca/rootCA-key.pem -CAcreateserial \
  -extfile /tmp/leaf.ext -out /certs/localhost.pem

chown -R "${OWNER:-0:0}" /ca /certs
