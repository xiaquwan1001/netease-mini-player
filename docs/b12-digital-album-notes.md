# B12 数字专辑只读 · 实测笔记(2026-11-09)

> 用 `ncm raw <method> k=v`(本批给 CLI raw 分支补了 4 个接线)实测;登录态 = 本机已登录账号,匿名 = 空 NCM_DATA_DIR。

## 实测响应形状

### digital_album_purchased(`/api/digitalAlbum/purchased`, weapi, 入参 limit/offset, total 固定 true)
登录态:
```json
{"code":200,"total":2,"paidAlbums":[{"albumId":120605500,"albumName":"冀西南林路行",
  "artist":{"id":13223,"name":"万能青年旅店"},"cover":"https://p3.music.126.net/…",
  "paidTime":1638063971559,"boughtCount":1,"sub":false,"channel":0,"valid":99,
  "aliasName":"","transName":null,"fromUser":null,"artists":[…]}]}
```
- **顶层是 `paidAlbums` + `total`**,没有 `data` 包装;分页字段只有 `total`(不是 hasMore/more)。
- `paidTime` 是毫秒时间戳;`boughtCount` 是购买数量;封面字段叫 `cover`(不是 picUrl)。
- 匿名:服务端直接报错(vendor 抛 `Authentication required`,HTTP 301 族)。

### song_purchased(`/api/single/mybought/song/list`, weapi, 入参 limit/offset)
```json
{"code":200,"data":{"count":0,"hasMore":false,"list":[]},"message":""}
```
- `data.{count,hasMore,list}`;本账号没有已购单曲,`list` 元素形状未实测到(宽松取 id/name/artist 常见字段)。

### digital_album_detail(`/api/vipmall/albumproduct/detail`, weapi, 入参 id)
```json
{"code":200,"hasAlbum":true,"boughtCnt":1,"canBuy":true,"vipType":11,
 "album":{"albumId":120605500,"albumName":"冀西南林路行","artistName":"万能青年旅店",
   "artistId":13223,"artistNames":"万能青年旅店","coverUrl":"https://…","coverDocId":"…"},
 "product":{"price":22.0,"pubTime":1608566401510,"saleNum":0,"tags":["独家","无损品质收听＆下载"],
   "descr":[{"resource":"…","type":1}],"buynotes":[…],"albumfee":4,"finished":true},
 "singleSongProductId":5933052,"board":{…}}
```
- 专辑字段在 **`album`**(不是 detail 本体),价格/上架时间/标签在 `product`。
- `descr` 是分段文案数组(`resource`+`type`),`</br>` 是分隔占位,拼简介时要过滤。
- `product.saleNum` 这里恒 0,真实销量走 sales 接口。

### digital_album_sales(实际端点 `/api/vipmall/albumproduct/album/query/sales`, weapi)
- vendor 入参键是 **`albumIds`**(CLI query 键名 `ids`,即 `ncm raw digital_album_sales ids=120605500`)。
```json
{"code":200,"data":{"120605500":1300052}}
```
- `data` 是 **专辑id字符串 → 销量数字** 的 map;不是数组,没有 bizType/limit/offset(工单里的说法与 vendor 不符,以 vendor 为准)。

## 决策
- 4 个接口全部只读;`digital_album_ordering`(下单)不做。
- 分页:`purchased` 用 `total` 与已取条数判没有更多;`song_purchased` 用 `data.hasMore`。
- UI:已购专辑 + 已购单曲两个列表;详情用页内 BottomSheet 展开(封面+价格+销量+标签)。
- 匿名下 purchased/song_purchased 服务端报 auth 错,UI 未登录不显示入口。

## 落地与回归(2026-11-09)

| 步骤 | 结果 |
|---|---|
| Rust 单测 | `ncm-service` 78→83 全绿(+5: purchased 实测形状 / 缺 paidAlbums / song_purchased 分页+空 / detail 实测+缺 product+缺 album 报错 / sales map) |
| CLI | `ncm digital 120605500` / `digital-purchased` / `purchased-songs` / `digital-sales` 全链路实测通过;`digital-sales` 实测返回 1300053(销量每天在涨) |
| codegen | `flutter_rust_bridge_codegen generate` 一次成功 + `cargo build -p ncm_ffi` 通过(content hash 一致) |
| analyze / test | `flutter analyze --no-fatal-infos` 28 条全 info、0 error 0 warning;`flutter test` 192 通过 +1 skip 全绿(新增 digital_album_page_test 5 例:空态/列表/错误态/BottomSheet/窄屏 300dp+1.25 字号) |
| 设备 | a36(5554) 走查:我的页 → 「数字专辑(只读)」→ 已购 2 张(伍六七 2023-06-17 / 冀西南林路行 2021-11-28)→ BottomSheet 详情(¥22.0 · 独家/无损 · 销量 130.0万 · 简介)。截图 `/tmp/b12_purchased.png`、`/tmp/b12_detail.png` |
| 未登录 | 入口按 `widget.loggedIn` 过滤不显示;provider 侧另有 MUSIC_U 检查兜底(auth 错误) |

## 遗留
- `song_purchased` 本账号 list 为空,元素真实形状未实测(DTO 字段已做两种命名兼容,等有已购单曲的账号再核)。
- `tools/build-android.sh` 在本机报 `BUILD FAILED in 1s`(疑似 gradle/环境收口问题);本批改用 `cd ui && flutter build apk --debug` 构建,产物可装可用;ci.sh 收口由编排者复核。
