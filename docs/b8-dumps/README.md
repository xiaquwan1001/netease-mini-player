# B8 等级/勋章 · 真实响应形状(2026-11-08 实测)

命令(登录态, device=BF448268, uid=1822714196):

```bash
core/target/debug/ncm raw user_level                     # 完整 JSON: user_level.json (343B)
core/target/debug/ncm raw user_medal uid=1822714196      # 完整 JSON: user_medal.json(1.7MB, 原始响应不入库; 这里只留 user_medal.sample.json 抽样)
```

## user_level (`/api/user/level`, weapi, body {})

```json
{"code":200,"data":{"info":"60G音乐网盘免费容量$黑名单上限120$...","level":9,
 "nextLoginCount":350,"nextPlayCount":12000,"nowLoginCount":350,"nowPlayCount":2301,
 "progress":0.19175,"userId":1822714196},"full":false}
```

- `level` = 当前等级 9。
- `nowPlayCount`/`nextPlayCount` = 本等级已听 / 升下一级所需累计听歌数(2301/12000);
  `nowLoginCount`/`nextLoginCount` = 登录天数(350/350,**已满**)。
- `progress` = 0.19175;实测 = 2301/12000 = 0.19175 → **进度按听歌数算**,
  但由于 nowLoginCount 已满级,无法断言 100% 时二者谁封顶。按"听歌数进度"理解。
- `info` = 该等级权益文案,`$` 分隔多条。
- **未实测**: 非法/未登录响应形状(未登录时 vendor 走 weapi 匿名,预计 code=301)。

## user_medal (`/api/medal/user/page`, eapi, body {"uid": ...})

**`uid` 必填**: 不传时 vendor 传空串 → 服务端返回 code=499 "Unknown error"(偶发 http 层错误)。
传本账号 uid 才 200。

data 结构:

```
data.avatar / nickName / canManageWear / medalNum / rankingPer / showGuide / newPageUIAb / useMedalTabs
data.medalTabs             = null(未实测非空形状)
data.musicMedalOperationVO = null
data.categoryMedalBlockVos[] : { categoryCode, categoryId, categoryTitle, desc, medalVOS[] }
data.obtainMedals[]        = 已获得的同一批 medal 对象(与 categoryMedalBlockVos 里 status=OBTAIN 的完全一致)
```

实测 5 个分类共 **200 枚**:

| categoryTitle | 枚数 | status 分布 |
|---|---|---|
| 即将获得 (will_obtain) | 11 | WILL_OBTAIN 11 |
| 成就徽章 (genre_language) | 33 | OBTAIN 16 / NOT_OBTAIN_PROCESS 15 / WILL_OBTAIN 1 / NOT_OBTAIN_NO_PROCESS 1 |
| 乐迷徽章 (categoryCode=null) | 132 | OBTAIN 132 |
| 限定徽章 (challenge) | 18 | OBTAIN 8 / NOT_OBTAIN_NO_PROCESS 9 / WILL_OBTAIN 1 |
| 会员专享 (categoryCode=null) | 6 | OBTAIN 1 / NOT_OBTAIN_NO_PROCESS 4 / NOT_OBTAIN_PROCESS 1 |

- `medalNum` = 157 = status=OBTAIN 的枚数 = obtainTime 非空的枚数 → **medalNum 就是已获得总数**。
- `status` 枚举: `OBTAIN` / `NOT_OBTAIN_PROCESS` / `NOT_OBTAIN_NO_PROCESS` / `WILL_OBTAIN`。
  `OBTAIN` 与 `obtainTime != null` 完全等价(157 对 157),但以 `status == "OBTAIN"` 为准。

### medal 对象(50 个字段,只取 UI 需要的)

非空比例(200 枚):

| 字段 | 非空 | 语义 |
|---|---|---|
| medalCode | 200 | 唯一 id,**字符串**(如 "22086503",乐迷徽章形如 "20170503_1081839") |
| medalName | 200 | 名称(乐迷徽章=艺术家名) |
| medalPicUrl | 200 | 徽章图(方形) |
| wearPic | 200 | 佩戴/横排图 |
| obtainTime | 157 | 获得时间,**毫秒**;未获得为 null |
| status | 200 | 见上枚举 |
| medalPicText | 66 | 图上文字;非乐迷徽章时为 null |
| levelTitle / levelTitleShort | 132 | 等级文本,如 "Lv.4 乐迷" / "Lv.4"(仅乐迷徽章) |
| medalLevel / medalLevelAll | 190 / 180 | 当前级 / 满级(乐迷徽章 4/9) |
| specialMedalType | 132 | `new_fans_level` \| `new_fans_day`;其余 null |
| rankText | 122 | "前0.033%获得该徽章" |
| progress | 28 | **字符串** "当前进度1897/5000"(未获得且有目标) |
| showProgress | 200 | bool |
| descriptionText | 28 | 达成条件补充说明(常为 null) |
| acceptCondition | 200 | 达成条件文案 |
| artistName / centerBasePicUrl | 132 | 乐迷徽章对应艺术家 |
| wearPicV2 | 66 | 新版佩戴图 |
| userObtainProportion / detailPage / sideBarGuideText | 0 | 全 null,不用 |

- 徽章图 url 有 **http://** 与 **https://** 两种,UI 侧要能处理 http(原样透传)。
