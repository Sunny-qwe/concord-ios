#!/bin/bash
# Ad-hoc sign the unsigned .app with entitlements embedded (FlClash-style).
#
# Why this exists: SideKite/zsign re-signs the IPA, and it preserves the
# entitlements already embedded in each binary's ad-hoc signature. A
# completely unsigned binary carries no entitlements, so the re-signer
# cannot know the PacketTunnel extension needs packet-tunnel-provider
# (and the matching application-identifier) -- installd then rejects the
# extension and the whole install fails. FlClash does exactly this in
# setup.dart (packageIOSNoSign -> _adHocCodesign with
# createIOSNoSignEntitlements); this script mirrors it: a generic deep
# ad-hoc sign first, then a per-bundle ad-hoc sign with the expanded
# entitlements (extension first, then the app).
#
# Usage: bash tools/adhoc-sign.sh <path-to-ConcordiOS.app>
# The entitlements come from the repo's .entitlements files, with
# application-identifier + team-identifier added. The team is the
# FlClash placeholder UNKNOWN000, NOT the real team: FlClash's
# createIOSNoSignEntitlements defaults to UNKNOWN000 when no team is
# given, and the re-signer rewrites team + bundle identifiers
# consistently from the profile it signs with. Our real team
# (65ZBN43KNV) must NOT be baked in: profile JUMJJ8's
# application-identifier is exactly 65ZBN43KNV.app.forest5669.sapodilla72
# (no wildcard), so it does not cover .PacketTunnel, and a real-but-
# mismatched tunnel identifier is what the re-signer preserves.
# EXPERIMENT (v0.2.11): placeholder entitlements, unproven on device.
set -euo pipefail

APP="${1:?usage: adhoc-sign.sh <path-to-ConcordiOS.app>}"
TEAM="UNKNOWN000"
# EXPERIMENT (v0.2.12): bundle IDs deliberately do NOT match the JUMJJ8 profile, FlClash-style — diagnostic test of whether non-matching IDs are what makes the re-signer accept FlClash.
APP_ID="com.concord.ios"
TUNNEL_ID="${APP_ID}.PacketTunnel"

# Expand one target's entitlements: read the repo's .entitlements file,
# add application-identifier + team-identifier (like FlClash's
# createIOSNoSignEntitlements), write the result to a temp plist.
expand_entitlements() {
  local src="$1" bundle_id="$2" out="$3"
  python3 - "$src" "$TEAM" "$bundle_id" "$out" <<'PYEOF'
import plistlib, sys
src, team, bid, out = sys.argv[1:5]
with open(src, 'rb') as f:
    d = plistlib.load(f)
d['application-identifier'] = f'{team}.{bid}'
d['com.apple.developer.team-identifier'] = team
with open(out, 'wb') as f:
    plistlib.dump(d, f)
PYEOF
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
TMPDIR="$(mktemp -d)"
trap "rm -rf $TMPDIR" EXIT

APP_ENT="$TMPDIR/app.entitlements"
TUNNEL_ENT="$TMPDIR/tunnel.entitlements"
expand_entitlements "$REPO_DIR/ConcordiOS/ConcordiOS.entitlements" "$APP_ID" "$APP_ENT"
expand_entitlements "$REPO_DIR/PacketTunnel/PacketTunnel.entitlements" "$TUNNEL_ID" "$TUNNEL_ENT"

# 1. Generic deep ad-hoc sign (no entitlements), like FlClash.
codesign --force --deep --sign - --timestamp=none "$APP"
# 2. Per-bundle ad-hoc sign with entitlements: extension first, then the app.
codesign --force --sign - --timestamp=none --generate-entitlement-der --entitlements "$TUNNEL_ENT" "$APP/PlugIns/PacketTunnel.appex"
codesign --force --sign - --timestamp=none --generate-entitlement-der --entitlements "$APP_ENT" "$APP"

# Verify: print the embedded entitlements for the build log.
echo "--- PacketTunnel embedded entitlements ---"
codesign -d --entitlements - "$APP/PlugIns/PacketTunnel.appex/PacketTunnel"
echo "--- App embedded entitlements ---"
codesign -d --entitlements - "$APP/ConcordiOS"
