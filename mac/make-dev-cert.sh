#!/usr/bin/env bash
# Membuat identitas code signing self-signed "cursoe-dev" di login keychain (sekali saja).
#
# Kenapa: dengan tanda tangan ad-hoc, macOS mengikat izin Accessibility ke hash binary,
# jadi izin hilang setiap kali aplikasi di-rebuild. Dengan sertifikat tetap, izin menempel
# ke identitas sertifikat + bundle id dan bertahan walau di-rebuild.
#
# Skrip ini akan memunculkan dialog password macOS (untuk mempercayai sertifikat
# khusus code signing). Kunci privat hanya ada di login keychain Anda.
set -euo pipefail

NAME="cursoe-dev"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
OPENSSL=/usr/bin/openssl   # LibreSSL bawaan macOS: format .p12-nya bisa dibaca `security import`

if security find-identity -v -p codesigning | grep -q "\"$NAME\""; then
    echo "Identitas \"$NAME\" sudah ada. Tidak ada yang perlu dilakukan."
    exit 0
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

cat > "$WORK/cert.conf" <<EOF
[ req ]
distinguished_name = dn
x509_extensions = ext
prompt = no
[ dn ]
CN = $NAME
[ ext ]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
EOF

echo "==> Membuat kunci & sertifikat"
"$OPENSSL" req -x509 -newkey rsa:2048 -nodes -days 3650 \
    -keyout "$WORK/key.pem" -out "$WORK/cert.pem" -config "$WORK/cert.conf" 2>/dev/null
"$OPENSSL" pkcs12 -export -inkey "$WORK/key.pem" -in "$WORK/cert.pem" \
    -name "$NAME" -out "$WORK/id.p12" -passout pass:cursoe

echo "==> Mengimpor ke login keychain"
security import "$WORK/id.p12" -k "$KEYCHAIN" -P cursoe -T /usr/bin/codesign

echo "==> Mempercayai sertifikat untuk code signing (akan muncul dialog password)"
security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" "$WORK/cert.pem"

echo
security find-identity -v -p codesigning | grep "$NAME"
echo "Selesai. build-app.sh sekarang otomatis menandatangani dengan \"$NAME\"."
echo "Pertama kali codesign memakai kunci ini, pilih \"Always Allow\" bila macOS bertanya."
