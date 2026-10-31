#!/bin/zsh
set -euo pipefail
project_dir="${0:A:h:h}"
cd "$project_dir"
fixture_dir="$project_dir/.build/TranslateBarFixture.app"
mkdir -p "$fixture_dir/Contents/MacOS"
swiftc Tools/TestFixture.swift -o "$fixture_dir/Contents/MacOS/TranslateBarFixture"
python3 - "$fixture_dir/Contents/Info.plist" "$project_dir/.build/translation-fixture.aiff" <<'PY'
import plistlib, sys
with open(sys.argv[1], 'wb') as f:
    plistlib.dump({'CFBundleIdentifier':'com.murphy.TranslateBarFixture','CFBundleName':'TranslateBarFixture','CFBundleExecutable':'TranslateBarFixture','CFBundlePackageType':'APPL','FixtureAudioPath':sys.argv[2]}, f)
PY
codesign --force --sign - "$fixture_dir"
