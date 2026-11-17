import re
import sys

# 断言口径见 .pi/memory/media-notification-custom-buttons.md:
#   上一首 -> 播放/暂停 -> 下一首 -> 喜欢/取消喜欢 -> 播放顺序
EXPECTED = [
    (0, "上一首", ("上一首", "上一曲", "Previous")),
    (2, "下一首", ("下一首", "Next")),
    (3, "喜欢/取消喜欢", ("喜欢", "取消喜欢", "Like", "Unlike")),
    (4, "播放顺序", ("播放顺序", "Playback mode")),
]
CUSTOM_TITLES = {"上一首", "上一曲", "下一首", "喜欢", "取消喜欢", "播放顺序"}


def main():
    path = sys.argv[1]
    pkg_want = sys.argv[2] if len(sys.argv) > 2 else ""
    text = open(path, encoding="utf-8", errors="replace").read()

    # 记录按 AOSP NotificationRecord.dump 的排版切块:
    #   NotificationRecord(0x..: pkg=<pkg> user=0 id=1001 tag=null importance=2 key=.. : Notification(channel=.. actions=5 ..))
    #     ...
    #     notification=
    #         [i] "<title>" -> PendingIntent{...}
    starts = list(re.finditer(r"^\s*NotificationRecord\(", text, re.M))
    blocks = []
    for i, m in enumerate(starts):
        end = starts[i + 1].start() if i + 1 < len(starts) else len(text)
        blocks.append(text[m.start():end])

    records = []
    for b in blocks:
        head = b.splitlines()[0] if b.splitlines() else ""
        pkg = re.search(r"pkg=(\S+)", head)
        chan = re.search(r"channel=(\S+)", head)
        imp = re.search(r"importance=(-?\d+)", head)
        title = re.search(r"android\.title=String \((.*)\)", b)
        acts = [(int(n), t) for n, t in
                re.findall(r"^\s*\[(\d+)\] \"([^\"]*)\" ->", b, re.M)]
        compact = re.search(
            r"android\.compactActions=int \((\d+)\)\n((?:\s*\[\d+\] -?\d+\n)+)", b)
        compact_idx = None
        if compact:
            compact_idx = [int(x) for x in re.findall(r"\[\d+\] (-?\d+)", compact.group(2))]
        large_icon = re.search(r"android\.largeIcon=Bitmap \((\d+)x(\d+)\)", b)
        records.append(dict(
            pkg=pkg.group(1) if pkg else "?",
            channel=chan.group(1) if chan else "?",
            importance=int(imp.group(1)) if imp else None,
            title=(title.group(1) if title else "?"),
            actions=[t for _, t in acts],
            compact=compact_idx,
            large_icon=(int(large_icon.group(1)), int(large_icon.group(2))) if large_icon else None,
        ))

    npass = 0
    nfail = 0

    def check(ok, msg, detail=""):
        nonlocal npass, nfail
        if ok:
            npass += 1
            print("PASS  " + msg)
        else:
            nfail += 1
            print("FAIL  " + msg + (("  [" + detail + "]") if detail else ""))

    cands = [r for r in records if r["actions"] and (not pkg_want or r["pkg"] == pkg_want)]
    if not cands:
        print("FAIL  没找到带 action 的通知记录" +
              ("(pkg=" + pkg_want + ")" if pkg_want else "") +
              " —— 先确认 App 正在播放, 且 Android 13+ 已授予 POST_NOTIFICATIONS")
        return 1

    print("# 共 %d 条通知记录, 取第一条带 action 的:" % len(records))
    rec = cands[0]
    print("#   pkg=%s  title=%s  channel=%s  importance=%s  actions=%d"
          % (rec["pkg"], rec["title"], rec["channel"], rec["importance"], len(rec["actions"])))

    titles = rec["actions"]
    print("# 实际按钮: " + " -> ".join(titles))
    check(rec["channel"] == "default_channel_id",
          "通知渠道 = default_channel_id(Media3 默认)", rec["channel"])
    check(rec["importance"] == 2,
          "渠道 importance = IMPORTANCE_LOW(2)", str(rec["importance"]))
    check(len(titles) == 5, "action 数量 = 5", str(len(titles)))
    if len(titles) >= 5:
        for idx, name, allowed in EXPECTED:
            check(titles[idx] in allowed, "第 %d 位 = %s" % (idx + 1, name), titles[idx])
        check(titles[1] not in CUSTOM_TITLES,
              "第 2 位是系统 play/pause 槽(不是自定义按钮)", titles[1])
        check(titles.count("下一首") == 1,
              "「下一首」只出现一次(没被顶成重复槽)", "x%d" % titles.count("下一首"))
    if rec["compact"] is not None:
        check(rec["compact"] == [0, 1, 2], "compactActions = [0,1,2](锁屏紧凑视图)",
              ",".join(map(str, rec["compact"])))
    else:
        print("INFO  没解析到 compactActions(该 ROM 可能不 dump 这个 extra)")
    if rec["large_icon"]:
        print("INFO  封面 largeIcon = %dx%d" % rec["large_icon"])
    else:
        print("INFO  无 largeIcon(无封面或未解析到) —— 不算槽位失败")

    print()
    print("== %d PASS / %d FAIL ==" % (npass, nfail))
    return 1 if nfail else 0


if __name__ == "__main__":
    sys.exit(main())
