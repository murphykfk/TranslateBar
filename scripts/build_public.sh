#!/bin/zsh
set -euo pipefail

# Build a fresh ad hoc app without copying a locally signed app bundle.
project_dir="${0:A:h:h}"
cd "$project_dir"
output_dir="${1:-$project_dir/dist/public}"
output_dir="${output_dir:A}"
if [[ -e "$output_dir/TranslateBar.app" ]]; then
    print -u2 "Output already exists: $output_dir/TranslateBar.app"
    exit 1
fi
swift build -c release
mkdir -p "$output_dir"
public_workdir=$(mktemp -d "$output_dir/.stage.XXXXXX")
trap 'rm -rf -- "$public_workdir"' EXIT
app_dir="$public_workdir/TranslateBar.app"
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"
cp .build/release/TranslateBar "$app_dir/Contents/MacOS/TranslateBar"
codesign --remove-signature "$app_dir/Contents/MacOS/TranslateBar"
strip -S -x "$app_dir/Contents/MacOS/TranslateBar"
python3 scripts/make_plist.py "$app_dir/Contents/Info.plist"
swift scripts/make_icon.swift "$app_dir/Contents/Resources/AppIcon.icns"
codesign --force --sign - --timestamp=none --options runtime \
    --entitlements Resources/TranslateBar.entitlements --identifier com.murphy.TranslateBar "$app_dir"
codesign --verify --deep --strict "$app_dir"
mv "$app_dir" "$output_dir/TranslateBar.app"
print "Built public ad hoc app: $output_dir/TranslateBar.app"
