#!/usr/bin/env bash
# 门禁: 测试代码里不得直连"写类"桥接接口.
#
# 背景(docs/remaining-batches.md §11.C1「评论发送写操作走查」):
# 评论/点赞/转发/分享/歌单写都是**真实副作用**, CI 一旦真的打到网易云就等于拿仓库
# 去写线上数据。仓库做法是全部通过注入的假钩子(CommentSendHook / SongActionHost /
# likeEvent 参数 ...), 测试里不出现直连写接口的调用。
#
# 这个脚本把"靠自觉"变成"能被 CI 拦住": ui/test/** 里一旦出现对写接口的直接调用就失败。
# 读类接口(搜索/详情/歌词)不拦 —— 那是离线 mock 或 @Tags(['network']) 白名单。
set -euo pipefail
cd "$(dirname "$0")/.."

# 写类桥接函数(ncm-ffi/src/api.rs 里的 pub async fn).
WRITE_APIS='replyComment|deleteComment|likeComment|likeEvent|forwardEvent|forwardMessage|shareResource|createPlaylist|playlistTracksAdd|reportComment|signin|logout'

fail=0
if hits=$(grep -rnE "rust\\.(${WRITE_APIS})\\b" ui/test 2>/dev/null); then
  echo "::error::测试里出现直连写接口(必须注入假钩子, 见 tools/check-write-guard.sh 头部说明):"
  echo "$hits"
  fail=1
else
  echo "OK: ui/test/** 没有直连写接口(评论/点赞/转发/分享/歌单写全部走注入钩子)"
fi

# 带 network 标签的测试也不许碰写接口(它们会真的发请求).
if hits=$(grep -rlE "@Tags\\(\\[.network.\\]\\)" ui/test 2>/dev/null | xargs -r grep -nE "rust\\.(${WRITE_APIS})\\b" 2>/dev/null); then
  echo "::error::@Tags(['network']) 的测试不允许调写接口:"
  echo "$hits"
  fail=1
fi

if [ "$fail" != 0 ]; then
  echo "门禁失败: 写操作必须走注入的假实现, CI 不触网."
  exit 1
fi
echo "write-guard OK"
