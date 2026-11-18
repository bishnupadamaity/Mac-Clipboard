#!/bin/bash
# Builds ClipStack.app (run on a Mac with Xcode or Command Line Tools installed).
#
# Environment overrides:
#   CLIPSTACK_BUNDLE_ID  reverse-DNS bundle identifier
#   CLIPSTACK_VERSION    marketing version (CFBundleShortVersionString)
#   CLIPSTACK_BUILD      build number (CFBundleVersion), must increase
#   CLIPSTACK_SIGN_ID    signing identity; defaults to Developer ID when present
#   CLIPSTACK_NOTARIZE   set to 1 to notarise and staple after signing
#   CLIPSTACK_KEYCHAIN_PROFILE  notarytool profile name (default: clipstack)
set -euo pipefail
cd "$(dirname "$0")"

# ---- Identity and version ---------------------------------------------------
# The bundle identifier keys the Accessibility grant, the login-item registration
# and the Application Support path. Changing it after release resets every user's
# permission and orphans their history, so settle it before distributing.
BUNDLE_ID="${CLIPSTACK_BUNDLE_ID:-com.inneitec.ClipStack}"

# Marketing version plus a monotonic build number. Notarisation and any updater
# use the build number to order releases; a UTC timestamp always increases.
VERSION="${CLIPSTACK_VERSION:-1.0}"
BUILD="${CLIPSTACK_BUILD:-$(date -u +%Y%m%d%H%M)}"

APP="ClipStack.app"

# ---- Build ------------------------------------------------------------------
# Universal, so the app runs on Intel Macs as well as Apple Silicon. Package.swift
# pins the deployment target, so both slices carry minos 13.0.
ARCH_FLAGS=(--arch arm64 --arch x86_64)
swift build -c release "${ARCH_FLAGS[@]}"
BIN_DIR="$(swift build -c release "${ARCH_FLAGS[@]}" --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN_DIR/ClipStack" "$APP/Contents/MacOS/"

cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>ClipStack</string>
  <key>CFBundleDisplayName</key><string>ClipStack</string>
  <key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
  <key>CFBundleExecutable</key><string>ClipStack</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>${BUILD}</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
  <key>LSUIElement</key><true/>
  <key>NSHumanReadableCopyright</key><string>Copyright © 2026. All rights reserved.</string>
</dict>
</plist>
EOF

# ---- Signing ----------------------------------------------------------------
# macOS ties Accessibility approval to the signature's "designated requirement".
# An ad-hoc signature's requirement is the binary's own hash, so every rebuild
# looks like a brand-new app: the System Settings toggle stays on but grants
# nothing, and auto-paste silently stops working. Signing with a real certificate
# makes the requirement name the bundle id and the certificate instead, so it
# survives rebuilds.
#
# Prefer Developer ID (the only identity other Macs will accept); fall back to a
# development certificate, which is fine locally but will not run elsewhere.
IDENTITIES="$(security find-identity -v -p codesigning 2>/dev/null || true)"
pick_identity() {
  printf '%s' "$IDENTITIES" | sed -n "s/.*\"\($1[^\"]*\)\".*/\1/p" | head -1
}
# Developer ID is the only identity other Macs accept. Falling back to whatever
# development certificate this machine has keeps the Accessibility grant stable
# for local builds; ad-hoc is the last resort.
# Order: explicit env, then a machine-local pin, then Developer ID, then any
# development certificate. The local pin matters when a Mac holds several
# certificates: picking a different one changes the designated requirement and
# silently drops the Accessibility grant, so the choice must not be incidental.
SIGN_ID="${CLIPSTACK_SIGN_ID:-}"
[ -n "$SIGN_ID" ] || { [ -f .signing-identity.local ] && SIGN_ID="$(head -1 .signing-identity.local)"; }
[ -n "$SIGN_ID" ] || SIGN_ID="$(pick_identity 'Developer ID Application: ')"
[ -n "$SIGN_ID" ] || SIGN_ID="$(pick_identity 'Apple Development: ')"
[ -n "$SIGN_ID" ] || SIGN_ID="-"

if [ "$SIGN_ID" != "-" ] && printf '%s' "$IDENTITIES" | grep -qF "$SIGN_ID"; then
  # Hardened runtime is required for notarisation and harmless for local builds.
  SIGN_ARGS=(--force --options runtime --sign "$SIGN_ID")
  case "$SIGN_ID" in
    "Developer ID Application:"*) SIGN_ARGS+=(--timestamp) ;;  # required for notarisation
  esac
  codesign "${SIGN_ARGS[@]}" "$APP"

  echo "Built $APP"
  echo "  bundle id : $BUNDLE_ID"
  echo "  version   : $VERSION ($BUILD)"
  echo "  arch      : $(lipo -archs "$APP/Contents/MacOS/ClipStack")"
  echo "  signed as : $SIGN_ID"
  echo "Accessibility permission carries over between builds."

  case "$SIGN_ID" in
    "Developer ID Application:"*) ;;
    *)
      cat >&2 <<'NOTE'

NOTE: signed with a development certificate. This build runs on this Mac only —
Gatekeeper rejects it elsewhere. Distribution needs a "Developer ID Application"
certificate (Apple Developer Program > Certificates), after which this script
signs and notarises automatically.
NOTE
      ;;
  esac
else
  codesign --force --sign - "$APP"
  cat >&2 <<NOTE
Built $APP (ad-hoc signed — no code-signing certificate found on this Mac)

WARNING: ad-hoc signing gives the app a new signature hash on every build, so macOS
will silently drop its Accessibility approval and auto-paste will stop working. The
entry under System Settings > Privacy & Security > Accessibility still looks enabled
but no longer applies. After each rebuild, reset and re-approve:

    tccutil reset Accessibility $BUNDLE_ID

Set CLIPSTACK_SIGN_ID to a valid identity from \`security find-identity -v -p codesigning\`
to avoid this.
NOTE
fi

# ---- Notarisation -----------------------------------------------------------
# Opt-in, because it needs credentials and a network round trip. Store them once:
#   xcrun notarytool store-credentials clipstack \
#     --apple-id <id> --team-id <team> --password <app-specific-password>
if [ "${CLIPSTACK_NOTARIZE:-0}" = "1" ]; then
  PROFILE="${CLIPSTACK_KEYCHAIN_PROFILE:-clipstack}"
  case "$SIGN_ID" in
    "Developer ID Application:"*) ;;
    *) echo "Refusing to notarise: $SIGN_ID is not a Developer ID certificate." >&2; exit 1 ;;
  esac
  ZIP="$(mktemp -d)/ClipStack.zip"
  ditto -c -k --keepParent "$APP" "$ZIP"
  xcrun notarytool submit "$ZIP" --keychain-profile "$PROFILE" --wait
  xcrun stapler staple "$APP"
  spctl -a -vvv "$APP"
  echo "Notarised and stapled."
fi
