# 万象 pro(wanxiang_pro)性能检测报告(Windows / 小狼毫)

- 测试日期:2026-10-17  |  引擎:小狼毫 0.17.4 自带 librime 1.17.0(rime.dll)
- 硬件:AMD Ryzen 7 H 260(8C/16T)/ 31.3 GB RAM / Win10 (10.0.26200)
- 方法:基于 [Carlson24/librime-custom PROFILING.md](https://github.com/Carlson24/librime-custom/blob/master/PROFILING.md) 的思路做的 Windows 等效实现。
  Linux 方案用带插桩的 librime + LD_PRELOAD 收集每组件耗时;Windows 上小狼毫不便于换 DLL,改为用 Python ctypes 直驱小狼毫自带的 rime.dll,
  在 E:\Rime 的完整副本上模拟小鹤双拼整句打字,逐键测量 `ProcessKey`(引擎全路径:分词→翻译器→语法→过滤器)与 `GetContext`(候选菜单/注释求值)。
  指标口径与原方案报告一致:P50/P95/P99、慢键 Top、按输入长度分组、组件差分归因。
- 键序:已用编译好的 prism 逐组合验证的双拼映射(hc=好、bn=表、bk=并、zz=走、ul=双 等),
  并非标准小鹤(ao→c、iao→n、ing/uai→k、ou→z、in→b、ian→m 与经典小鹤不同,以万象 algebra 为准)。
- 每组测试:8 个日常句子(4~13 字)+ 1 个 22 字长句 × 4 轮,共 896 次计时按键。测试目录为副本,不影响真实用户数据。

## 一、总体结果

| 配置 | 每键 P50 | P95 | P99 | max | >25ms 尖峰占比 | 首选命中率* |
|---|---|---|---|---|---|---|
| 基线(当前配置,全部组件) | 11.1 ms | 39.7 ms | 52.8 ms | 60.0 ms | 18.5% | 24/36 |
| 去掉语法模型(.gram) | 10.9 ms | 40.7 ms | 50.5 ms | 60.6 ms | 17.7% | 16/36 |
| 去掉 7 个 simplifier(opencc) | 11.2 ms | 42.2 ms | 51.1 ms | 61.5 ms | 17.3% | 24/36 |
| 去掉 8 个 Lua 处理器 | 12.0 ms | 46.8 ms | 57.0 ms | 65.1 ms | 21.1% | 24/36 |
| 去掉 10 个 Lua 过滤器 | 8.1 ms | 33.3 ms | 46.0 ms | 51.2 ms | 11.6% | 24/36 |
| 去掉 5 个 Lua 翻译器 | 218 µs | 1.4 ms | 2.2 ms | 2.9 ms | 0.0% | 0/36 |
| 去掉全部 23 个 Lua 组件 | 6 µs | 69 µs | 175 µs | 413 µs | 0.0% | 0/36 |
| 只去掉 lua_translator moran_english | 11.6 ms | 41.9 ms | 51.2 ms | 60.4 ms | 18.0% | 24/36 |
| 只去掉 lua_translator pseudo_moran | 286 µs | 1.2 ms | 1.8 ms | 2.8 ms | 0.0% | 0/36 |
| 只去掉 lua_translator mixed_V | 11.1 ms | 41.6 ms | 50.0 ms | 54.9 ms | 17.5% | 24/36 |
| 只去掉 lua_translator unicode | 10.9 ms | 42.2 ms | 51.7 ms | 66.0 ms | 18.9% | 24/36 |
| 只去掉 lua_translator panacea(PIN) | 11.4 ms | 43.8 ms | 52.4 ms | 61.1 ms | 18.4% | 24/36 |

\* 首选命中率 = 空格上屏文本与预期完全一致的比例。测试未用墨奇辅助码消歧,
同音歧义(如 吃/出、元音/原因)按引擎默认排序计,反映纯双拼整句的最坏情况,不代表你日常输入质量。

**基线:每键中位 11.1 ms,P95 39.7 ms,最长 60.0 ms。**
作为参照:去掉全部 Lua 后引擎原生路径仅 P50=6 µs(三个数量级的差距);
上屏(空格提交)本身很便宜:P50=159 µs;`GetContext`(菜单/注释)P50=64 µs —— 全部重活都在 `ProcessKey` 内部。

## 二、组件差分归因

| 组件组 | 拿掉后 P50 | 结论 |
|---|---|---|
| 语法模型 wanxiang-lts-zh-hans.gram(401MB) | 10.9 ms | ≈0(11.1→10.9ms),语法几乎免费,但拿掉后整句命中率 24→16 |
| 7 个 simplifier(emoji/简繁/中英/拼音提示等 opencc) | 11.2 ms | ≈0(11.1→11.2ms),opencc 过滤器链不是瓶颈 |
| 8 个 Lua 处理器 | 12.0 ms | ≈0(反而 12.0ms,噪声内) |
| 10 个 Lua 过滤器 | 8.1 ms | 约 3ms(11.1→8.1ms),占 27% |
| 5 个 Lua 翻译器 | 218 µs | **≈10.9ms(11.1→0.22ms),占 98% —— 主要瓶颈** |
| 全部 23 个 Lua 组件 | 6 µs | 11.1ms→6µs,引擎原生路径极快 |

### 元凶:lua_translator `pseudo_moran`(mylua/pseudo_moran.lua,魔然翻译器 zaran 万象改造版)

5 个 Lua 翻译器逐个切除,只有去掉 `pseudo_moran` 时延迟崩塌式下降:
P50 11.1ms → **286 µs**,P95 39.7ms → **1.2 ms**,max 60ms → **2.8 ms**;其余 4 个(moran_english / mixed_V / unicode / panacea)单独去掉均无变化(≈基线)。

该翻译器每键开销的来源(见 `E:\Rime\lua\mylua\pseudo_moran.lua`):

1. `top.func` 里 `env.smart`(= `script_translator@frequency`,挂 wanxiang_pro 95MB 词表+语法)
   每键全量查询,并且 `for cand in smart_iter` **把整个候选流迭代到枯竭**,而不是只算第一页(第 317、324 行);
   整句模式下还要 `while ... type == "sentence"` 收集全部句子候选(第 302 行)。
2. `top.wanxiangOutput` 再用 `env.fixtranslator`(= `script_translator@translator`,同一个 95MB 词表)
   **重复查询同一输入**(第 375-382 行)。即同一按键最多触发 3 次全量词典翻译:引擎自身 1 次 + smart 1 次 + fixtranslator 1 次。
3. `env.fixed`(码表)查询在长句时也全量迭代(第 210-213 行),外加每键 `collectgarbage("step")`(第 157 行)。

## 三、延迟随输入长度的增长(整句输入的代价)

| 已输入键数(≈2键/字) | 基线 P50 | 基线 P95 | 去掉 pseudo_moran 后 P50 |
|---|---|---|---|
| 2 键(≈1字) | 5.8 ms | 9.3 ms | 1.2 ms |
| 4 键(≈2字) | 3.5 ms | 10.7 ms | 324 µs |
| 6 键(≈3字) | 4.5 ms | 9.4 ms | 242 µs |
| 8 键(≈4字) | 5.2 ms | 15.1 ms | 227 µs |
| 10 键(≈5字) | 8.9 ms | 20.3 ms | 240 µs |
| 12 键(≈6字) | 11.4 ms | 23.1 ms | 257 µs |
| 14 键(≈7字) | 10.7 ms | 22.9 ms | 229 µs |
| 16 键(≈8字) | 13.5 ms | 34.0 ms | 259 µs |
| 18 键(≈9字) | 14.8 ms | 33.4 ms | 269 µs |
| 20 键(≈10字) | 15.0 ms | 28.7 ms | 240 µs |
| 22 键(≈11字) | 15.4 ms | 30.8 ms | 257 µs |
| 24 键(≈12字) | 28.5 ms | 50.2 ms | 296 µs |

短句(≤4 字)每键 3.5~5.2ms,体感无碍;**12 字以上长句后段每键 28~60ms,快速连打会出现可感知的跟手性下降**。
增长主因即 pseudo_moran 对整句候选的全量迭代(候选数与句子长度成正比)。

## 四、部署/启动耗时

- 全量重新部署(等价于"重新部署"按钮,重建全部词典):**351 秒**,其中 wanxiang_pro 词表(95MB)编译为大头;单独重编译 wanxiang_pro 一个方案实测约 33~46 秒(各组测试的 warm_start 一致复现)。
- 数据无变化时的增量维护:**15 ms**(无感)。
- 热启动(引擎初始化+增量维护,引擎侧):~10ms;不含前端 UI 加载。

## 五、建议(按收益排序)

1. **优化或限制 pseudo_moran 的全量迭代**——只需让 smart/fixtranslator 的候选流在产出首页候选后停止(如迭代上限=页大小×2),
   预计把整句每键延迟从 28~60ms 压到 1~3ms 量级。该文件头部标注上游为 ksqsf/Project Moran 0.12.2、zaran 为万象做的改造,
   可关注万象/魔然上游是否已有性能修复版本;若自己改,注意 `wanxiangOutput` 与 smart 的重复查询可合并或缓存。
2. Lua 过滤器组(10 个)合计 ~3ms/键,其中如 super_comment/aux_code 类每候选扫描的过滤器,
   若整句场景用不到,可按 tag 或输入长度条件降载(如长句时跳过部分过滤器)。
3. 语法模型与 opencc 过滤器链开销可忽略,保持现状即可;整句质量(命中率)恰恰依赖语法,不要为提速去掉它。
4. 部署 350 秒来自词表体量,属一次性成本;平时用增量维护(15ms)无感,避免不必要的"重新部署"。
5. 首选命中 24/36 是纯双拼无辅助码的最坏情况;配合墨奇码辅助码(本测试未模拟)即为你日常的真实体验。

## 六、复现方式

```
# 脚本位于 C:\rime-perf\(测试工作区为 E:\Rime 的 robocopy 副本,不触碰原数据)
python rime_bench.py bench  <工作区> <输出.json>   # 模拟打字并逐键计时
python rime_bench.py deploy <工作区> <输出.json>   # 全量部署计时
python probe_cand.py <工作区> <标签> [nomaint]     # 候选内容探针
python make_report.py                              # 重新生成本报告
```

### 与 Linux 原方案的差异说明

- 原方案:自编译 ENABLE_PROFILING=ON 的 librime + LD_PRELOAD 注入 fcitx5,拿到**组件级插桩耗时**与按键事件日志。
- 本报告:直驱小狼毫自带 rime.dll(未编译插桩版),用**组件差分法**(逐组摘除组件测差值)达到同样的归因效果;
  指标口径(P50/P95/P99/尖峰/按长度分组)与原方案 `profile_report.py` 一致。
- 未覆盖:小狼毫前端 UI 绘制开销、墨奇辅助码路径、英文方案 wanxiang_english。如需组件级精确插桩(而非差分),
  仍需按原方案自编译 librime(需安装 VS2022 构建工具+替换 weasel 目录 rime.dll,可另行进行)。
