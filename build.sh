#!/bin/bash
# LectureRecorderをビルドして ~/Applications に入れ、起動します
set -euo pipefail
cd "$(dirname "$0")"

if ! xcrun --find swiftc >/dev/null 2>&1; then
  echo "Swiftのコンパイラが見つかりません。出てくる画面で「インストール」を押し、終わったらもう一度 ./build.sh を実行してください。"
  xcode-select --install || true
  exit 1
fi

APP="$HOME/Applications/LectureRecorder.app"
OLD_APP="$HOME/Applications/講義レコーダー.app"   # 旧名の版を片付ける
ARCH="$(uname -m)"

echo "ビルド中…"
pkill -x LectureRecorder 2>/dev/null || true
rm -rf build && mkdir -p build
xcrun swiftc -O -parse-as-library -swift-version 5 \
  -target "${ARCH}-apple-macos13.0" \
  -o build/LectureRecorder Sources/*.swift \
  -framework Cocoa -framework AVFoundation -framework Speech \
  -framework UserNotifications -framework ServiceManagement -framework SwiftUI

mkdir -p "$HOME/Applications"
rm -rf "$APP" "$OLD_APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp build/LectureRecorder "$APP/Contents/MacOS/LectureRecorder"
cp Info.plist "$APP/Contents/Info.plist"
cp AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
codesign --force --sign - "$APP"
touch "$APP"   # アイコンの表示を更新

echo "完了：$APP"
open "$APP"
