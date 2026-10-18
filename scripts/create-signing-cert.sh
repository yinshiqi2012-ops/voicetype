#!/bin/bash
# 创建用于本地代码签名的自签名证书，并导入登录钥匙串。
#
#   ./scripts/create-signing-cert.sh
#
# 背景：ad-hoc 签名的 designated requirement 是 cdhash，每次重建都会变，
# 导致「麦克风 / 输入监控 / 辅助功能」授权被清空、需要重新授权。改用自签名证书后，
# DR 变为基于证书，重建不再丢失授权。
#
# 幂等：已存在同名有效身份则直接退出。
set -euo pipefail

CERT_NAME="Voicetype Dev"
DAYS="${DAYS:-3650}"

KEYCHAIN="$(security default-keychain -d user | tr -d '"' | xargs)"

if security find-identity -v -p codesigning | grep -qF "\"${CERT_NAME}\""; then
  echo "已存在可用签名身份：${CERT_NAME}，无需重复创建"
  exit 0
fi

WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

cat <<EOF > "$WORKDIR/openssl.cnf"
[req]
distinguished_name = dn
x509_extensions = v3_req
prompt = no
[dn]
CN = ${CERT_NAME}
[v3_req]
basicConstraints = critical,CA:true
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
subjectKeyIdentifier = hash
EOF

echo "==> 生成自签名证书（有效期 ${DAYS} 天）"
openssl req -x509 -newkey rsa:2048 -sha256 -nodes -days "$DAYS" \
  -config "$WORKDIR/openssl.cnf" \
  -keyout "$WORKDIR/key.pem" -out "$WORKDIR/cert.pem" 2>/dev/null

# 转成传统 PKCS#1 私钥（`security import` 对 PKCS#8 支持不稳定）。
openssl rsa -in "$WORKDIR/key.pem" -out "$WORKDIR/key-rsa.pem" 2>/dev/null

echo "==> 导入私钥与证书到登录钥匙串（仅允许本机签名使用）"
security import "$WORKDIR/key-rsa.pem" -k "$KEYCHAIN" -T /usr/bin/codesign -A
security import "$WORKDIR/cert.pem" -k "$KEYCHAIN" -T /usr/bin/codesign -A

echo "==> 添加代码签名信任设置"
if ! security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" "$WORKDIR/cert.pem"; then
  echo "!! 写入信任设置失败。请在「钥匙串访问」中找到证书 ${CERT_NAME}，"
  echo "   双击 → 信任 → 「使用此证书时」选择「始终信任」。"
  exit 1
fi

echo "==> 校验签名身份"
security find-identity -v -p codesigning | grep -F "${CERT_NAME}"

cat <<TXT

证书已就绪。后续用 ./scripts/build-app.sh 构建即会自动使用该身份。
若需删除：在「钥匙串访问」中删除证书 ${CERT_NAME}（私钥一并删除）。
TXT
