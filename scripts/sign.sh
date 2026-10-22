#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

APP="build/Peeko.app"
IDENTITY="${SIGN_IDENTITY:--}"

# Inside out: Sparkle's helpers first, then the app.
codesign --force --deep --sign "$IDENTITY" "$APP/Contents/Frameworks/Sparkle.framework"

if [[ "$IDENTITY" == "-" ]]; then
    # An ad-hoc signature's default requirement is this exact build's hash, so every update
    # would look like a different app: Sparkle refuses to install it, and Keychain and
    # Accessibility forget Peeko. Pin the requirement to the bundle ID instead; Sparkle's
    # EdDSA signature is what proves an update came from us.
    codesign --force --sign - -r='designated => identifier "com.a7med7x7.peeko"' "$APP"
else
    codesign --force --sign "$IDENTITY" "$APP"
fi

codesign --verify --deep --strict "$APP"
echo "Signed $APP (identity: $IDENTITY)"
