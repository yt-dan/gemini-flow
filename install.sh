#!/bin/bash
# GeminiFlow installer for macOS.
#
#   ./install.sh                     build, install to ~/Applications, and launch
#   ./install.sh --start-at-login    same, and also start GeminiFlow automatically when you log in
#   ./install.sh --no-launch         build and install only (don't restart the app)
#
# Optional: GEMINI_API_KEY=... ./install.sh   saves your Gemini API key for the app (otherwise set it from the menu bar icon).
#
# Safe to run again at any time (it is also what update.sh uses). It never sends anything anywhere and never prints your key.
set -euo pipefail

cd "$(dirname "$0")"
REPO_DIR="$(pwd)"
APP="${HOME}/Applications/GeminiFlow.app"
BUNDLE_ID="com.google.internal.geminiflow"
SIGN_NAME="GeminiFlow Local Signing"
START_AT_LOGIN=0
LAUNCH=1
for arg in "$@"; do
  case "$arg" in
    --start-at-login) START_AT_LOGIN=1 ;;
    --no-launch) LAUNCH=0 ;;
    -h|--help) sed -n '2,11p' "$0"; exit 0 ;;
    *) echo "Unknown option: $arg (try --help)"; exit 2 ;;
  esac
done

step() { printf '\n==> %s\n' "$1"; }

step "1/6 Checking your Mac"
if [ "$(uname -s)" != "Darwin" ]; then echo "GeminiFlow only runs on macOS."; exit 1; fi
MACOS_MAJOR="$(sw_vers -productVersion | cut -d. -f1)"
if [ "${MACOS_MAJOR}" -lt 11 ]; then echo "GeminiFlow needs macOS 11 or newer (you have $(sw_vers -productVersion))."; exit 1; fi
if ! xcode-select -p >/dev/null 2>&1 || [ ! -x /usr/bin/clang ]; then
  echo "Apple's free Command Line Tools are needed to build the app."
  echo "A macOS window will open: click Install, wait until it finishes (5-15 min), then run ./install.sh again."
  xcode-select --install || true
  exit 1
fi
echo "OK: macOS $(sw_vers -productVersion), command line tools at $(xcode-select -p)"

step "2/6 Making sure a local signing certificate exists"
# A stable (self-signed, local-only) certificate keeps macOS permissions (Microphone, Accessibility) across updates.
# Without it every rebuild would look like a new app and macOS would ask for permissions again.
if [ "${GF_SKIP_CERT:-0}" = 1 ]; then
  echo "Skipped (GF_SKIP_CERT=1, for automated tests only): the build will be ad-hoc signed"
elif /usr/bin/security find-certificate -c "${SIGN_NAME}" >/dev/null 2>&1; then
  echo "OK: '${SIGN_NAME}' already in your login keychain"
else
  echo "Creating '${SIGN_NAME}' (stays on this Mac; used only to sign your own build)..."
  TMP="$(mktemp -d)"
  trap 'rm -rf "${TMP}"' EXIT
  cat > "${TMP}/cert.cnf" <<'CNF'
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = GeminiFlow Local Signing
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
CNF
  /usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -config "${TMP}/cert.cnf" \
      -keyout "${TMP}/key.pem" -out "${TMP}/cert.pem" >/dev/null 2>&1
  P12_PASS="gf-$(date +%s)"
  /usr/bin/openssl pkcs12 -export -inkey "${TMP}/key.pem" -in "${TMP}/cert.pem" -name "${SIGN_NAME}" \
      -out "${TMP}/id.p12" -passout "pass:${P12_PASS}" >/dev/null 2>&1 \
    || /usr/bin/openssl pkcs12 -export -legacy -inkey "${TMP}/key.pem" -in "${TMP}/cert.pem" -name "${SIGN_NAME}" \
      -out "${TMP}/id.p12" -passout "pass:${P12_PASS}" >/dev/null 2>&1
  /usr/bin/security import "${TMP}/id.p12" -k "${HOME}/Library/Keychains/login.keychain-db" -P "${P12_PASS}" \
      -T /usr/bin/codesign >/dev/null
  echo "OK: certificate created"
  echo "NOTE: the first build may show a macOS keychain dialog asking to let 'codesign' use this key."
  echo "      Enter your Mac login password and click 'Always Allow'."
fi

step "3/6 Building GeminiFlow"
./build.sh

step "4/6 Running the built-in self-test"
if "${APP}/Contents/MacOS/GeminiFlow" --test >/tmp/geminiflow-selftest.txt 2>&1; then
  echo "OK: $(grep -Eo '[0-9]+ passed, [0-9]+ failed' /tmp/geminiflow-selftest.txt | tail -1)"
else
  echo "The self-test reported a problem. Details: /tmp/geminiflow-selftest.txt"
  tail -5 /tmp/geminiflow-selftest.txt || true
  exit 1
fi

step "5/6 Settings"
mkdir -p "${HOME}/Library/Application Support/GeminiFlow"
if [ ! -f "${HOME}/Library/Application Support/GeminiFlow/rules.json" ]; then
  cp "${REPO_DIR}/rules.json" "${HOME}/Library/Application Support/GeminiFlow/rules.json"
  echo "OK: default text-cleanup rules copied to ~/Library/Application Support/GeminiFlow/rules.json"
else
  echo "OK: keeping your existing rules.json"
fi
if [ -n "${GEMINI_API_KEY:-}" ]; then
  if /usr/bin/defaults read "${BUNDLE_ID}" GeminiFlow_ApiKey >/dev/null 2>&1; then
    echo "Replacing the Gemini API key that was already saved."
  fi
  /usr/bin/defaults write "${BUNDLE_ID}" GeminiFlow_ApiKey -string "${GEMINI_API_KEY}"
  echo "OK: Gemini API key saved (not shown)"
fi
PLIST="${HOME}/Library/LaunchAgents/${BUNDLE_ID}.plist"
if [ "${START_AT_LOGIN}" = 1 ]; then
  mkdir -p "${HOME}/Library/LaunchAgents"
  cat > "${PLIST}" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>${BUNDLE_ID}</string>
  <key>ProgramArguments</key><array><string>/usr/bin/open</string><string>-a</string><string>${APP}</string></array>
  <key>RunAtLoad</key><true/>
</dict></plist>
PL
  echo "OK: GeminiFlow will start automatically when you log in"
fi

step "6/6 Starting GeminiFlow"
if [ "${LAUNCH}" = 1 ]; then
  /usr/bin/pkill -x GeminiFlow 2>/dev/null || true
  sleep 1
  /usr/bin/open "${APP}"
else
  echo "Skipped (--no-launch). Start it with: open ~/Applications/GeminiFlow.app"
fi

cat <<'DONE'

GeminiFlow is installed and running (look for the microphone icon in the menu bar, top right).

Finish setup (one time):
  1. Allow the Microphone and Speech Recognition prompts when they appear.
  2. System Settings > Privacy & Security > Accessibility: turn ON GeminiFlow (needed to paste for you).
     If asked, also turn it on under Input Monitoring.
  3. Menu bar icon > "Set Gemini API Key" > paste your key > Save   (skip if you used GEMINI_API_KEY=...)
  4. System Settings > Keyboard > "Press fn key to" > "Do Nothing"   (stops the emoji picker popping up)

Use it: hold Fn, speak, release. Double-tap Fn for hands-free; tap Fn again to finish. Esc cancels.
Update later with: ./update.sh
DONE
