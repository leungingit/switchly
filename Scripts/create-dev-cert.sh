#!/usr/bin/env bash
#
# Scripts/create-dev-cert.sh
#
# Create a local, self-signed code-signing certificate (default name
# "SwitchlyDev") so rebuilds keep a stable code identity and macOS stops
# resetting the Accessibility / Screen Recording grants after every build.
#
# The certificate and its private key live ONLY in your login keychain —
# nothing here is committed to the repository.
#
# Usage:
#   Scripts/create-dev-cert.sh [certificate-name]   # default: SwitchlyDev
#
# Afterwards enable Option A in Config/Local.xcconfig (see
# Config/Local.xcconfig.example) and re-grant the permissions once:
#   tccutil reset Accessibility com.switchly.app
#   tccutil reset ScreenCapture com.switchly.app

set -euo pipefail

CERT_NAME="${1:-SwitchlyDev}"

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
say()  { printf "${GREEN}%s${NC}\n" "$*"; }
warn() { printf "${YELLOW}%s${NC}\n" "$*"; }
die()  { printf "${RED}%s${NC}\n" "$*" >&2; exit 1; }

# --- Sanity checks -----------------------------------------------------------
command -v openssl >/dev/null 2>&1 || die "❌ 需要 openssl（macOS 自带，或 brew install openssl）"
command -v security >/dev/null 2>&1 || die "❌ 需要 security 工具（macOS 自带）"

KEYCHAIN="$(security default-keychain | tr -d '"' | awk '{print $NF}')"
[ -n "${KEYCHAIN}" ] || die "❌ 未找到默认钥匙串"
say "🔑 使用钥匙串: ${KEYCHAIN}"

# --- Idempotency -------------------------------------------------------------
if security find-identity -v -p codesigning 2>/dev/null | grep -qF "\"${CERT_NAME}\""; then
  say "✅ 证书已存在且可用于代码签名，无需重复创建："
  security find-identity -v -p codesigning | grep -F "\"${CERT_NAME}\"" || true
  exit 0
fi
if security find-identity -p codesigning 2>/dev/null | grep -qF "\"${CERT_NAME}\""; then
  die "❌ 钥匙串中已存在同名证书 ${CERT_NAME}，但当前不可用于代码签名（未受信任）。请先在「钥匙串访问」中删除它，再重新运行本脚本。"
fi

# --- Generate key + self-signed code-signing certificate ---------------------
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

# keyUsage digitalSignature + extendedKeyUsage codeSigning are what codesign
# requires. Written via a config file (instead of -addext) so this works with
# both LibreSSL (macOS system openssl) and OpenSSL.
cat > "${TMP}/openssl.cnf" <<EOF
[req]
distinguished_name = dn
prompt             = no
x509_extensions    = v3_codesign

[dn]
CN = ${CERT_NAME}

[v3_codesign]
keyUsage               = critical, digitalSignature
extendedKeyUsage       = codeSigning
subjectKeyIdentifier   = hash
authorityKeyIdentifier = keyid:always
basicConstraints       = critical, CA:true
EOF

say "🛠  正在生成自签名代码签名证书「${CERT_NAME}」（有效期 10 年）…"
openssl req -x509 -new -newkey rsa:2048 -nodes \
  -keyout "${TMP}/key.pem" \
  -out "${TMP}/cert.pem" \
  -config "${TMP}/openssl.cnf" \
  -days 3650 >/dev/null 2>&1

# --- Import into the login keychain; allow codesign to use the key -----------
# Import the PEM key and certificate separately: OpenSSL 3 pkcs12 output trips
# macOS `security import` ("MAC verification failed"), plain PEM avoids that.
security import "${TMP}/key.pem"  -k "${KEYCHAIN}" -T /usr/bin/codesign >/dev/null
security import "${TMP}/cert.pem" -k "${KEYCHAIN}" -T /usr/bin/codesign >/dev/null
# Trust the certificate for the code-signing policy (user trust domain; no sudo).
security add-trusted-cert -p codeSign -r trustRoot -k "${KEYCHAIN}" "${TMP}/cert.pem"

# --- Verify ------------------------------------------------------------------
if ! security find-identity -v -p codesigning 2>/dev/null | grep -qF "\"${CERT_NAME}\""; then
  die "❌ 证书已创建但未能通过代码签名信任校验，请检查「钥匙串访问」中的证书信任设置。"
fi
security find-identity -v -p codesigning | grep -F "\"${CERT_NAME}\"" || true

# --- Smoke test: sign a throwaway copy of /bin/echo --------------------------
TESTDIR="$(mktemp -d)"
if cp /bin/echo "$TESTDIR/echo" 2>/dev/null && \
   codesign --force -s "${CERT_NAME}" "$TESTDIR/echo" >/dev/null 2>&1; then
  say "🧪 试签名成功。该证书的指定要求（对 TCC 保持稳定的部分）："
  codesign -dr - "$TESTDIR/echo" 2>&1 | grep -i -E 'designated|authority' | sed 's/^/    /' || true
else
  warn "⚠️ 试签名未成功，但证书已创建；如弹出钥匙串提示，请点击「始终允许」后重试构建。"
fi
rm -rf "$TESTDIR"

cat <<EOF

🎉 完成！接下来：

  1. cp Config/Local.xcconfig.example Config/Local.xcconfig
     并取消注释方案 A（CODE_SIGN_IDENTITY = ${CERT_NAME}）
  2. 最后重置一次系统授权（此后重建不会再丢）：
       tccutil reset Accessibility com.switchly.app
       tccutil reset ScreenCapture com.switchly.app
     然后在「系统设置 → 隐私与安全性」里重新勾选授权。
EOF
