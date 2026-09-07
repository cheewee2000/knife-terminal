#!/bin/bash
# Cut a notarized macOS release and publish the Sparkle appcast.
#   ./release.sh "release notes html"
# Bump MARKETING_VERSION + CURRENT_PROJECT_VERSION in apple/project.yml first.
set -euo pipefail
cd "$(dirname "$0")"

V=$(sed -n 's/.*MARKETING_VERSION: *"\(.*\)".*/\1/p' apple/project.yml)
NOTES=${1:-$(git log -1 --pretty=%s)}
REPO=cheewee2000/knife-terminal
ZIP="$PWD/dist/Knife-Terminal-$V.zip"
[ -n "$V" ] || { echo "no MARKETING_VERSION in apple/project.yml"; exit 1; }
git diff --quiet || { echo "working tree dirty — commit the version bump first"; exit 1; }
gh release view "v$V" >/dev/null 2>&1 && { echo "v$V already released"; exit 1; }

echo "── building $V"
mkdir -p dist
cd apple
xcodegen generate
D=DerivedData
rm -rf "$D/KnifeMac.xcarchive" "$D/export"
xcodebuild archive -project KnifeTerminal.xcodeproj -scheme KnifeMac -configuration Release \
  -archivePath "$D/KnifeMac.xcarchive" -derivedDataPath "$D" \
  -allowProvisioningUpdates -skipPackagePluginValidation
xcodebuild -exportArchive -archivePath "$D/KnifeMac.xcarchive" \
  -exportOptionsPlist ~/.knife-release-signing/ExportOptions.plist \
  -exportPath "$D/export" -allowProvisioningUpdates
APP="$D/export/Knife Terminal.app"

echo "── notarizing"
ditto -c -k --keepParent "$APP" "$ZIP"
xcrun notarytool submit "$ZIP" --keychain-profile notary --wait
xcrun stapler staple "$APP"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"   # re-zip so the ticket ships with it

echo "── signing appcast"
SIG=$("$D/SourcePackages/artifacts/sparkle/Sparkle/bin/sign_update" "$ZIP")  # prints sparkle:edSignature="…" length="…"
cd ..
cat > appcast.xml <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Knife Terminal</title>
    <link>https://github.com/$REPO</link>
    <description>Updates for Knife Terminal</description>
    <language>en</language>
    <item>
      <title>Knife Terminal $V</title>
      <link>https://github.com/$REPO/releases/tag/v$V</link>
      <sparkle:version>$V</sparkle:version>
      <sparkle:shortVersionString>$V</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
      <description><![CDATA[<p>$NOTES</p>]]></description>
      <enclosure
        url="https://github.com/$REPO/releases/download/v$V/Knife-Terminal-$V.zip"
        type="application/octet-stream"
        $SIG/>
    </item>
  </channel>
</rss>
XML

echo "── publishing"
gh release create "v$V" "$ZIP" --title "Knife Terminal $V" --notes "$NOTES"
git add appcast.xml && git commit -m "appcast: v$V" && git push
echo "done — v$V live, appcast updated"
