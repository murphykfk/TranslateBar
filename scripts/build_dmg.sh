#!/bin/zsh
set -euo pipefail

# Package an already-built app. Signing and notarization are separate steps.
project_dir="${0:A:h:h}"
app_dir="${1:-$project_dir/dist/TranslateBar.app}"
app_dir="${app_dir:A}"
output_dir="${2:-$project_dir/dist}"
output_dir="${output_dir:A}"

if [[ ! -f "$app_dir/Contents/Info.plist" || ! -x "$app_dir/Contents/MacOS/TranslateBar" ]]; then
    print -u2 'Usage: zsh scripts/build_dmg.sh /path/to/TranslateBar.app [output-directory]'
    exit 1
fi
case "$output_dir/" in
    "$app_dir/"*) print -u2 'The output directory must be outside the app bundle.'; exit 1 ;;
esac
codesign --verify --deep --strict "$app_dir"

version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app_dir/Contents/Info.plist")
if [[ ! "$version" =~ '^[0-9]+(\.[0-9]+)*$' ]]; then
    print -u2 'The app version must contain only numbers and dots.'
    exit 1
fi
architectures=$(lipo -archs "$app_dir/Contents/MacOS/TranslateBar")
case "$architectures" in
    arm64) package_arch=arm64 ;;
    x86_64) package_arch=x86_64 ;;
    'arm64 x86_64'|'x86_64 arm64') package_arch=universal ;;
    *) print -u2 "Unsupported app architecture: $architectures"; exit 1 ;;
esac

mkdir -p "$output_dir"
image_path="$output_dir/TranslateBar-$version-$package_arch.dmg"
if [[ -e "$image_path" ]]; then
    print -u2 "Output already exists: $image_path"
    exit 1
fi
dmg_workdir=$(mktemp -d "${TMPDIR:-/tmp}/TranslateBar-dmg.XXXXXX")
trap 'rm -rf -- "$dmg_workdir"' EXIT
mkdir "$dmg_workdir/content"
ditto --norsrc --noextattr "$app_dir" "$dmg_workdir/content/TranslateBar.app"
ln -s /Applications "$dmg_workdir/content/Applications"
cp "$project_dir/LICENSE" "$dmg_workdir/content/LICENSE.txt"
cat > "$dmg_workdir/content/安装说明.txt" <<'EOF'
TranslateBar

安装：将 TranslateBar.app 拖到 Applications（应用程序）文件夹。
如果正在运行旧版，请先从菜单栏退出，再替换应用。
完成复制后，弹出此磁盘映像，从“应用程序”中打开 TranslateBar。

需要 macOS 14.4 或更新版本，以及你自己的 OpenAI API Key。
首次启动时，按引导保存 Key、设置目标语言并授予所需系统权限。
关闭设置窗口后，应用仍在菜单栏运行。

项目与源码：https://github.com/murphykfk/TranslateBar
许可证：MIT（见 LICENSE.txt）

Install: drag TranslateBar.app to Applications.
Quit the previous version before replacing it. Eject this disk image after copying,
then launch TranslateBar from Applications and complete the first-run setup.
Requires macOS 14.4 or later and your own OpenAI API key.
EOF
codesign --verify --deep --strict "$dmg_workdir/content/TranslateBar.app"
hdiutil create -quiet -volname "TranslateBar $version" -srcfolder "$dmg_workdir/content" \
    -fs HFS+ -format UDZO -imagekey zlib-level=9 -nospotlight "$dmg_workdir/package.dmg"
hdiutil verify -quiet "$dmg_workdir/package.dmg"
mv "$dmg_workdir/package.dmg" "$image_path"
print "Built: $image_path"
