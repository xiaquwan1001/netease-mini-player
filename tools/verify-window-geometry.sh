#!/usr/bin/env bash
# 桌面窗口几何回归(平台审计 P2#2 最小尺寸 / P2#3 尺寸记忆) —— 真跑 GUI 的验收脚本。
#
# 用法: bash tools/verify-window-geometry.sh [bundle 路径]
#   默认 bundle = ui/build/linux/x64/release/bundle; 显示号用 DISPLAY_NUM 覆盖(默认 :91)。
#
# 断言(全部是"量出来的数字", 不是读码):
#   A. 冷启动(还没有 window.ini) ⇒ 1280x720;
#   B. `xdotool windowsize 200 300` ⇒ 实际几何不得小于 420x480 —— GTK 按
#      WM_NORMAL_HINTS 的 PMinSize 夹住(GtkWindow 自己就夹, 所以无 WM 的 Xvfb 里也生效),
#      这就是 P2#2 的现场: 修之前这里会真的变成 200x300 把播放条按钮裁掉;
#   C. 改成 900x600 → 停手 4s(size-allocate 去抖 2s)⇒ 退出后
#      `$XDG_CONFIG_HOME/minincm/window.ini` 里 width=900 / height=600;
#   D. 用同一份配置重启 ⇒ 几何回到 900x600(窗口边框容差 ±40);
#   E. window.ini 里塞非法尺寸(100x50) ⇒ 回落 1280x720。
#
# 为什么自带 Xvfb 而不是 xvfb-run: 三个用例要在**同一块屏**上先后启动同一个二进制
# (A 冷启动 / D 恢复 / E 非法回落), 每段都重新起 server 只会更慢。
#
# 退出码: 0 全通过 / 1 有断言失败 / 3 缺工具或 bundle。
set -uo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
BUNDLE=${1:-${BUNDLE:-$ROOT/ui/build/linux/x64/release/bundle}}
BIN="$BUNDLE/minincm"
DST=${DISPLAY_NUM:-:91}
# 与 ui/linux/runner/my_application.cc 的 kMinWindowWidth/kMinWindowHeight 同一对数
MIN_W=420
MIN_H=480
DEFAULT_W=1280
DEFAULT_H=720
FRAME_TOLERANCE=40
# 等窗口 map 上来: 冷启动 = Flutter 引擎 + Rust 内核, 实测 5~9s
WINDOW_WAIT_SECONDS=${WINDOW_WAIT_SECONDS:-30}

ok()   { printf '[ OK ] %s\n' "$1"; }
bad()  { printf '[FAIL] %s\n' "$1"; FAILED=1; }
skip() { printf '[SKIP] %s\n' "$1"; }
info() { printf '[INFO] %s\n' "$1"; }
FAILED=0

for tool in Xvfb xdpyinfo xdotool xwininfo timeout; do
  command -v "$tool" >/dev/null 2>&1 || { skip "缺 $tool"; exit 3; }
done
[ -x "$BIN" ] || { skip "没有可执行的 bundle($BIN): 先 flutter build linux --release"; exit 3; }
case "$DST" in
  # :94~:98 是别的车道的自测显示号, 别抢
  :94|:95|:96|:97|:98) echo "[FAIL] 显示号 $DST 已被其它车道占用, 换一个(DISPLAY_NUM=:91)" >&2; exit 2 ;;
esac

TMP=$(mktemp -d)
XVFB_PID=""
APP_PID=""
cleanup() {
  [ -n "$APP_PID" ] && kill -9 "$APP_PID" 2>/dev/null
  pkill -9 -f "$BIN" 2>/dev/null
  [ -n "$XVFB_PID" ] && kill -9 "$XVFB_PID" 2>/dev/null
  rm -rf "$TMP"
}
trap cleanup EXIT

export DISPLAY="$DST"
unset WAYLAND_DISPLAY
export GDK_BACKEND=x11
export NCM_DATA_DIR="$TMP/data"
# 尺寸记忆落在 XDG_CONFIG_HOME 下: 用例之间**共享**(D 就是靠它), 但绝不碰真实 ~/.config
export XDG_CONFIG_HOME="$TMP/config"
WINDOW_INI="$XDG_CONFIG_HOME/minincm/window.ini"
mkdir -p "$NCM_DATA_DIR" "$XDG_CONFIG_HOME"

info "bundle: $BIN"
info "display: $DST / XDG_CONFIG_HOME: $XDG_CONFIG_HOME"

timeout -k 10 20 Xvfb "$DST" -screen 0 1366x900x24 -nolisten tcp >"$TMP/xvfb.log" 2>&1 &
XVFB_PID=$!
for _ in $(seq 1 50); do
  timeout -k 5 10 xdpyinfo >/dev/null 2>&1 && break
  sleep 0.2
done
timeout -k 5 10 xdpyinfo >/dev/null 2>&1 || { skip "Xvfb $DST 起不来(见 $TMP/xvfb.log)"; exit 3; }
ok "Xvfb $DST 已就绪"

# ---------------------------------------------------------------------------
# 起停应用 + 量几何
# ---------------------------------------------------------------------------
# 找主窗口: 按标题筛 + 只要 Map State=IsViewable 的(未 map 的窗口 set size 会 BadMatch)
find_window() {
  local cand geo w h ms
  for _ in $(seq 1 $((WINDOW_WAIT_SECONDS * 2))); do
    while read -r cand; do
      [ -n "$cand" ] || continue
      geo=$(timeout -k 5 10 xwininfo -id "$cand" 2>/dev/null |
        awk '/^  Width:/{w=$2} /^  Height:/{h=$2} END{print w" "h}')
      w=${geo% *}
      h=${geo#* }
      [ "${w:-0}" -ge 200 ] 2>/dev/null || continue
      [ "${h:-0}" -ge 200 ] 2>/dev/null || continue
      ms=$(timeout -k 5 10 xwininfo -id "$cand" 2>/dev/null | sed -n 's/^ *Map State: *//p')
      if [ "$ms" = "IsViewable" ]; then
        WID=$cand
        return 0
      fi
    done <<<"$(timeout -k 5 10 xdotool search --name "轻音 MiniNCM" 2>/dev/null)"
    sleep 0.5
  done
  return 1
}

# 窗口客户区几何 "宽x高"(无 WM 的 Xvfb 里就是窗口本身, 有 WM 时是客户区)
window_geometry() {
  timeout -k 5 10 xwininfo -id "$WID" 2>/dev/null |
    awk '/^  Width:/{w=$2} /^  Height:/{h=$2} END{print w"x"h}'
}

# 起一个实例并等到窗口出来(dbus-run-session: 严格单实例需要会话总线)。
# SIGTERM 发给 dbus-run-session = 它会转发给被测进程(db-run-session 的信号处理)。
start_app() {
  local tag=$1
  timeout -k 10 300 dbus-run-session -- "$BIN" >"$TMP/app-$tag.log" 2>&1 &
  APP_PID=$!
  WID=""
  if ! find_window; then
    bad "用例 $tag: ${WINDOW_WAIT_SECONDS}s 内没等到主窗口(日志 $TMP/app-$tag.log)"
    return 1
  fi
  return 0
}

stop_app() {
  [ -n "$APP_PID" ] || return 0
  kill -TERM "$APP_PID" 2>/dev/null
  for _ in $(seq 1 50); do
    kill -0 "$APP_PID" 2>/dev/null || break
    sleep 0.1
  done
  kill -9 "$APP_PID" 2>/dev/null
  wait "$APP_PID" 2>/dev/null
  pkill -f "$BIN" 2>/dev/null
  for _ in $(seq 1 30); do
    pgrep -f "$BIN" >/dev/null 2>&1 || break
    sleep 0.1
  done
  APP_PID=""
}

# 断言几何落在 [期望-容差, 期望+容差]
expect_geometry() {
  local tag=$1 want_w=$2 want_h=$3 geo w h
  geo=$(window_geometry)
  w=${geo%x*}
  h=${geo#*x}
  if [ $((w - want_w)) -le $FRAME_TOLERANCE ] && [ $((want_w - w)) -le $FRAME_TOLERANCE ] &&
     [ $((h - want_h)) -le $FRAME_TOLERANCE ] && [ $((want_h - h)) -le $FRAME_TOLERANCE ]; then
    ok "$tag: 几何 $geo(期望 ${want_w}x${want_h}, 容差 ±$FRAME_TOLERANCE)"
  else
    bad "$tag: 几何 $geo ≠ 期望 ${want_w}x${want_h}(容差 ±$FRAME_TOLERANCE)"
  fi
}

# ---------------------------------------------------------------------------
# A. 冷启动默认尺寸
# ---------------------------------------------------------------------------
info "--- A. 冷启动(没有 window.ini)应回到 ${DEFAULT_W}x${DEFAULT_H} ---"
rm -f "$WINDOW_INI"
if start_app A; then
  [ -f "$WINDOW_INI" ] && info "启动时就写了 $WINDOW_INI(不该, 先记下)" || true
  expect_geometry "A 冷启动" "$DEFAULT_W" "$DEFAULT_H"

  # -------------------------------------------------------------------------
  # B. 最小尺寸: 200x300 必须被夹到 420x480 以上
  # -------------------------------------------------------------------------
  info "--- B. xdotool windowsize 200 300 ⇒ 不得小于 ${MIN_W}x${MIN_H} ---"
  timeout -k 5 10 xdotool windowsize "$WID" 200 300
  sleep 2
  GEO=$(window_geometry)
  BW=${GEO%x*}
  BH=${GEO#*x}
  if [ "${BW:-0}" -ge "$MIN_W" ] && [ "${BH:-0}" -ge "$MIN_H" ]; then
    ok "B 200x300 被夹到 $GEO(≥ ${MIN_W}x${MIN_H})"
  else
    bad "B 200x300 之后几何 $GEO 小于 ${MIN_W}x${MIN_H}(最小尺寸没生效)"
  fi

  # -------------------------------------------------------------------------
  # C. 改成 900x600 ⇒ 去抖落盘
  # -------------------------------------------------------------------------
  info "--- C. 改成 900x600, 停手 4s ⇒ window.ini 记为 900x600 ---"
  timeout -k 5 10 xdotool windowsize "$WID" 900 600
  sleep 4
  expect_geometry "C 改尺寸后" 900 600
  stop_app
  if [ -f "$WINDOW_INI" ]; then
    info "window.ini: $(tr '\n' ' ' <"$WINDOW_INI")"
    if grep -q '^width=900$' "$WINDOW_INI" && grep -q '^height=600$' "$WINDOW_INI"; then
      ok "C window.ini 记下 width=900 / height=600"
    else
      bad "C window.ini 内容不对(见上一条 INFO)"
    fi
  else
    bad "C 没有写出 $WINDOW_INI"
  fi
else
  stop_app
fi

# ---------------------------------------------------------------------------
# D. 重启恢复
# ---------------------------------------------------------------------------
info "--- D. 重启应回到 900x600 ---"
if start_app D; then
  expect_geometry "D 重启恢复" 900 600
  stop_app
else
  stop_app
fi

# ---------------------------------------------------------------------------
# E. 非法值回落
# ---------------------------------------------------------------------------
info "--- E. window.ini 里塞 100x50(非法)应回落 ${DEFAULT_W}x${DEFAULT_H} ---"
mkdir -p "$(dirname "$WINDOW_INI")"
printf '[window]\nwidth=100\nheight=50\nmaximized=false\n' >"$WINDOW_INI"
if start_app E; then
  expect_geometry "E 非法值回落" "$DEFAULT_W" "$DEFAULT_H"
  stop_app
else
  stop_app
fi

if [ "$FAILED" -eq 0 ]; then
  echo "窗口几何回归: PASS"
  exit 0
fi
echo "窗口几何回归: FAIL"
exit 1
