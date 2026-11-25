# 雑䁿

雑䁿是一套以 **小鹤双拼 + 墨奇码** 为主的个人 Rime 配置。平时可以只打双拼，遇到重码时直接在音节后加墨奇辅助码。整句输入使用万象词库和语法模型，字词候选结合魔然的固定字词表、PIN 置顶和候选重排。

## 在小狼毫中上手

1. 安装小狼毫。右键小狼毫托盘图标，打开「用户文件夹」，备份现有配置。[小狼毫下载](https://github.com/rime/weasel/releases)
2. 下载或克隆本仓库，把根目录的方案、字典、配置 YAML 文件和 `custom_phrase.txt`，以及 `dicts/`、`lua/`、`opencc/` 按原有层级复制到用户文件夹。保留本机的 `user.yaml`、`installation.yaml` 和 `*.userdb/`。已有同名 `.custom.yaml` 且希望保留原设置时，把所需设置合并到同一个 `patch` 中。
3. 单独下载上游的 `wanxiang-lts-zh-hans.gram`，改名为 `zamo-lts-zh-hans.gram`，放到用户文件夹根目录，与 `zamo_pro.schema.yaml` 同级。[万象语法模型下载](https://github.com/amzxyz/rime-wanxiang-data/releases/tag/LTS)
4. 右键小狼毫托盘图标，选择「重新部署」。在输入框中按 `Ctrl` + 反引号打开方案选单，选择 **雑䁿**。

## 墨奇辅助码

墨奇码按字形拆分，取首末部件的音托。双拼负责读音，墨奇辅助码用来缩小同音候选范围。[墨奇音形文档](https://github.com/gaboolic/moqiyinxing.github.io)

以「好」为例，小鹤双拼是 `hc`，墨奇码是 `nz`。

| 输入 | 用法 |
| --- | --- |
| `hc` | 纯双拼，平时可以照常打词和句子。 |
| `hcn` | 加第一位辅助码 `n`。码表把「好彩年」安排在首选，「好」仍可选。 |
| `hcnz` | 加两位完整辅助码 `nz`，进一步筛选。 |
| `hc9nz` | 用 `9` 指定三声，再加完整辅助码。 |

输入双拼后也可以按 `@` 显示辅助码提示，再补码筛选，例如 `hc@nz`。四个字母被切成两个双拼音节时，可以在两位辅助码后加 `/`，例如 `hcnz/`，再选字上屏。

## 简码和候选

相关编码可以分工。以「好」为例，`hc` 用两码出「好」，`hcn` 把首选留给「好彩年」，知道完整墨奇码时也可用 `hcnz/` 选字。

- 简码由固定字词表提供。自定义短语和 PIN 可按具体编码设置首选。[固定字词表](moran_fixed_simp.dict.yaml) · [自定义短语](custom_phrase.txt)
- 主方案的 Lua 翻译器连接固定码表、整句翻译和动态词频。四码输入既可能是两个双拼音节，也可能是一个带两位辅码的单字。词语的「出简让全」还会结合补码前的首选和按键间隔调整顺序。[主方案配置](zamo_pro.schema.yaml) · [Lua 翻译器](lua/mylua/pseudo_moran.lua)
- 中英混输有独立翻译器，也使用部分带 `/` 的编码。例如 `zip` 的固定首选是「自」，`zip/` 可以输入「7-Zip」。[混输配置](zamo_mixedcode.schema.yaml)

## 常用输入

| 想做什么 | 怎么输入 |
| --- | --- |
| 固定当前首选 | 在中文组字过程中，已有首选候选时按句号 `.`，为首选对应的音节补上大写辅助码。紧接着按退格可恢复原输入。 |
| 拆分或笔画反查 | 从空输入开始，先按反引号，再输入部件或笔画编码。 |
| 按声调筛选 | 在双拼音节后加 `7`、`8`、`9`、`0`，分别对应一至四声。例如 `hc9` 对应三声的「好」。 |

## 自定义

| 想改什么 | 修改入口 |
| --- | --- |
| 候选数量、方案顺序、中英文切换键 | [default.custom.yaml](default.custom.yaml) |
| 主方案的双拼、辅助码、三选键、注释提示 | [zamo_pro.custom.yaml](zamo_pro.custom.yaml) |
| 小狼毫候选窗的字体、字号和布局 | [weasel.custom.yaml](weasel.custom.yaml) |
| 「魔然·字詞」的个人设置 | [moran_fixed.custom.yaml](moran_fixed.custom.yaml) |
| 固定短语 | [custom_phrase.txt](custom_phrase.txt) |
| 自定义超级提示 | [lua/data/tips_user.txt](lua/data/tips_user.txt) |
| 标点、斜杠符号、成对符号和快符 | [zamo_symbols.yaml](zamo_symbols.yaml) |
| 主方案加载的词库 | [zamo_pro.dict.yaml](zamo_pro.dict.yaml) 的 `import_tables`，词库文件在 [dicts/](dicts/) |
| 双拼和辅助码规则 | [zamo_algebra.yaml](zamo_algebra.yaml) |

新增设置时写进对应 `.custom.yaml` 已有的 `patch`，用空格缩进。保留 `7`、`8`、`9`、`0` 作为声调键时，候选数量最多设为 6。保存后重新部署。[Rime 定制指南](https://github.com/rime/home/wiki/CustomizationGuide)

主方案还会加载拆分注释、英文混输和字集过滤等依赖。复制配置时请保留完整的方案与词库文件。`build/` 由部署生成，`*.userdb/` 保存本机用户数据。

## 参考与致谢

- 魔然提供固定字词、PIN 和候选重排机制。[rime-moran](https://github.com/rimeinn/rime-moran)
- 雜然提供固定字词与整句候选并用的实现参考。[zaran](https://github.com/LightGuOne/zaran) · [拼写规则](https://github.com/LightGuOne/zaran/blob/main/zaran_algebra.yaml#L36-L49)
- 万象提供主方案所用的词库与语法模型。[万象拼音](https://github.com/amzxyz/rime-wanxiang) · [万象词库与模型](https://github.com/amzxyz/rime-wanxiang-data)
