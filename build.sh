#!/bin/bash
# Builds "Lord of the Claudes.app" into ./build.
# ./build.sh           build only
# ./build.sh install   build, copy to /Applications and (re)start it
set -euo pipefail
cd "$(dirname "$0")"

APP="build/Lord of the Claudes.app"

swift build -c release
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/LordOfTheClaudes "$APP/Contents/MacOS/"
cp Info.plist "$APP/Contents/"
codesign --force --sign - "$APP"
echo "Built $APP"

if [ "${1:-}" = "install" ]; then
    pkill -x LordOfTheClaudes || true
    rm -rf "/Applications/Lord of the Claudes.app"
    cp -R "$APP" /Applications/
    open "/Applications/Lord of the Claudes.app"
    echo "Installed and started /Applications/Lord of the Claudes.app"
fi
