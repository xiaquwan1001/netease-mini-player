#!/usr/bin/env bash
# 桌面端发布前冒烟脚本骨架。
# 用法:
#   tools/smoke-desktop.sh --env                       环境信息 + bundle 校验 + DATA 目录检查
#   tools/smoke-desktop.sh --run BUNDLE=<路径> [--wait-window]
#                                                      启动 bundle 里的 minincm, 采 15 秒启动耗时
#   tools/smoke-desktop.sh --report BUNDLE=<路径>      把 --env/--run 拼成 markdown
#
# 设计约束: bash 3.2 兼容; set -euo pipefail; 外部命令先 command -v, 缺失就 SKIP 不 fail; 不联网。

set -euo pipefail

LOG_DIR="${HOME}/.cache/minincm-smoke"
RUN_SECONDS=15

# ---- 小工具: 带标签输出, 可脚本化判断 ---------------------------------------
ok()   { printf '[ OK ] %s\n' "$1"; }
skip() { printf '[SKIP] %s\n' "$1"; }
bad()  { printf '[FAIL] %s\n' "$1"; }
info() { printf '[INFO] %s\n' "$1"; }

usage() { sed -n '2,10p' "$0"; exit 2; }

parse_args() {
  MODE=""
  BUNDLE=""
  WAIT_WINDOW=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --env|--run|--report) MODE="$1" ;;
      --wait-window) WAIT_WINDOW=1 ;;
      BUNDLE=*) BUNDLE="${1#BUNDLE=}" ;;
      -h|--help) usage ;;
      *) echo "未知参数: $1" >&2; usage ;;
    esac
    shift
  done
  [ -n "$MODE" ] || usage
}

# ---- 公共检查段 ------------------------------------------------------------

do_env() {
  echo "===== MiniNCM 桌面冒烟 --env ====="
  echo "时间: $(date '+%F %T %Z')"
  echo

  # 发行版
  if [ -r /etc/os-release ]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    info "发行版: ${PRETTY_NAME:-unknown}"
  else
    skip "发行版: /etc/os-release 不存在"
  fi

  # GLib 版本
  if command -v pkg-config >/dev/null 2>&1 && pkg-config --exists glib-2.0 2>/dev/null; then
    info "GLib(本机): $(pkg-config --modversion glib-2.0)"
  elif command -v ldconfig >/dev/null 2>&1 && ldconfig -p 2>/dev/null | grep -q 'libglib-2\.0'; then
    info "GLib(本机): 存在 libglib-2.0(版本未知, 无 pkg-config)"
  else
    skip "GLib: 无法探测(pkg-config/ldconfig 均不可用)"
  fi

  # 图形会话
  SESSION="${XDG_SESSION_TYPE:-unknown}"
  info "图形会话: type=$SESSION wayland=${WAYLAND_DISPLAY:-unset} display=${DISPLAY:-unset}"
  if [ "$SESSION" = "wayland" ] && [ -z "${DISPLAY:-}" ]; then
    info "提示: Wayland 会话且无 DISPLAY, xdotool 类 X 工具可能拿不到窗口信息(不算失败)"
  fi

  # 音频后端
  if command -v pactl >/dev/null 2>&1 && pactl info >/dev/null 2>&1; then
    SERVER=$(pactl info 2>/dev/null | sed -n 's/^Server Name: *//p')
    info "音频后端: ${SERVER:-pulse/pipewire(pactl 可用)}"
  elif [ "$(uname -s)" = "Linux" ]; then
    if pgrep -x pipewire >/dev/null 2>&1; then info "音频后端: pipewire(进程在, 无 pactl)"
    elif pgrep -x pulseaudio >/dev/null 2>&1; then info "音频后端: pulseaudio(进程在, 无 pactl)"
    else skip "音频后端: 无法探测(pactl 缺失, 无 pipewire/pulseaudio 进程)"
    fi
  fi

  echo
  # bundle 校验
  if [ -n "$BUNDLE" ]; then
    BIN="$BUNDLE/minincm"
    if [ ! -x "$BIN" ]; then
      bad "BUNDLE: $BUNDLE/minincm 不存在或不可执行"
    else
      ok "BUNDLE: $BUNDLE"
      # 架构: readelf / file
      if command -v readelf >/dev/null 2>&1; then
        MACH=$(readelf -h "$BIN" 2>/dev/null | sed -n 's/.*Machine: *//p')
        HOST_MACH=$(readelf -h /bin/sh 2>/dev/null | sed -n 's/.*Machine: *//p')
        if [ -n "$MACH" ] && [ "$MACH" = "$HOST_MACH" ]; then
          ok "ARCH: $MACH(与本机一致)"
        elif [ -n "$MACH" ]; then
          bad "ARCH: $MACH 与本机 $HOST_MACH 不一致, 装上跑不起来"
        else
          skip "ARCH: readelf 读取失败"
        fi
      elif command -v file >/dev/null 2>&1; then
        info "ARCH(file): $(file -b "$BIN" | head -c 120)"
      else
        skip "ARCH: readelf/file 均缺失"
      fi
      # GLib 符号基线(思路同 packaging/linux/build-deb.sh): 不许引用 g_once_init_*_pointer
      if command -v nm >/dev/null 2>&1; then
        BADSYMS=$(nm -D --undefined-only "$BIN" 2>/dev/null \
          | grep -oE 'g_once_init_(enter|leave)_pointer' | sort -u || true)
        if [ -z "$BADSYMS" ]; then
          ok "GLIB-SYMBOL: 未引用 g_once_init_*_pointer(2.72 基线 OK)"
        else
          bad "GLIB-SYMBOL: 引用了 $BADSYMS, Ubuntu 22.04 起不来"
        fi
      else
        skip "GLIB-SYMBOL: nm 缺失"
      fi
    fi
  else
    skip "BUNDLE: 未给 BUNDLE=路径, 跳过 bundle 校验"
  fi

  echo
  # DATA 目录
  DATA_DIR="${HOME}/.local/share/ncm"
  if [ -d "$DATA_DIR" ]; then
    if [ -w "$DATA_DIR" ]; then
      ok "DATA-DIR: $DATA_DIR 存在且可写"
    else
      bad "DATA-DIR: $DATA_DIR 存在但当前用户不可写"
    fi
  else
    info "DATA-DIR: $DATA_DIR 不存在(首启会创建; 若已用过应用仍不存在则为异常)"
  fi
}

# ---- --run 段 --------------------------------------------------------------

do_run() {
  echo "===== MiniNCM 桌面冒烟 --run ====="
  if [ -z "$BUNDLE" ]; then
    skip "BUNDLE: 未给 BUNDLE=路径, --run 无从启动(示例: --run BUNDLE=/path/to/bundle)"
    return 0
  fi
  BIN="$BUNDLE/minincm"
  if [ ! -x "$BIN" ]; then
    bad "启动: $BIN 不存在或不可执行"
    return 0
  fi
  if [ "${DISPLAY:-}" = "" ] && [ "${WAYLAND_DISPLAY:-}" = "" ]; then
    skip "图形会话: 无 DISPLAY/WAYLAND_DISPLAY(容器/SSH), --run 优雅跳过"
    return 0
  fi

  mkdir -p "$LOG_DIR"
  LOG="$LOG_DIR/run-$(date +%Y%m%d-%H%M%S).log"

  T0=$(date +%s%3N)
  "$BIN" >"$LOG" 2>&1 &
  APP_PID=$!
  info "启动 $BIN (pid=$APP_PID), 日志: $LOG"

  # 等 RUN_SECONDS 秒: 进程活着即视为启动成功; 可选 --wait-window 用窗口工具确认
  WIN_TOOL=""
  if [ "$WAIT_WINDOW" = "1" ]; then
    if command -v xdotool >/dev/null 2>&1 && [ -n "${DISPLAY:-}" ]; then
      WIN_TOOL="xdotool"
    elif command -v gdbus >/dev/null 2>&1 && [ -n "${DISPLAY:-}" ]; then
      WIN_TOOL="gdbus"
    else
      skip "wait-window: xdotool/gdbus 均不可用或非 X 会话, 退化为进程存活判定"
    fi
  fi

  STARTED_MS=0
  i=0
  while [ $i -lt $((RUN_SECONDS * 10)) ]; do
    if ! kill -0 "$APP_PID" 2>/dev/null; then
      break
    fi
    if [ "$STARTED_MS" = "0" ] && [ "$i" -gt 0 ]; then
      # 进程存活超过 1s 即记录首帧候选耗时(脚本无法直接看 UI, 以进程稳定为准)
      STARTED_MS=$(( $(date +%s%3N) - T0 ))
    fi
    if [ "$WAIT_WINDOW" = "1" ] && [ -n "$WIN_TOOL" ]; then
      if [ "$WIN_TOOL" = "xdotool" ] && xdotool search --name 'MiniNCM\|minincm' >/dev/null 2>&1; then
        STARTED_MS=$(( $(date +%s%3N) - T0 ))
        break
      fi
    fi
    sleep 0.1
    i=$((i + 1))
  done

  ELAPSED=$(( $(date +%s%3N) - T0 ))
  if kill -0 "$APP_PID" 2>/dev/null; then
    ok "进程存活 ${ELAPSED}ms; 首帧候选 ≈ ${STARTED_MS}ms"
    info "注意: debug 包首帧慢是 debug JIT 成本, 该数值仅 release 包作数"
    kill "$APP_PID" 2>/dev/null || true
    sleep 1
    kill -0 "$APP_PID" 2>/dev/null && kill -9 "$APP_PID" 2>/dev/null || true
    wait "$APP_PID" 2>/dev/null || true
    ok "已停止测试进程"
  else
    wait "$APP_PID" 2>/dev/null || true
    bad "进程在 ${ELAPSED}ms 内退出(启动失败?)"
  fi
  echo "----- 日志尾部($LOG) -----"
  if [ -r "$LOG" ] && command -v tail >/dev/null 2>&1; then
    tail -20 "$LOG" || true
  else
    skip "日志尾部: 无法读取"
  fi
  echo "----- 日志尾部结束 -----"
}

# ---- --report 段 -----------------------------------------------------------

do_report() {
  echo "# 桌面冒烟报告(自动段)" 
  echo
  echo "\`\`\`"
  do_env 2>&1 || true
  echo
  do_run 2>&1 || true
  echo "\`\`\`"
  echo
  echo "人工段见 docs/smoke-desktop.md(31 条清单), 逐条 ✅/❌/N/A 后贴回。"
}

parse_args "$@"
case "$MODE" in
  --env)    do_env ;;
  --run)    do_run ;;
  --report) do_report ;;
esac
