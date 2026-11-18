#!/usr/bin/env bash
# AppImage 冒烟(平台审计 P3 / §11.A 桌面端冒烟的第一段: **只验 AppImage 产物本身**)。
#
# 用法:
#   tools/smoke-appimage.sh                          # 自动挑 dist/ 里最新的 *.AppImage
#   APPIMAGE=<path> tools/smoke-appimage.sh          # 指定产物
#   BUILD=1 tools/smoke-appimage.sh                  # 先 flutter build linux --release + 打 AppImage(慢)
#   STATIC_ONLY=1 tools/smoke-appimage.sh            # 只做解包/资产断言(无图形工具也能跑)
#
# 判据(全部自动断言, 不需要人看屏幕; 每条都写清"看什么"):
#
#  A. 产物静态(用自带的 --appimage-extract 解包, 不需要 FUSE/root):
#    ① squashfs 里 AppRun 可执行且指向 usr/bin/minincm;
#    ② 根有 <application-id>.desktop, usr/share/applications 里同一份;
#       Exec=minincm %U / Icon=minincm / StartupWMClass=<application-id> / X-AppImage-Version=<ver>;
#    ③ 图标 256x256 PNG(.DirIcon 是它的符号链接), AppStream metainfo 的 <id>/<launchable>/<release version>;
#    ④ 运行期资产齐: usr/bin/minincm + data/icudtl.dat + data/flutter_assets/{AssetManifest.bin,
#       FontManifest.json,fonts/MaterialIcons-Regular.otf,shaders/,NOTICES.Z,version.json}
#       + lib/{libflutter_linux_gtk.so,libapp.so,libncm_ffi.so};
#    ⑤ ELF 架构与文件名架构一致(x86_64/aarch64);
#    ⑥ GLib 基线: minincm 不得引用 g_once_init_*_pointer(否则 Ubuntu 22.04 起不来, issue #2);
#    ⑦ 版本一致: 文件名 / .desktop / metainfo 与 ui/pubspec.yaml 同一个版本。
#
#  B. 运行期(xvfb-run + 独立 dbus session, 临时 HOME, 不碰真实用户目录):
#    ⑧ 进程存活 N 秒(默认 8s); 有 FUSE 走真实挂载, 否则退到 APPIMAGE_EXTRACT_AND_RUN=1;
#    ⑨ 默认数据目录 $HOME/.local/share/<application-id> 自动创建 + identity.json/settings.json 落地
#       (证明 Rust 内核起来且路径确实跟着 application-id 走);
#    ⑩ 复用: 同一 HOME 再启一次, identity.json 内容不变(device_id 不重建, 身份纪律);
#    ⑪ NCM_DATA_DIR 显式指定时优先生效(指定目录被创建);
#    ⑫ 日志无 panic / segmentation fault / core dumped / GLib-ERROR / Gtk-ERROR。
#
#  C. 托盘(可选, 需 python3+PyGObject 与 libayatana-appindicator3):
#    ⑬ settings.json 的 closeBehavior=tray ⇒ 启动即建托盘(日志"托盘已就绪");
#    ⑭ 经 dbusmenu(com.canonical.dbusmenu.GetLayout)回读菜单: 8 子项 = 6 个文案项 + 2 条分隔线,
#       顺序 显示主界面 · ─ · 播放/暂停 · 上一首 · 下一首 · 喜欢/取消喜欢 · ─ · 退出;
#       未登录/无曲目时四个播放控制项 enabled=0(置灰, 不是崩溃)。
#
# 退出码: 0 全通过 / 1 有断言失败 / 3 没有产物或缺工具(门禁按 SKIP 处理, 不算失败)。
set -uo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
APPIMAGE=${APPIMAGE:-}
BUILD=${BUILD:-0}
STATIC_ONLY=${STATIC_ONLY:-0}
ALIVE_SECONDS=${ALIVE_SECONDS:-8}
APP_ID=${APP_ID:-$(sed -n 's/^set(APPLICATION_ID "\(.*\)")$/\1/p' "$ROOT/ui/linux/CMakeLists.txt" | head -1)}
APP_ID=${APP_ID:-io.github.xiaquwan1001.MiniNCM}
EXPECTED_VER=${EXPECTED_VER:-$(sed -n 's/^version: *\([^+ ]*\).*/\1/p' "$ROOT/ui/pubspec.yaml" | head -1)}

ok()   { printf '[ OK ] %s\n' "$1"; }
bad()  { printf '[FAIL] %s\n' "$1"; FAILED=1; }
skip() { printf '[SKIP] %s\n' "$1"; }
info() { printf '[INFO] %s\n' "$1"; }
FAILED=0
T_START=$(date +%s)

TMP=$(mktemp -d)
cleanup() { if [ "${KEEP_TMP:-0}" = "1" ]; then info "保留临时目录: $TMP"; return; fi; rm -rf "$TMP"; }
trap cleanup EXIT

# ---------- 0. 找产物 ----------
if [ "$BUILD" = "1" ]; then
  info "BUILD=1: 先编 release bundle 再打 AppImage"
  # 只出 AppImage 的最小链路: flutter build linux --release + packaging/linux/build-appimage.sh
  ( cd "$ROOT/ui" && source "$ROOT/tools/env.sh" && timeout -k 30 1800 flutter build linux --release ) \
    || { bad "flutter build linux --release 失败"; exit 1; }
  OUTDIR="$TMP/dist"
  timeout -k 30 600 bash "$ROOT/packaging/linux/build-appimage.sh" "$OUTDIR" \
    || { bad "packaging/linux/build-appimage.sh 失败"; exit 1; }
  APPIMAGE=$(ls -t "$OUTDIR"/*.AppImage | head -1)
fi

if [ -z "$APPIMAGE" ]; then
  # 默认挑 dist/ 里最新的产物; 没有就 SKIP(冒烟不负责出包)
  APPIMAGE=$(ls -t "$ROOT"/dist/*.AppImage 2>/dev/null | head -1 || true)
fi
if [ -z "$APPIMAGE" ] || [ ! -f "$APPIMAGE" ]; then
  skip "没有 AppImage 产物(找 dist/*.AppImage; 或用 APPIMAGE=<路径> / BUILD=1), 本段冒烟跳过"
  exit 3
fi
[ -x "$APPIMAGE" ] || chmod +x "$APPIMAGE" 2>/dev/null || true
BASE=$(basename "$APPIMAGE")
info "AppImage: $APPIMAGE"
info "大小: $(du -h "$APPIMAGE" | cut -f1) ($(stat -c %s "$APPIMAGE") 字节)  sha256=$(sha256sum "$APPIMAGE" | cut -d' ' -f1)"
info "期望版本(ui/pubspec.yaml): ${EXPECTED_VER:-<取不到>}  期望 application-id: $APP_ID"

# ---------- A. 静态 ----------
info "--- A. 解包与资产断言 ---"
EX="$TMP/extract"
mkdir -p "$EX"
if ! ( cd "$EX" && timeout -k 10 180 "$APPIMAGE" --appimage-extract >"$TMP/extract.log" 2>&1 ); then
  bad "AppImage --appimage-extract 失败"
  tail -5 "$TMP/extract.log" | sed 's/^/  | /'
  echo "AppImage 冒烟: FAIL"
  exit 1
fi
SR="$EX/squashfs-root"
[ -d "$SR" ] || { bad "解包后没有 squashfs-root"; echo "AppImage 冒烟: FAIL"; exit 1; }
ok "解包成功(squashfs-root, $(du -sh "$SR" | cut -f1))"

# ① AppRun
if [ -x "$SR/AppRun" ]; then ok "AppRun 可执行"; else bad "AppRun 缺失或不可执行"; fi
if grep -q 'usr/bin/minincm' "$SR/AppRun" 2>/dev/null; then
  ok "AppRun 启动 AppDir 内的 usr/bin/minincm(不依赖系统 Flutter 运行时)"
else
  bad "AppRun 没有指向 usr/bin/minincm"
fi

# ② .desktop
DESK="$SR/$APP_ID.desktop"
DSK_IN_SHARE="$SR/usr/share/applications/$APP_ID.desktop"
if [ -f "$DESK" ]; then ok ".desktop 在 AppDir 根: $(basename "$DESK")"; else bad "AppDir 根缺 $APP_ID.desktop"; fi
if [ -f "$DSK_IN_SHARE" ]; then ok ".desktop 也在 usr/share/applications(桌面集成可见)"; else bad "usr/share/applications 里缺 $APP_ID.desktop"; fi
check_kv() { # <file> <key> <期望值> <说明>
  local f=$1 key=$2 want=$3 desc=$4 got
  got=$(sed -n "s/^$key=//p" "$f" 2>/dev/null | head -1)
  if [ "$got" = "$want" ]; then ok "$desc: $key=$got"; else bad "$desc: $key='${got}' 期望 '$want'"; fi
}
if [ -f "$DESK" ]; then
  check_kv "$DESK" Exec 'minincm %U' "desktop 入口"
  check_kv "$DESK" Icon 'minincm' "desktop 图标"
  check_kv "$DESK" StartupWMClass "$APP_ID" "desktop 归组(必须等于 application-id)"
  check_kv "$DESK" X-AppImage-Version "$EXPECTED_VER" "desktop 版本"
  grep -q '^Categories=.*Audio.*Player' "$DESK" && ok "desktop Categories 含 Audio/Player" || bad "desktop Categories 不含 Audio/Player"
  if command -v desktop-file-validate >/dev/null 2>&1; then
    if desktop-file-validate "$DESK" >"$TMP/dfv.log" 2>&1; then
      ok "desktop-file-validate 无告警"
    else
      bad "desktop-file-validate 报错: $(head -2 "$TMP/dfv.log" | tr '\n' ' ')"
    fi
  else
    skip "desktop-file-validate: 未安装"
  fi
fi

# ③ 图标 + metainfo
ICON="$SR/usr/share/icons/hicolor/256x256/apps/minincm.png"
if [ -f "$ICON" ] && file -b "$ICON" | grep -q 'PNG image data, 256 x 256'; then
  ok "图标 256x256 PNG($(stat -c %s "$ICON") 字节)"
else
  bad "缺 256x256 PNG 图标($ICON)"
fi
if [ -L "$SR/.DirIcon" ] || [ -f "$SR/.DirIcon" ]; then ok ".DirIcon 存在(文件管理器显示用)"; else bad ".DirIcon 缺失"; fi
META="$SR/usr/share/metainfo/$APP_ID.metainfo.xml"
if [ -f "$META" ]; then
  ok "AppStream metainfo 已打进 AppDir"
  grep -q "<id>$APP_ID</id>" "$META" && ok "metainfo <id> = application-id" || bad "metainfo <id> 不是 $APP_ID"
  grep -q "<launchable type=\"desktop-id\">$APP_ID.desktop</launchable>" "$META" \
    && ok "metainfo <launchable> 指向 $APP_ID.desktop" || bad "metainfo <launchable> 不对"
  grep -q "version=\"$EXPECTED_VER\"" "$META" && ok "metainfo release version = $EXPECTED_VER" \
    || bad "metainfo release version 不是 $EXPECTED_VER($(grep -o 'version="[^"]*"' "$META" | head -1))"
else
  bad "缺 AppStream metainfo"
fi

# ④ 运行期资产
BIN="$SR/usr/bin/minincm"
if [ -s "$BIN" ] && [ -x "$BIN" ]; then ok "usr/bin/minincm 可执行($(stat -c %s "$BIN") 字节)"; else bad "usr/bin/minincm 缺失/0 字节/不可执行"; fi
for f in \
  "usr/bin/data/icudtl.dat" \
  "usr/bin/data/flutter_assets/AssetManifest.bin" \
  "usr/bin/data/flutter_assets/FontManifest.json" \
  "usr/bin/data/flutter_assets/fonts/MaterialIcons-Regular.otf" \
  "usr/bin/data/flutter_assets/NOTICES.Z" \
  "usr/bin/data/flutter_assets/version.json" \
  "usr/bin/data/flutter_assets/shaders/ink_sparkle.frag" \
  "usr/bin/lib/libflutter_linux_gtk.so" \
  "usr/bin/lib/libapp.so" \
  "usr/bin/lib/libncm_ffi.so" ; do
  if [ -s "$SR/$f" ]; then
    ok "资产 $(stat -c %s "$SR/$f") 字节  $f"
  else
    bad "缺运行期资产: $f"
  fi
done
# 字体口径: 项目没有自带字体资源(ui/pubspec.yaml 的 assets/fonts 全注释), 只有 Material 图标字体;
# 正文中文字体来自系统 fontconfig ⇒ AppImage 不保证在没装中文字体的机器上不出方块。
if compgen -G "$SR/usr/bin/data/flutter_assets/assets/*" >/dev/null 2>&1; then
  info "flutter_assets/assets/ 有内容(打包了自有资源)"
else
  info "flutter_assets/assets/ 为空 —— 与 pubspec 未声明 assets 一致; 中文字体靠系统 fontconfig"
fi

# ⑤ ELF 架构
ELF=$(LC_ALL=C readelf -h "$BIN" 2>/dev/null | sed -n 's/^ *Machine: *//p' | head -1)
case "$BASE:$ELF" in
  *x86_64*:"Advanced Micro Devices X86-64") ok "ELF 架构与 x86_64 文件名一致" ;;
  *aarch64*:"AArch64") ok "ELF 架构与 aarch64 文件名一致" ;;
  *) bad "文件名架构与 ELF Machine 不匹配(文件='$BASE', ELF='$ELF')" ;;
esac

# ⑥ GLib 符号基线
if command -v nm >/dev/null 2>&1; then
  if nm -D "$BIN" 2>/dev/null | grep -qE 'g_once_init_(enter|leave)_pointer'; then
    bad "minincm 引用了 GLib 2.80 才有的 g_once_init_*_pointer(Ubuntu 22.04 上会 symbol lookup error)"
  else
    ok "GLib 基线: 没有引用 g_once_init_*_pointer(22.04 可启动)"
  fi
else
  skip "GLib 符号检查: 缺 nm"
fi

# ⑦ 版本一致性(文件名)
case "$BASE" in
  *"$EXPECTED_VER"*) ok "文件名版本与 pubspec 一致($EXPECTED_VER)" ;;
  *) bad "文件名里的版本不是 $EXPECTED_VER($BASE)" ;;
esac

if [ "$STATIC_ONLY" = "1" ]; then
  info "STATIC_ONLY=1: 跳过运行期断言"
  if [ "$FAILED" -ne 0 ]; then echo "AppImage 冒烟(静态): FAIL"; exit 1; fi
  echo "AppImage 冒烟(静态): PASS"
  info "耗时 $(( $(date +%s) - T_START ))s"
  exit 0
fi

# ---------- B/C 运行期所需工具 ----------
for tool in xvfb-run dbus-run-session timeout; do
  command -v "$tool" >/dev/null 2>&1 || { skip "缺 $tool, 无法无头驱动 AppImage"; exit 3; }
done
# 注意: 不要写成 `ldconfig -p | grep -q` —— pipefail 下 grep 提前退出会让 ldconfig 吃 SIGPIPE(141),
# 整条流水线非 0, 于是 FUSE/ayatana 检测会假阴性(2026-11-18 实测)。先落文件再 grep。
LDCONFIG_LIST="$TMP/ldconfig.txt"
( ldconfig -p 2>/dev/null || true ) > "$LDCONFIG_LIST"
HAVE_FUSE=0
if [ -r /dev/fuse ] && grep -q 'libfuse\.so\.2' "$LDCONFIG_LIST"; then HAVE_FUSE=1; fi
if [ "$HAVE_FUSE" = "1" ]; then
  info "检测到 FUSE(libfuse.so.2 + /dev/fuse): 直接挂载运行(真实用户路径)"
else
  info "没有 FUSE: 退到 APPIMAGE_EXTRACT_AND_RUN=1(等价 --appimage-extract-and-run)"
fi

# 公共内层脚本: 起 AppImage、等 N 秒、报状态。参数: <appimage> <HOME> <NCM_DATA_DIR|-> <日志> <case> <秒>
cat > "$TMP/inner.sh" <<'INNER'
#!/usr/bin/env bash
set -uo pipefail
APP=$1; HOME_DIR=$2; DATA=$3; LOG=$4; CASE=$5; ALIVE=$6
APP_ID=${APP_ID:?}
WATCHER_PY=${WATCHER_PY:-}; MENU_PY=${MENU_PY:-}
export HOME="$HOME_DIR"
mkdir -p "$HOME"
unset WAYLAND_DISPLAY          # 否则 GTK 去连真实 compositor, 窗口跑到用户屏幕上
export GDK_BACKEND=x11
if [ -n "$DATA" ] && [ "$DATA" != "-" ]; then export NCM_DATA_DIR="$DATA"; fi
DEFAULT_DATA="$HOME/.local/share/$APP_ID"
if [ "$CASE" = "tray" ]; then
  # 托盘是懒建的: settings.json 里 closeBehavior=tray ⇒ 启动时 Dart 就推给原生并 ensure_tray
  mkdir -p "$DEFAULT_DATA"
  printf '{"closeBehavior":"tray"}\n' > "$DEFAULT_DATA/settings.json"
fi
if [ "$CASE" = "tray" ] && [ -n "$WATCHER_PY" ]; then
  python3 "$WATCHER_PY" >"$LOG.watcher" 2>&1 &
  WP=$!
  # 必须先等宿主真正占住 well-known name: 应用在启动早期只探测一次,
  # 宿主还没 owner 时会判定"没有托盘宿主"并降级(2026-11-18 实测踩过)。
  for _ in $(seq 1 40); do
    grep -qa WATCHER_READY "$LOG.watcher" 2>/dev/null && break
    sleep 0.25
  done
fi
"$APP" >"$LOG" 2>&1 &
P=$!
sleep "$ALIVE"
if kill -0 "$P" 2>/dev/null; then echo "ALIVE=1"; else echo "ALIVE=0"; fi
if [ -d "$DEFAULT_DATA" ]; then echo "DEFAULT_DATADIR=1"; else echo "DEFAULT_DATADIR=0"; fi
if [ -f "$DEFAULT_DATA/identity.json" ]; then echo "IDENTITY=1"; else echo "IDENTITY=0"; fi
if [ -f "$DEFAULT_DATA/settings.json" ]; then echo "SETTINGS=1"; else echo "SETTINGS=0"; fi
if [ -n "$DATA" ] && [ "$DATA" != "-" ]; then
  if [ -d "$DATA" ]; then echo "ENV_DATADIR=1"; else echo "ENV_DATADIR=0"; fi
fi
echo "SHARE_DIRS=$(ls -1 "$HOME/.local/share" 2>/dev/null | tr '\n' ' ')"
if [ "$CASE" = "tray" ] && [ -n "$WATCHER_PY" ]; then
  sleep 6
  LINE=$(grep -a REG_SENDER "$LOG.watcher" 2>/dev/null | head -1 || true)
  SENDER=$(printf '%s' "$LINE" | awk '{print $2}')
  IPATH=$(printf '%s' "$LINE" | awk '{print $4}')
  echo "TRAY_SENDER=${SENDER:--}"
  if [ -n "$SENDER" ] && [ -n "$MENU_PY" ]; then
    python3 "$MENU_PY" "$SENDER" "$IPATH" 2>&1 | sed 's/^/MENU: /'
  else
    echo "MENU: NO_ITEM"
  fi
  kill -9 "$WP" 2>/dev/null || true
fi
kill -TERM "$P" 2>/dev/null || true
for _ in $(seq 1 50); do kill -0 "$P" 2>/dev/null || break; sleep 0.1; done
kill -9 "$P" 2>/dev/null || true
wait "$P" 2>/dev/null || true
INNER
chmod +x "$TMP/inner.sh"

# 假 StatusNotifierWatcher(托盘段用; 缺 PyGObject 就整段 SKIP)
cat > "$TMP/watcher.py" <<'WATCHER'
# 最小 StatusNotifierWatcher: 让会话总线上真的有一个宿主 owner(不断言图标渲染)。
import gi
from gi.repository import Gio, GLib

XML = """
<node>
  <interface name="org.kde.StatusNotifierWatcher">
    <method name="RegisterStatusNotifierItem"><arg type="s" direction="in"/></method>
    <method name="RegisterStatusNotifierHost"><arg type="s" direction="in"/></method>
    <property name="RegisteredStatusNotifierItems" type="as" access="read"/>
    <property name="IsStatusNotifierHostRegistered" type="b" access="read"/>
    <property name="ProtocolVersion" type="i" access="read"/>
    <signal name="StatusNotifierItemRegistered"><arg type="s"/></signal>
    <signal name="StatusNotifierItemUnregistered"><arg type="s"/></signal>
  </interface>
</node>"""

items = []
node = Gio.DBusNodeInfo.new_for_xml(XML)


def on_call(conn, sender, path, iface, method, params, inv):
    if method == "RegisterStatusNotifierItem":
        arg = params.unpack()[0]
        items.append(arg)
        print("REG_SENDER", sender, "REG_PATH", arg, flush=True)
    inv.return_value(None)


def on_get(conn, sender, path, iface, prop):
    if prop == "RegisteredStatusNotifierItems":
        return GLib.Variant("as", items)
    if prop == "IsStatusNotifierHostRegistered":
        return GLib.Variant("b", True)
    if prop == "ProtocolVersion":
        return GLib.Variant("i", 0)
    return None


def on_bus(conn, name):
    conn.register_object("/StatusNotifierWatcher", node.interfaces[0], on_call, on_get, None)


def on_acquired(conn, name):
    print("WATCHER_READY", flush=True)


Gio.bus_own_name(Gio.BusType.SESSION, "org.kde.StatusNotifierWatcher",
                 Gio.BusNameOwnerFlags.NONE, on_bus, on_acquired, None)
GLib.timeout_add_seconds(60, lambda: False)
GLib.MainLoop().run()
WATCHER

# dbusmenu 回读: 逐项打印 type/visible/enabled/label
cat > "$TMP/menu.py" <<'MENU'
import sys
import gi
from gi.repository import Gio, GLib

bus = Gio.bus_get_sync(Gio.BusType.SESSION, None)
sender, ipath = sys.argv[1], sys.argv[2]
try:
    r = bus.call_sync(sender, ipath, "org.freedesktop.DBus.Properties", "Get",
                      GLib.Variant("(ss)", ("org.kde.StatusNotifierItem", "Menu")),
                      GLib.VariantType("(v)"), Gio.DBusCallFlags.NONE, 5000, None)
    menu_path = r.unpack()[0]
except GLib.Error as e:
    print("NO_MENU_PROP", e.message)
    raise SystemExit(2)
print("MENU_PATH", menu_path)
r = bus.call_sync(sender, menu_path, "com.canonical.dbusmenu", "GetLayout",
                  GLib.Variant("(iias)", (0, -1, [])),
                  GLib.VariantType("(u(ia{sv}av))",), Gio.DBusCallFlags.NONE, 5000, None)
revision, root = r.unpack()
print("REVISION", revision)
count = 0
for item in root[2]:
    iid, props = item[0], item[1]
    if iid == 0:
        continue
    count += 1
    label = props.get("label", "") or "-"
    typ = props.get("type", "standard")
    print("ITEM", count, "type=%s" % typ,
          "visible=%d" % (1 if props.get("visible", True) else 0),
          "enabled=%d" % (1 if props.get("enabled", True) else 0),
          "label=%s" % label)
print("TOTAL", count)
MENU

WATCHER_PY="$TMP/watcher.py"
MENU_PY="$TMP/menu.py"
export WATCHER_PY MENU_PY APP_ID

RUN_MODE=extract
[ "$HAVE_FUSE" = "1" ] && RUN_MODE=fuse
if [ "$RUN_MODE" = "fuse" ]; then export APPIMAGE_EXTRACT_AND_RUN=0; else export APPIMAGE_EXTRACT_AND_RUN=1; fi

info "--- B. 运行期断言($RUN_MODE 方式, 临时 HOME) ---"
run_phase() { # <name> <home> <data|-> <case>
  local name=$1 home=$2 data=$3 case_=$4
  timeout -k 10 180 xvfb-run -a dbus-run-session -- \
    "$TMP/inner.sh" "$APPIMAGE" "$home" "$data" "$TMP/$name.log" "$case_" "$ALIVE_SECONDS" 2>&1
}

# ⑧⑨ 首次启动: 默认数据目录(XDG), 不设 NCM_DATA_DIR
H1="$TMP/home1"
OUT1=$(run_phase first "$H1" - run)
printf '%s\n' "$OUT1" | grep -E '^(ALIVE|DEFAULT_DATADIR|IDENTITY|SETTINGS|SHARE_DIRS|ENV_DATADIR)=' | sed 's/^/  | /'
if grep -q '^ALIVE=1$' <<<"$OUT1"; then ok "进程存活 ${ALIVE_SECONDS}s(启动成功, $RUN_MODE 方式)"; else bad "进程在 ${ALIVE_SECONDS}s 内退出($RUN_MODE 方式)"; fi
if grep -q '^DEFAULT_DATADIR=1$' <<<"$OUT1"; then
  ok "默认数据目录已创建: \$HOME/.local/share/$APP_ID"
else
  bad "默认数据目录没被创建($(grep '^SHARE_DIRS=' <<<"$OUT1"))"
fi
grep -q '^IDENTITY=1$' <<<"$OUT1" && ok "identity.json 已写入(身份持久层初始化)" || bad "数据目录里没有 identity.json"
# settings.json 只在用户改过设置(或退出时 flush)才落盘 → 缺它不算失败, 只做提示
if grep -q '^SETTINGS=1$' <<<"$OUT1"; then
  ok "settings.json 已落盘(设置持久化初始化)"
else
  info "settings.json 未出现(默认设置不落盘/退出时 flush, 不是失败)"
fi
SHARE=$(grep '^SHARE_DIRS=' <<<"$OUT1" | sed 's/^SHARE_DIRS=//')
if printf '%s' "$SHARE" | grep -q 'ncm'; then
  info "~/.local/share 下还有旧目录 'ncm'(首启迁移逻辑的产物, 属预期)"
fi

# ⑩ 复用: 同一 HOME 再启一次, identity.json 必须不变(device_id 不重建)
IDENT1=$(sha256sum "$H1/.local/share/$APP_ID/identity.json" 2>/dev/null | cut -d' ' -f1)
OUT2=$(run_phase second "$H1" - run)
printf '%s\n' "$OUT2" | grep -E '^(ALIVE|IDENTITY)=' | sed 's/^/  | /'
IDENT2=$(sha256sum "$H1/.local/share/$APP_ID/identity.json" 2>/dev/null | cut -d' ' -f1)
if [ -n "$IDENT1" ] && [ "$IDENT1" = "$IDENT2" ]; then
  ok "第二次启动复用既有 identity.json(device_id 未重建)"
else
  bad "第二次启动后 identity.json 变了(期望 '$IDENT1' 实际 '$IDENT2')"
fi
if grep -q '^ALIVE=1$' <<<"$OUT2"; then ok "第二次启动同样存活(数据目录复用时无异常)"; else bad "第二次启动进程退出"; fi

# ⑪ NCM_DATA_DIR 显式指定优先
D3="$TMP/ncm-data-env"
OUT3=$(run_phase envdir "$TMP/home3" "$D3" run)
printf '%s\n' "$OUT3" | grep -E '^(ALIVE|ENV_DATADIR)=' | sed 's/^/  | /'
if grep -q '^ENV_DATADIR=1$' <<<"$OUT3"; then
  ok "NCM_DATA_DIR 生效(指定目录被创建)"
else
  bad "NCM_DATA_DIR 没生效(指定目录未被使用)"
fi

# ⑫ 日志无崩溃痕迹
CRASH=""
for lg in "$TMP/first.log" "$TMP/second.log" "$TMP/envdir.log"; do
  [ -f "$lg" ] || continue
  hit=$(grep -aiE 'segmentation fault|core dumped|GLib-ERROR|Gtk-ERROR|^FATAL|panicked at' "$lg" | head -2 | tr '\n' ' ')
  [ -n "$hit" ] && CRASH="$CRASH [$lg] $hit"
done
if [ -z "$CRASH" ]; then
  ok "运行日志无崩溃痕迹(segfault/core/GLib-ERROR/Gtk-ERROR/panic)"
else
  bad "运行日志出现崩溃痕迹:$CRASH"
fi
if grep -qa 'libEGL warning: DRI3' "$TMP/first.log" 2>/dev/null; then
  info "日志有 libEGL DRI3 告警(xvfb 无 GPU 加速, 与产物质量无关)"
fi

# ---------- C. 托盘菜单 ----------
info "--- C. 托盘菜单(dbusmenu) ---"
if ! command -v python3 >/dev/null 2>&1 || ! python3 -c 'import gi; from gi.repository import Gio' >/dev/null 2>&1; then
  skip "托盘断言: 缺 python3/PyGObject"
elif ! grep -q 'ayatana-appindicator3' "$LDCONFIG_LIST"; then
  skip "托盘断言: 系统没有 libayatana-appindicator3(AppImage 不打包它, 属运行期推荐依赖)"
else
  OUT4=$(run_phase tray "$TMP/home4" - tray)
  printf '%s\n' "$OUT4" | grep -E '^(TRAY_SENDER=|MENU: )' | sed 's/^/  | /'
  if grep -qa '托盘已就绪' "$TMP/tray.log" 2>/dev/null; then
    ok "closeBehavior=tray 时启动即建好托盘(日志: 托盘已就绪)"
  else
    bad "托盘没建起来(日志里没有『托盘已就绪』)"
  fi
  HOSTLINE=$(grep -a '启动探测' "$TMP/tray.log" 2>/dev/null | head -1)
  info "原生探测: ${HOSTLINE:-<无>}"
  EXPECT_LABELS=$(printf '显示主界面\n-\n播放\n上一首\n下一首\n喜欢\n-\n退出\n')
  GOT_LABELS=$(grep '^MENU: ITEM ' <<<"$OUT4" | sed 's/.*label=//')
  GOT_TYPES=$(grep '^MENU: ITEM ' <<<"$OUT4" | sed 's/.*type=\([a-z]*\).*/\1/')
  GOT_TOTAL=$(grep '^MENU: TOTAL ' <<<"$OUT4" | sed 's/.*TOTAL //')
  if [ "${GOT_TOTAL:-0}" = "8" ]; then
    ok "托盘菜单共 8 个子项(6 个文案项 + 2 条分隔线)"
  else
    bad "托盘菜单子项数 ${GOT_TOTAL:-<取不到>}(期望 8 = 6 文案 + 2 分隔线)"
  fi
  if [ "$GOT_LABELS" = "$EXPECT_LABELS" ]; then
    ok "托盘菜单文案与顺序正确: 显示主界面·─·播放·上一首·下一首·喜欢·─·退出"
  else
    bad "托盘菜单文案/顺序不符(实际: $(printf '%s' "$GOT_LABELS" | tr '\n' ' '))"
  fi
  if [ "$(printf '%s\n' "$GOT_TYPES" | grep -c '^separator$')" = "2" ]; then
    ok "两条分隔线位置正确(显示主界面之后 / 喜欢之后)"
  else
    bad "分隔线数量不是 2(实际: $(printf '%s' "$GOT_TYPES" | tr '\n' ' '))"
  fi
  DISABLED=$(grep '^MENU: ITEM ' <<<"$OUT4" | grep -c 'enabled=0')
  if [ "$DISABLED" = "4" ]; then
    ok "无曲目时四个播放控制项 enabled=0(置灰, 符合预期)"
  else
    info "播放控制项置灰数 = ${DISABLED:-0}(未登录/无曲目时预期 4)"
  fi
fi

echo "----- 首次启动日志尾部 -----"
tail -12 "$TMP/first.log" 2>/dev/null | sed 's/^/  | /'

if [ "$FAILED" -ne 0 ]; then
  echo "AppImage 冒烟: FAIL"
  exit 1
fi
echo "AppImage 冒烟: PASS"
info "耗时 $(( $(date +%s) - T_START ))s"
