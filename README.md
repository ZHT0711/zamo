# 我的 Rime 配置

当前保留「魔然固定」「万象专业版」「万象反查」「英文」四个选单方案，以及它们所需的依赖。主方案沿用 **小鹤双拼 + 直接辅助**，PIN 代码和现有词库保留。

## 以后主要改这些文件

| 想改什么 | 修改入口 |
| --- | --- |
| 候选数量、方案顺序、中英文切换键 | [default.custom.yaml](default.custom.yaml) |
| 主方案双拼、辅助码、三选键、注释提示 | [wanxiang_pro.custom.yaml](wanxiang_pro.custom.yaml) |
| 小狼毫字体、大小等外观 | [weasel.custom.yaml](weasel.custom.yaml) |
| 魔然固定方案的个人补丁 | [moran_fixed.custom.yaml](moran_fixed.custom.yaml) |
| 固定短语 | [custom_phrase.txt](custom_phrase.txt) |
| 自定义超级提示 | [lua/data/tips_user.txt](lua/data/tips_user.txt) |
| 符号映射 | [wanxiang_symbols.yaml](wanxiang_symbols.yaml) |
| 主方案加载哪些词库 | [wanxiang_pro.dict.yaml](wanxiang_pro.dict.yaml) 的 `import_tables`，对应 [dicts/](dicts/) |
| 双拼和辅助码规则的具体定义 | [wanxiang_algebra.yaml](wanxiang_algebra.yaml) |

优先改 `.custom.yaml` 中 `patch:` 下的项目。例如主方案的 `force_upper_aux/hotkey: period` 表示句号固定候选。新增补丁时写在已有 `patch:` 内，不要再加第二个 `patch:`。保留 YAML 的空格缩进，不使用 Tab。当前候选数量不要超过 6，数字 7890 用于声调。

保存后右键小狼毫托盘图标，选择「重新部署」。也可以在本目录打开 PowerShell，运行：

```powershell
.\tools\deploy.ps1
```

Lua 改动也需要重新部署。短语、提示数据分别沿用现有文件中的行格式；修改提示数据后重新部署即可刷新。

## 目录怎么分

```text
*.custom.yaml          常用个人设置
*.schema.yaml          方案本体及依赖，进阶修改时再看
*.dict.yaml            字典入口
dicts/                 实际使用的分包词库
lua/mylua/             个人功能：辅助码、V 计算器、分段上屏、反查与注释等
lua/wanxiang/          万象公共工具、按键处理、提示、过滤器
lua/moran/             魔然功能、重排、PIN 等
lua/lib/               必要的位运算与旧路径兼容入口
lua/data/              超级提示的默认数据和个人数据
lua/aux_code/          辅助码原始数据
opencc/                方案实际引用的转换与映射数据
tools/                 重新部署入口
build/                 自动生成的编译结果
*.userdb/              使用中的用户词库、PIN、提示缓存等数据库
```

公共函数统一维护在 `lua/wanxiang/wanxiang.lua`，数据库包装统一维护在 `lua/wanxiang/userdb.lua`。`lua/wanxiang.lua` 和 `lua/lib/userdb.lua` 是兼容旧 `require` 路径的小入口，保留它们即可。PIN 实现在 `lua/moran/moran_pin.lua`，本次没有修改。

根目录保留了 Rime 需要直接定位的方案、字典和公共配置。七个 schema 中，`wanxiang_mixedcode`、`wanxiang_chaifen`、`moran_charset` 是依赖方案，不能因它们不在选单中而删除。

`build/`、`*.userdb/`、`user.yaml`、`installation.yaml` 是编译结果或本机状态，不作为日常修改入口。尤其不要手动编辑数据库。`wanxiang-lts-zh-hans.gram` 是实际启用的语言模型，需要保留。

`.ignore` 让常用代码搜索跳过运行数据；`.gitignore` 阻止以后新产生的数据进入版本管理。它不会移除 Git 中已经跟踪的文件，本次也没有改动 Git 索引。

## 本次精简及恢复

整理时间：2026-10-17。移出未引用的 Lua、旧日文模块、重复字典、旧模板、停用数据库与英文方案的旧编译结果，共 1926 个文件、约 108 MiB；四个选单方案及现用数据库保留。

完整备份（包括原 Git 目录和用户词库）：

```text
E:\Rime-backups\directory-cleanup-20261017-204632\full
```

移出的文件按原相对路径归档在：

```text
E:\Rime-backups\directory-cleanup-20261017-204632\archive
```

该备份目录中的 `cleanup-plan.json` 记录移出路径及文件校验值。需要恢复某项功能时，从 `archive` 按原路径复制回本目录，再检查方案里的引用并重新部署。恢复数据库或整目录前先退出小狼毫，避免文件占用；日常修改只需按上表找到对应文件。

Rime 的补丁机制可参考[官方定制指南](https://github.com/rime/home/wiki/CustomizationGuide)。
