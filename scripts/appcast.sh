#!/usr/bin/env bash
# Writes build/appcast.xml for Sparkle: one item for the DMG of this version, signed with
# SPARKLE_PRIVATE_KEY. The release uploads it next to the DMG, and the app reads it from
# releases/latest/download/appcast.xml, so only the newest release's feed is ever served.
# Usage: scripts/appcast.sh [release-notes.md]
set -euo pipefail
cd "$(dirname "$0")/.."

PLIST="build/Peeko.app/Contents/Info.plist"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST")"
BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$PLIST")"
MIN_OS="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$PLIST")"
DMG="build/Peeko-$VERSION.dmg"
REPO="${GITHUB_REPOSITORY:-STACK-42/peeko}"
# DMG_URL overrides the download link, for testing against a local server.
URL="${DMG_URL:-https://github.com/$REPO/releases/download/v$VERSION/Peeko-$VERSION.dmg}"
NOTES="${1:-}"

SIGNATURE="$(swift scripts/sign-update.swift "$DMG")"
LENGTH="$(stat -f %z "$DMG")"
DATE="$(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S +0000')"

# The changelog section as plain HTML: ### headings, "- " bullets, and paragraphs.
notes_html() {
    [[ -n "$NOTES" && -s "$NOTES" ]] || return 0
    sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' "$NOTES" | awk '
        /^### / { if (list) { print "</ul>"; list = 0 } sub(/^### /, ""); print "<h3>" $0 "</h3>"; next }
        /^- /   { if (!list) { print "<ul>"; list = 1 } sub(/^- /, ""); print "<li>" $0 "</li>"; next }
        /^  - / { sub(/^  - /, ""); print "<li>" $0 "</li>"; next }
        /^$/    { next }
                { if (list) { print "</ul>"; list = 0 } print "<p>" $0 "</p>" }
        END     { if (list) print "</ul>" }
    '
}

cat > build/appcast.xml <<EOF
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Peeko</title>
    <link>https://github.com/$REPO</link>
    <item>
      <title>Peeko $VERSION</title>
      <pubDate>$DATE</pubDate>
      <sparkle:version>$BUILD</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>$MIN_OS</sparkle:minimumSystemVersion>
      <sparkle:fullReleaseNotesLink>https://github.com/$REPO/releases/tag/v$VERSION</sparkle:fullReleaseNotesLink>
      <description><![CDATA[
$(notes_html)
      ]]></description>
      <enclosure url="$URL" length="$LENGTH" type="application/octet-stream" sparkle:edSignature="$SIGNATURE"/>
    </item>
  </channel>
</rss>
EOF
echo "Wrote build/appcast.xml for $VERSION (build $BUILD)"
