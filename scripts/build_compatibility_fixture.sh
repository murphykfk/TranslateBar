#!/bin/zsh
set -euo pipefail
project_dir="${0:A:h:h}"
cd "$project_dir"
fixture_dir="$project_dir/.build/CompatibilityFixture.app"
mkdir -p "$fixture_dir/Contents/MacOS"
swiftc Tools/CompatibilityFixture.swift -o "$fixture_dir/Contents/MacOS/CompatibilityFixture"
python3 - "$fixture_dir/Contents/Info.plist" <<'PY'
import plistlib,sys
with open(sys.argv[1],'wb') as f:
 plistlib.dump({'CFBundleIdentifier':'com.murphy.CompatibilityFixture','CFBundleName':'CompatibilityFixture','CFBundleExecutable':'CompatibilityFixture','CFBundlePackageType':'APPL'},f)
PY
codesign --force --sign - "$fixture_dir"
