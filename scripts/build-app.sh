#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release --product AgentUsage
APP="AgentUsage.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/AgentUsage "$APP/Contents/MacOS/AgentUsage"
cp Support/Info.plist "$APP/Contents/Info.plist"
chmod +x "$APP/Contents/MacOS/AgentUsage"
codesign --force --sign - "$APP"
echo "Built $PWD/$APP"
