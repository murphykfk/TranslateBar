#!/bin/zsh
set -euo pipefail
project_dir="${0:A:h:h}"
cd "$project_dir"
swift build -c release
app_dir="$project_dir/dist/TranslateBar.app"
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"
cp .build/release/TranslateBar "$app_dir/Contents/MacOS/.TranslateBar.new"
mv -f "$app_dir/Contents/MacOS/.TranslateBar.new" "$app_dir/Contents/MacOS/TranslateBar"
python3 scripts/make_plist.py "$app_dir/Contents/Info.plist"
swift scripts/make_icon.swift "$app_dir/Contents/Resources/AppIcon.icns"
signing_identity="${TRANSLATEBAR_SIGN_ID:-$(python3 - <<'PY'
import re, subprocess
result = subprocess.run(['security', 'find-identity', '-v', '-p', 'codesigning'], capture_output=True, text=True)
matches = re.findall(r'\b([0-9A-F]{40}) "(?:Apple Development:|Developer ID Application:)[^"\n]*"', result.stdout)
print(matches[0] if matches else '-')
PY
)}"
codesign --force --sign "$signing_identity" --timestamp=none --options runtime --entitlements Resources/TranslateBar.entitlements --identifier com.murphy.TranslateBar "$app_dir"
codesign --verify --deep --strict "$app_dir"
printf 'Built: %s\n' "$app_dir"
