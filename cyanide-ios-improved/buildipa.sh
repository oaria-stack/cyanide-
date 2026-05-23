#!/usr/bin/env bash
# Build Cyanide into an unsigned IPA for sideloading.
#
# Usage:
#   ./buildipa.sh
#   CONFIG=Release ./buildipa.sh
#
# Output:
#   build/Cyanide-<version>.ipa
#   build/Cyanide.ipa

set -euo pipefail

cd "$(dirname "$0")"

SCHEME="${SCHEME:-Cyanide}"
CONFIG="${CONFIG:-Debug}"
SDK="${SDK:-iphoneos}"

echo "==> building IPA with SCHEME=$SCHEME CONFIG=$CONFIG SDK=$SDK"
SCHEME="$SCHEME" CONFIG="$CONFIG" SDK="$SDK" bash ./scripts/build.sh

echo "==> IPA output"
ls -lh build/*.ipa
