#!/bin/bash
# Builds "Lord of the Claudes.app" into ./build, with the lotc command line tool inside it.
# ./build.sh           build only
# ./build.sh install   build, copy to /Applications, (re)start it and link lotc into Homebrew's bin
# ./build.sh test      run the tests
set -euo pipefail
cd "$(dirname "$0")"

if [ "${1:-}" = "test" ]; then
    # Without Xcode, swift test does not look for the Testing framework where the Command Line Tools keep it.
    CLT=/Library/Developer/CommandLineTools/Library/Developer
    flags=()
    if [ "$(xcode-select -p)" = /Library/Developer/CommandLineTools ] && [ -d "$CLT/Frameworks/Testing.framework" ]; then
        flags=(-Xswiftc -F -Xswiftc "$CLT/Frameworks" -Xlinker -rpath -Xlinker "$CLT/Frameworks"
               -Xlinker -rpath -Xlinker "$CLT/usr/lib")
    fi
    exec swift test ${flags[@]+"${flags[@]}"}
fi

APP="build/Lord of the Claudes.app"

swift build -c release
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/LordOfTheClaudes .build/release/lotc "$APP/Contents/MacOS/"
cp Info.plist "$APP/Contents/"
# Code nested in a bundle is signed before the bundle itself.
codesign --force --sign - "$APP/Contents/MacOS/lotc"
codesign --force --sign - "$APP"
echo "Built $APP"

if [ "${1:-}" = "install" ]; then
    pkill -x LordOfTheClaudes || true
    rm -rf "/Applications/Lord of the Claudes.app"
    cp -R "$APP" /Applications/
    open "/Applications/Lord of the Claudes.app"
    echo "Installed and started /Applications/Lord of the Claudes.app"
    if command -v brew >/dev/null; then
        ln -sf "/Applications/Lord of the Claudes.app/Contents/MacOS/lotc" "$(brew --prefix)/bin/lotc"
        echo "Linked $(brew --prefix)/bin/lotc"
    fi
fi
