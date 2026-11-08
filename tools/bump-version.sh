#!/usr/bin/env bash
# 版本号提升: 唯一事实来源是 ui/pubspec.yaml 的 `version: X.Y.Z+N`。
#   X.Y.Z = versionName(展示给用户)  +N = versionCode(Android 覆盖安装必须递增)
# 同步修改:
#   - ui/pubspec.yaml            version
#   - ui/lib/src/app_meta.dart   kAppVersion(设置页「关于」显示)
# 用法: bash tools/bump-version.sh [patch|minor|major]   (默认 patch)
set -euo pipefail
cd "$(dirname "$0")/.."

KIND="${1:-patch}"
PUBSPEC="ui/pubspec.yaml"
META="ui/lib/src/app_meta.dart"

python3 - "$KIND" <<'PY'
import re, sys, pathlib

kind = sys.argv[1]
if kind not in ("patch", "minor", "major"):
    sys.exit(f"unknown kind: {kind}")

pub = pathlib.Path("ui/pubspec.yaml")
meta = pathlib.Path("ui/lib/src/app_meta.dart")

text = pub.read_text()
m = re.search(r"^version:\s*(\d+)\.(\d+)\.(\d+)\+(\d+)\s*$", text, re.M)
if not m:
    sys.exit("ui/pubspec.yaml 里的 version 不是 X.Y.Z+N 形式")
major, minor, patch, build = (int(x) for x in m.groups())

if kind == "major":
    major, minor, patch = major + 1, 0, 0
elif kind == "minor":
    minor, patch = minor + 1, 0
else:
    patch += 1
build += 1

new = f"{major}.{minor}.{patch}+{build}"
text = re.sub(r"^version:.*$", f"version: {new}", text, count=1, flags=re.M)
pub.write_text(text)

mtext = meta.read_text()
mtext, n = re.subn(
    r"const String kAppVersion = '[^']*';",
    f"const String kAppVersion = '{major}.{minor}.{patch}';",
    mtext,
    count=1,
)
if n != 1:
    sys.exit("ui/lib/src/app_meta.dart 里没找到 kAppVersion")
meta.write_text(mtext)

print(f"version -> {new}  (versionName={major}.{minor}.{patch}, versionCode={build})")
PY

echo "改完记得: bash tools/build-android.sh / git tag v<versionName>"
