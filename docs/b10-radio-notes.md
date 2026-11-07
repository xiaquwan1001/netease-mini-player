# B10 电台补充(只读) · 实测笔记(2026-11-09)

> 用 `ncm raw <method> k=v`(本批给 CLI raw 分支补了 10 个接线)实测;登录态 = 本机已登录账号,匿名 = 空 NCM_DATA_DIR。
> 全部接口匿名都通(无登录门槛);所有调用均为只读 GET/查询,不做任何写操作。

## 实测响应形状

### dj_catelist(`/api/djradio/category/get`, weapi, 无入参)
```json
{"categories":[{"id":3,"name":"情感","pic56x56Url":"https://…","pic56x56IdStr":"…","picWebUrl":"https://…",…}]}
```
- **顶层直接 `categories` 数组,没有 `code`**(不查 code,判断空数组即可)。
- 每类 10 个 pic 字段,实际只用 `id/name/pic56x56Url`(有 https)。
- 匿名/登录形状一致。

### dj_category_recommend(`/api/djradio/home/category/recommend`, weapi, 无入参)
```json
{"code":200,"data":[{"categoryId":3,"categoryName":"情感","radios":[
  {"id":526564706,"name":"伴听FM","picUrl":"https://…","playCount":6555956,"programCount":18,
   "subCount":0,"subed":false,"lastProgramName":"…","rcmdText":"用小半的我筑温暖的你",
   "radioFeeType":0,"feeScope":0,"alg":"featured","icon":{"type":"text","value":"独家",…}|"icon":null}]}]}
```
- `data` 是**数组**,每项一个分类 + 该分类下 3 个推荐电台。
- `icon` 可为 null(独家标签);radioFeeType 0=免费。
- 匿名也通(返回同一批精选)。

### dj_recommend_type(`/api/djradio/recommend`, weapi, 入参 type=cateId)
- **默认 `type=0` 时 `djRadios` 为空数组**(type=0 不是"全部");传真实分类 id(如 `type=2001` 创作翻唱)才有数据。
```json
{"code":200,"djRadios":[{"id":…,"name":"…","picUrl":"https://…","playCount":…,"programCount":…,
  "subCount":…,"desc":"…","descPicList":[…],"category":"创作翻唱","categoryId":2001,"dj":{…}}],
 "hasMore":false}
```
- 字段与现有 `dj_hot` 形状一致(可复用 DjRadio DTO 的宽松解析);分页字段 `hasMore`(实测 false,推荐接口页很小)。

### dj_toplist(`/api/djradio/toplist`, weapi, 入参 limit/offset/type(0=新/1=热, vendor 把 "new"→0 "hot"→1))
```json
{"code":200,"toplist":[{"rank":1,"lastRank":3,"score":116563,"category":"创作翻唱","categoryId":2001,
  "id":792868378,"name":"一条小团团OvO的翻唱合集","picUrl":"http://…","playCount":131838544,
  "programCount":56,"subCount":456521,"creatorName":"…","dj":{"nickname":"…","avatarUrl":"http://…"},
  "rcmdtext":"…","createTime":…,"radioFeeType":0,"feeScope":0}]}
```
- **顶层 `toplist`**;元素是 DjRadio 超集,`rank/score/lastRank` 是榜单特有。
- `type=hot`(1)也实测通;限 100 条。注意 `rcmdtext` 全小写(不是 rcmdText)。

### dj_toplist_hours(`/api/dj/toplist/hours`, weapi, 入参 limit) · dj_toplist_newcomer(`/api/dj/toplist/newcomer`, limit/offset) · dj_toplist_popular(`/api/dj/toplist/popular`, limit)
```json
{"code":200,"data":{"list":[{"rank":1,"lastRank":2,"id":287921940,"nickName":"开心锤锤",
  "avatarUrl":"http://…","score":3581801,"userFollowedCount":79757,"userType":4,
  "avatarDetail":{"identityIconUrl":"…","identityLevel":1,"userType":4}|"avatarDetail":null,
  "liveId":0,"liveStatus":-1,"mainAuthDesc":"","roomNo":0}]}}
```
- 三个榜**同形状**:`data.list` 里是**主播**(用户)不是电台;字段 `nickName`(驼峰)、`avatarUrl`、`score`。
- newcomer 的条目 `avatarDetail` 常 null;popular 第一名实测是薛之谦(2157万粉)。

### dj_toplist_pay(`/api/djradio/toplist/pay`, weapi, 入参 limit)
```json
{"code":200,"data":{"list":[{"rank":1,"lastRank":1,"id":988499285,"name":"猫小九历险记 | 大型奇幻冒险剧",
  "picUrl":"https://…","creatorName":"奇喵君故事","score":11104632}]}}
```
- 付费精品榜是**电台**不是主播:有 `name/picUrl/creatorName`,无 playCount/programCount。

### dj_program_toplist(`/api/program/toplist/v1`, weapi, 入参 limit/offset)
```json
{"code":200,"toplist":[{"rank":1,"lastRank":3,"program":{"id":…,"name":"…","coverUrl":"https://…",
  "duration":92400,"description":"…","dj":{"nickname":"…"},"commentThreadId":"A_DJ_1_…",
  "createTime":…,"auditStatus":10,…}}]}
```
- 顶层 `toplist`,每项 `{rank,lastRank,program}`,program 与现有 `dj_program` 元素同形状(可复用宽松解析)。

### dj_subscriber(`/api/djradio/subscriber`, weapi, 入参 id(电台id)/limit/offset(用 time=-1 游标)/total=true)
```json
{"code":200,"hasMore":true,"subscribers":[{"userId":1594251132,"nickname":"…","avatarUrl":"http://…",
  "signature":"…","subscribeTime":1793611157940,"userType":0,"gender":1,…}]}
```
- 顶层 `hasMore` + `subscribers`(完整 user 对象);分页游标 vendor 用 `time`(取上一页最后 subscribeTime),不是 offset。

## 匿名 vs 登录
- 10 个接口匿名全部 200 通,字段一致;B10 全部入口**不要求登录**(与 B12 数字专辑相反)。

## 文档口径 vs 实测差异
1. Node 文档说 `dj_recommend_type` 不传 type 也行 —— 实测 type=0 返回空 `djRadios`,必须传真实分类 id。
2. 官方文档把 hours/newcomer/popular 说成"电台榜" —— 实测是**主播(用户)榜**;只有 pay 榜是电台。
3. `dj_toplist` 的 `type` Node 版给 "new"/"hot" 字符串,vendor 映射成 0/1;UI 侧直接传数字语义。
4. `dj_catelist` 无 code 字段,与绝大多数接口不同,解析不能依赖 code==200。
5. `dj_toplist` 元素的推荐语字段是 `rcmdtext`(全小写),与 `dj_category_recommend` 的 `rcmdText`(驼峰)不一致。

## 决策
- 10 个接口全部只读接入。**不做**:`dj_sub`(订阅,写)、`dj_difm_channel_subscribe/unsubscribe`(写,语义未验证)、
  `dj_paygift`(付费礼包,导购性质)、`dj_difm_*` 其余 4 个(私人电台语义未验证,不碰)。
- provider 新增聚合:
  - `radio_categories` → dj_catelist + dj_category_recommend(首页一次拉分类+精选)。
  - `radio_recommend(cate_id)` → dj_recommend_type。
  - `radio_toplist(kind)` → 按 kind 分发 hot/newcomer/pay/popular/hours(主播榜统一 DTO)/program(节目榜)。
  - `radio_subscribers(id)` → dj_subscriber。
- UI:`radio_explore_page.dart` 分类胶囊 → 推荐电台 → 榜单页签;入口 = discover.dart「推荐播客」标题行「更多」。
- CLI:`ncm radio-cats` / `ncm radio-top <kind>` / `ncm radio-sub <id>`。

## 落地与回归(2026-11-09)

| 步骤 | 结果 |
|---|---|
| Rust 单测 | `ncm-service` 83→**89** 全绿(+6: categories 实测形状/缺 categories 兜底、picks 实测/缺 data、toplist radios 实测+pay 形状+lastRank=-1、主播榜实测/缺 data.list、节目榜实测/缺 program 跳过、订阅者实测/空页) |
| CLI | `ncm radio-cats`(19 分类) / `radio-rec 2001`(10 台) / `radio-top popular`(87 条主播) / `radio-top program`(100 条) / `radio-sub 526564706` 全链路实测通过 |
| codegen | `flutter_rust_bridge_codegen generate` 一次成功 + `cargo build -p ncm_ffi` 通过 |
| analyze / test | `dart analyze` 0 error(仅 info); `flutter test` **203 通过 +1 skip 全绿**(新增 radio_explore_page_test 6 例: 首页渲染/分类切换与切回精选/推荐空态+主播榜/错误态可重试/行点击回调/300dp+1.25 不溢出); recommend_view_test 的「更多」计数 2→3(新入口) |
| 设备 | 见下 |

## 设备实测(a36 / emulator-5554, 1080x2400)

| 步骤 | 结果 |
|---|---|
| 入口 | 推荐 → 推荐播客标题行「更多」→ 电台广场页打开 |
| 精选 | 分类胶囊(精选/情感/音乐播客/有声书/脱口秀…) + 各分类精选列表(伴听FM 18集·656万 等), 图片/计数正常 |
| 分类切换 | 点「情感」→ `dj_recommend_type` 拉到「情感」推荐电台 10 条, 标题「情感」推荐电台 |
| 榜单 | 热门(带 rank 角标 1/2/3 高亮, 一条小团团OvO 13184万) / 主播(薛之谦 热度 259万 · 粉丝 2158万) 实测通过 |
| 行点击 | 点精选行 → showPodcastDetail(伴听FM, 18 个节目 · 播放 6555957 次, 节目列表加载) |
| 空态/错误态 | `svc wifi disable + svc data disable` 后进页: 「加载失败: 网络不稳定, 已自动重试仍失败, 请稍后重试」+ 重试按钮; 恢复网络点重试正常回填(截图 /tmp/b10_empty.png → /tmp/b10_retry.png) |

截图: /tmp/b10_explore.png(精选) /tmp/b10_category.png(分类推荐) /tmp/b10_cat_bottom.png(热门榜) /tmp/b10_dj.png(主播榜) /tmp/b10_detail.png(电台详情) /tmp/b10_empty.png(错误态) /tmp/b10_retry.png(重试恢复)

## 改动文件清单
- core/crates/ncm-domain/src/lib.rs: +12 个 Radio* DTO(serde default)
- core/crates/ncm-provider/src/lib.rs: +Capability::RadioExplore + 4 个默认 unsupported 方法
- core/crates/ncm-service/src/netease.rs: +6 个 parse_* + 4 个 provider 实现 + 6 个单测; CAPABILITIES +1
- core/crates/ncm-ffi/src/api.rs: +7 个 DTO + 4 个 FFI 函数(radioExploreHome/radioRecommend/radioToplist/radioSubscribers)
- core/crates/ncm-cli/src/main.rs: raw 分支 +10 接线; 新命令 radio-cats/radio-rec/radio-top/radio-sub; 文件头用法注释
- ui/lib/src/rust/*(codegen 一次) + ui/lib/src/radio_explore_page.dart(新) + ui/lib/src/recommend_view.dart(「更多」入口) + ui/test/radio_explore_page_test.dart(新, 6 例) + ui/test/recommend_view_test.dart(「更多」计数 2→3)

## 遗留
- dj_program_toplist 的节目榜 UI 没放页签(榜单页签只做了 热门/新晋/付费/主播), Rust/FFI/CLI 已通(`ncm radio-top program` 实测 100 条), 后续可加「节目」页签。
- `dj_toplist` 实测返回 100 条且无 hasMore 字段, 未做翻页(够展示)。
- 主播榜行为只读展示, 不跳用户主页(现有 UI 无用户主页路由)。
- `dj_difm_*`(6 个)与 `dj_sub`/`dj_paygift` 判定不做(见上「决策」)。
