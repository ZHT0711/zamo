--@namzxyz https://github.com/amzxyz/rime_wanxiang
-- 2026-10-17: 静态拆分词典采用有界正/负结果缓存。

local wanxiang = require('wanxiang')

local tone_map = {
    ['ā']='a', ['á']='a', ['ǎ']='a', ['à']='a',
    ['ē']='e', ['é']='e', ['ě']='e', ['è']='e',
    ['ī']='i', ['í']='i', ['ǐ']='i', ['ì']='i',
    ['ō']='o', ['ó']='o', ['ǒ']='o', ['ò']='o', ['ň']='n',
    ['ū']='u', ['ú']='u', ['ǔ']='u', ['ù']='u', ['ǹ']='n',
    ['ǖ']='ü', ['ǘ']='ü', ['ǚ']='ü', ['ǜ']='ü', ['ń']='n',
}

-- **辅助码角标映射表**
local superscript_map = {
    a = "ª", b = "ᵇ", c = "ᶜ", d = "ᵈ", e = "ᵉ", f = "ᶠ", g = "ᵍ",
    h = "ʰ", i = "ⁱ", j = "ʲ", k = "ᵏ", l = "ˡ", m = "ᵐ", n = "ⁿ",
    o = "ᵒ", p = "ᵖ", q = "𐞥", r = "ʳ", s = "ˢ", t = "ᵗ", u = "ᵘ",
    v = "ᵛ", w = "ʷ", x = "ˣ", y = "ʸ", z = "ᶻ",
    ["/"] = "⸝", [" "] = " "
}

local function remove_pinyin_tone(s)
    if not s:find('[\128-\255]') then return s end
    local result = {}
    for uchar in s:gmatch("[%z\1-\127\194-\244][\128-\191]*") do
        result[#result + 1] = tone_map[uchar] or uchar
    end
    return table.concat(result)
end

-- ----------------------
-- # 辅助码拆分提示模块
-- PRO 专用
-- ----------------------
local CF = {}
function CF.init(env)
    if wanxiang.is_pro_scheme(env) then -- pro 版直接初始化
        CF.get_dict(env)
    end
end

function CF.fini(env)
    env.chaifen_dict = nil
    env.chaifen_cache = nil
    env.chaifen_queue = nil
    env.chaifen_head = nil
end

function CF.get_dict(env)
    if env.chaifen_dict == nil then
        env.chaifen_dict = ReverseLookup("wanxiang_chaifen")
        env.chaifen_cache = {}
        env.chaifen_queue = {}
        env.chaifen_head = 1
    end
    return env.chaifen_dict
end

function CF.get_comment(cand, env)
    local dict = CF.get_dict(env)
    if not dict then return "" end

    local raw = env.chaifen_cache[cand.text]
    if raw == nil then
        raw = dict:lookup(cand.text)
        local queue = env.chaifen_queue
        if #queue < 1024 then
            queue[#queue + 1] = cand.text
        else
            env.chaifen_cache[queue[env.chaifen_head]] = nil
            queue[env.chaifen_head] = cand.text
            env.chaifen_head = env.chaifen_head % 1024 + 1
        end
        env.chaifen_cache[cand.text] = raw and raw ~= "" and raw or false
    end
    if not raw or raw == "" then return "" end

    local settings = env.settings
    if settings.chaifen_left then
        return settings.chaifen_left .. raw .. settings.chaifen_right
    end

    return raw
end

-- ----------------------
-- # 错音错字提示模块
-- ----------------------
local CR = {}
function CR.init(env)
    env.corrections_cache = nil
    if not env.settings.corrector_enabled then return end
    local auto_delimiter = env.settings.auto_delimiter
    local is_pro = wanxiang.is_pro_scheme(env)
    -- 根据方案选择加载路径
    local path = (is_pro and "dicts/cuoyin.pro.dict.yaml") or "dicts/cuoyin.dict.yaml"
    local file, close_file, err = wanxiang.load_file_with_fallback(path)
    if not file then
        log.error(string.format("[super_comment]: 加载失败 %s，错误: %s", path, err))
        return
    end
    local corrections_cache = {}
    env.corrections_cache = corrections_cache
    for line in file:lines() do
        if not line:match("^#") then
            local text, code, weight, comment = line:match("^(.-)\t(.-)\t(.-)\t(.-)$")
            if text and code then
                text = text:match("^%s*(.-)%s*$")
                code = code:match("^%s*(.-)%s*$")
                comment = comment and comment:match("^%s*(.-)%s*$") or ""
                comment = comment:gsub("%s+", auto_delimiter)
                code = code:gsub("%s+", auto_delimiter)
                corrections_cache[code] = { text = text, comment = comment }
            end
        end
    end
    close_file()
end

function CR.get_comment(cand, env)
    local corrections_cache = env.corrections_cache
    local correction = corrections_cache and corrections_cache[cand.comment] or nil
    if not (correction and cand.text == correction.text) then
        return nil
    end
    -- 只认占位符 `comment`，按"刀法"切分
    local left, right = env.settings.corrector_left, env.settings.corrector_right

    if left then
        return left .. correction.comment .. right
    else
        return correction.comment
    end
end

-- ----------------------
-- 部件组字返回的注释unicode
-- ----------------------
local function get_charset_label(text)
    if not text or text == "" then return nil end
    local cp = utf8.codepoint(text)
    if not cp then return nil end

    if cp >= 0x4E00   and cp <= 0x9FFF  then return "基本" end
    if cp >= 0x3400   and cp <= 0x4DBF  then return "扩A" end
    if cp >= 0x20000  and cp <= 0x2A6DF then return "扩B" end
    if cp >= 0x2A700  and cp <= 0x2B73F then return "扩C" end
    if cp >= 0x2B740  and cp <= 0x2B81F then return "扩D" end
    if cp >= 0x2B820  and cp <= 0x2CEAF then return "扩E" end
    if cp >= 0x2CEB0  and cp <= 0x2EBEF then return "扩F" end
    if cp >= 0x2EBF0  and cp <= 0x2EE5F then return "扩I" end
    if cp >= 0x30000  and cp <= 0x3134F then return "扩G" end
    if cp >= 0x31350  and cp <= 0x323AF then return "扩H" end
    if cp >= 0xF900   and cp <= 0xFAFF  then return "兼容" end
    if cp >= 0x2F800  and cp <= 0x2FA1F then return "兼容" end
    return nil
end


local function get_az_comment(cand, env, initial_comment)
    local inner_parts = {}

    if initial_comment and initial_comment ~= "" then
        local segments = {}
        for segment in initial_comment:gmatch("[^%s]+") do
            table.insert(segments, segment)
        end
        local semicolon_count = select(2, (segments[1] or ""):gsub(";", ""))
        local pinyins = {}
        local fuzhu = nil
        for _, segment in ipairs(segments) do
            local pinyin = segment:match("^[^;~]+")
            local fz = nil
            if semicolon_count == 1 then
                fz = segment:match(";(.+)$")
            end
            if pinyin then table.insert(pinyins, pinyin) end
            if not fuzhu and fz and fz ~= "" then fuzhu = fz end
        end

        if #pinyins > 0 then
            local pinyin_str = table.concat(pinyins, ",")
            table.insert(inner_parts, string.format("音%s", pinyin_str))
            if fuzhu then
                table.insert(inner_parts, string.format("辅%s", fuzhu))
            end
        end
    end

    if cand and cand.text then
        local label = get_charset_label(cand.text)
        if label then
            table.insert(inner_parts, label)
        end
    end

    if #inner_parts == 0 then
        return "〔无〕"
    end
    return "〔" .. table.concat(inner_parts, "・") .. "〕"
end


-- ----------------------
-- # 辅助码提示或带调全拼注释模块 (Fuzhu)
-- ----------------------
local function get_fz_comment(cand, env, initial_comment, use_tone)
    local length = utf8.len(cand.text)
    if length > env.settings.candidate_length then
        return ""
    end
    local auto_delimiter = env.settings.auto_delimiter or " "
    local first_segment = initial_comment:match(env.settings.fz_segment_pattern) or ""
    -- 无辅助码时直接返回，避免创建段落数组及二次遍历。
    if not first_segment:find(";", 1, true) then
        return initial_comment:gsub(auto_delimiter, " ")
    end

    local fuzhu_comments = {}
    local extract_pattern = use_tone and "^(.-);" or ";(.+)$"
    for segment in initial_comment:gmatch(env.settings.fz_segment_pattern) do
        local value = segment:match(extract_pattern)
        if value and value ~= "" then
            fuzhu_comments[#fuzhu_comments + 1] = value
        end
    end
    return table.concat(fuzhu_comments, use_tone and " " or "/")
end

local SV = {}

-- 工具：取光标前的编码（安全处理 caret 越界）
local function front_input(ctx)
    if not ctx then return "" end
    local raw_full = ctx.input or ""
    local caret    = ctx.caret_pos or #raw_full
    if caret < 0 then
        caret = 0
    elseif caret > #raw_full then
        caret = #raw_full
    end
    return raw_full:sub(1, caret)
end

-- 这个模块主要用于将滤镜阶段未修改前的注释或者 preedit
-- 存到上下文变量里，按键处理阶段使用；update_notifier 保证一致性
function SV.init(env)
    env._sv_seq_sig          = ""
    env._sv_last_pre         = ""   -- 最近一次要写入的 preedit
    env._saved_input_for_seq = ""   -- 上次对应的 raw_in（光标前编码）

    local ctx = env.engine.context

    env._sv_ctx_conn = ctx.update_notifier:connect(function(c)
        local raw_in = front_input(c)

        local pre = env._sv_last_pre or ""
        if pre == "" or raw_in == "" then
            return
        end

        -- 不重写：光标前编码 + preedit
        local sig = raw_in .. "\t" .. pre
        if env._sv_seq_sig == sig then
            return
        end

        c:set_property("sequence_preedit_key", raw_in)
        c:set_property("sequence_preedit_val", pre)
        env._sv_seq_sig = sig
    end)
end

-- 断开 notifier，清理状态
function SV.fini(env)
    if env._sv_ctx_conn then
        env._sv_ctx_conn:disconnect()
        env._sv_ctx_conn = nil
    end
    env._sv_seq_sig          = nil
    env._sv_last_pre         = nil
    env._saved_input_for_seq = nil
end

-- 限制更新范围：同一个 raw_in 只记第一次的 preedit
function SV.update_preedit(env, preedit, raw_in)
    preedit = preedit or ""

    if raw_in == "" or preedit == "" then
        return
    end

    if env._saved_input_for_seq ~= raw_in then
        env._saved_input_for_seq = raw_in
        env._sv_last_pre         = preedit
    end
end

-- ----------------------
-- # preedit 数字转上标 & force_upper_aux 双大写辅助码隐藏
-- 整合自文件2的 apply_tone_preedit 函数
-- ----------------------
local function apply_tone_preedit(env, cand, skip_tone_preedit)
    if not cand or not cand.preedit or cand.preedit == "" then
        return
    end

    if skip_tone_preedit then return end

    -- 判断首选是否为纯英文（通过匹配是否全由英文字符组成且不含中文）
    if cand.text:match("^[%a%p%s]+$") then
        return
    end

    -- 2. 加载配置
    local aux_symbol = env.settings.aux_symbol

    -- 如果没配置 symbol，直接跳过大写转换逻辑
    if not aux_symbol or aux_symbol == "" then
        goto tone_only
    end

    do
        local preedit = cand.preedit
        -- 3. 核心逻辑：排除前两位是大写的情况，只转换后续出现的双大写
        -- ([A-Z][A-Z]+) 匹配后续连续的两个及以上的大写字母
        local converted = preedit:gsub("^(..?-?)([A-Z][A-Z]+)", function(prefix, upper)
            -- 检查前缀是否包含大写字母。如果前缀里有大写，说明可能是英文输入，不转换
            if prefix:match("[A-Z]") then
                return prefix .. upper
            else
                return prefix .. aux_symbol
            end
        end)

        -- 处理非行首（音节中间或靠后）的双大写
        -- 比如 "nihaoWS" -> "nihao·"
        converted = converted:gsub("([^%s%^])([A-Z][A-Z]+)", function(prev, upper)
            return prev .. aux_symbol
        end)

        cand.preedit = converted
    end
    ::tone_only::
    -- 4. 数字映射逻辑（上标转换）
    local final_pre = cand.preedit:gsub("([^%d%s]+)(%d+)", function(body, digits)
        local mapped = digits:gsub("%d", env.tone_map)
        return body .. mapped
    end)

    cand.preedit = final_pre
end

-- ----------------------
-- 主函数：根据优先级处理候选词的注释和preedit
-- ----------------------
local ZH = {}
function ZH.init(env)
    local config = env.engine.schema.config
    local delimiter = config:get_string('speller/delimiter') or " '"
    local auto_delimiter = delimiter:sub(1, 1)
    local manual_delimiter = delimiter:sub(2, 2)
    local corrector_enabled = config:get_bool("super_comment/corrector")
    if corrector_enabled == nil then corrector_enabled = true end
    env.settings = {
        delimiter = delimiter,
        auto_delimiter = auto_delimiter,
        manual_delimiter = manual_delimiter,
        corrector_enabled = corrector_enabled,
        corrector_type = config:get_string("super_comment/corrector_type") or "{comment}",
        chaifen = config:get_string("super_comment/chaifen") or "〔chaifen〕",
        candidate_length = tonumber(config:get_string("super_comment/candidate_length")) or 1,
    }
    -- 固定配置仅在初始化时读取；选项仍在每次过滤时动态读取。
    local settings = env.settings
    settings.quick_code_indicator = config:get_string("moran/quick_code_indicator") or "⚡️"
    settings.pin_indicator = config:get_string("moran/pin/indicator") or "📌"
    settings.visual_delim = config:get_string("speller/visual_delimiter") or " "
    settings.tone_isolate = config:get_bool("speller/tone_isolate")
    settings.aux_symbol = config:get_string("force_upper_aux/symbol")
    settings.is_wanxiang_pro = (env.engine.schema.schema_id == "wanxiang_pro")
    settings.chaifen_left, settings.chaifen_right = settings.chaifen:match("^(.-)chaifen(.-)$")
    settings.corrector_left, settings.corrector_right = settings.corrector_type:match("^(.-)comment(.-)$")
    settings.fz_segment_pattern = "[^" .. auto_delimiter .. "]+"
    settings.pinyin_segment_pattern = "[^" .. auto_delimiter .. manual_delimiter .. "]+"
    env.tone_map = {}
    for d = 0, 9 do
        local k = tostring(d)
        local v = config:get_string("tone_preedit/" .. k)
        env.tone_map[k] = (v and v ~= "") and v or k
    end
    CR.init(env)
    SV.init(env)
end

function ZH.fini(env)
    -- 清理
    CF.fini(env)
    SV.fini(env)
    env.corrections_cache = nil
    env.tone_map = nil
end

function ZH.func(input, env)
    local settings = env.settings
    local quick_code_indicator = settings.quick_code_indicator
    local pin_indicator = settings.pin_indicator
    local context = env.engine.context
    local input_str = context.input
    local is_radical_mode = wanxiang.is_in_radical_mode(env)
    local is_wanxiang_pro = settings.is_wanxiang_pro
    local should_skip_candidate_comment = wanxiang.is_function_mode_active(context) or input_str == ""
    local is_tone_comment = env.engine.context:get_option("tone_hint")
    local is_comment_hint = env.engine.context:get_option("fuzhu_hint")
    local is_chaifen_enabled = env.engine.context:get_option("chaifen_switch")
    --preedit相关声明
    local auto_delimiter = env.settings.auto_delimiter
    local manual_delimiter = env.settings.manual_delimiter
    local visual_delim = settings.visual_delim
    local tone_isolate = settings.tone_isolate
    local is_tone_display = context:get_option("tone_display")
    local is_full_pinyin = context:get_option("full_pinyin")
    local is_superscript_mode = context:get_option("superscript_fuzhu") -- 辅助码角标模式开关
    local raw_in = front_input(context)
    local skip_tone_preedit = input_str:match("%d%d") ~= nil

    for cand in input:iter() do
        local genuine_cand = cand:get_genuine()
        local preedit = genuine_cand.preedit or ""
        local initial_comment = genuine_cand.comment or ""
        initial_comment = initial_comment:gsub(quick_code_indicator, '')
        initial_comment = initial_comment:gsub(pin_indicator, '')
        local final_comment = initial_comment
        
        SV.update_preedit(env, preedit, raw_in) --储存到环境变量
        
        -- preedit相关处理只跳过 preedit，不影响注释
        if is_radical_mode then
            goto after_preedit
        end
        if not is_tone_display and not is_full_pinyin and not is_superscript_mode then
            goto after_preedit
        end
        if (not initial_comment or initial_comment == "") then
            goto after_preedit
        end
        
        do
            -- 拆分 preedit
            local input_parts = {}
            local segment_start = 1
            for i = 1, #preedit do
                local char = preedit:sub(i, i)
                if char == auto_delimiter or char == manual_delimiter then
                    if i > segment_start then
                        input_parts[#input_parts + 1] = preedit:sub(segment_start, i - 1)
                    end
                    input_parts[#input_parts + 1] = char
                    segment_start = i + 1
                end
            end
            if segment_start <= #preedit then
                input_parts[#input_parts + 1] = preedit:sub(segment_start)
            end

            -- 拆分拼音段（comment）
            local pinyin_segments = {}
            for segment in string.gmatch(initial_comment, settings.pinyin_segment_pattern) do
                local pinyin = segment:match("^[^;]+")
                if pinyin then
                    pinyin = pinyin:gsub("[%[%]]", "")  --去掉英文词库编码中的[]
                    table.insert(pinyin_segments, pinyin)
                end
            end

            -- 替换逻辑
            local pinyin_index = 1
            
            -- **角标模式：前两位拼音，后续转角标**
            if is_superscript_mode then
                for i, part in ipairs(input_parts) do
                    if part == auto_delimiter or part == manual_delimiter then
                        input_parts[i] = visual_delim
                    else
                        if #part >= 2 and pinyin_index <= #pinyin_segments then
                            local first_part = pinyin_segments[pinyin_index]
                            pinyin_index = pinyin_index + 1
                            
                            -- 后续部分转角标
                            local mapped_remaining = part:sub(3):gsub(".", superscript_map)
                            input_parts[i] = first_part .. mapped_remaining
                        end
                    end
                end
            -- **普通模式：原有逻辑**
            else
                for i, part in ipairs(input_parts) do
                    if part == auto_delimiter or part == manual_delimiter then
                        input_parts[i] = visual_delim
                    else
                        local py = pinyin_segments[pinyin_index]

                        if py then
                            if is_wanxiang_pro then
                                input_parts[i] = py
                                pinyin_index = pinyin_index + 1
                            elseif i == #input_parts and #part == 1 then
                                local prefix = py:sub(1, 2)
                                local first_char = part:sub(1,1):lower()
                                if first_char == "s" or first_char == "c" or first_char == "z" then
                                    input_parts[i] = part
                                else
                                    if prefix == "zh" or prefix == "ch" or prefix == "sh" then
                                        input_parts[i] = prefix
                                    else
                                        input_parts[i] = part
                                    end
                                end
                            else
                                if tone_isolate then
                                    local _, tone = part:match("([%a]+)([^%a]+)")
                                    input_parts[i] = py .. (tone or "")
                                else
                                    input_parts[i] = py
                                end
                                pinyin_index = pinyin_index + 1
                            end
                        end
                    end
                end
            end

            if is_full_pinyin then
                for idx, part in ipairs(input_parts) do
                    input_parts[idx] = remove_pinyin_tone(part)
                end
            end

            genuine_cand.preedit = table.concat(input_parts)
        end
        ::after_preedit::

        if should_skip_candidate_comment then
            yield(genuine_cand)
            goto continue
        end

        -- 应用 force_upper_aux 双大写隐藏 & 数字转上标（统一入口，替代原内联逻辑）
        apply_tone_preedit(env, genuine_cand, skip_tone_preedit)
        
        -- 添加对空字符串候选词的检查，跳过注释处理
        if not cand.text or cand.text == "" then
            yield(genuine_cand)
            goto continue
        end
        
        -- 进入注释处理阶段
        -- ① 辅助码注释或者声调注释
        if is_comment_hint or is_tone_comment then
            final_comment = get_fz_comment(cand, env, initial_comment, is_tone_comment)
        else
            final_comment = ""
        end

        -- ② 拆分注释
        if is_chaifen_enabled then
            local cf_comment = CF.get_comment(cand, env)
            if cf_comment and cf_comment ~= "" then  --不为空很重要
                final_comment = cf_comment
            end
        end

        -- ③ 错音错字提示
        if env.settings.corrector_enabled then
            local cr_comment = CR.get_comment(cand, env)
            if cr_comment and cr_comment ~= "" then
                final_comment = cr_comment
            end
        end

        -- ④ 反查模式提示
        if is_radical_mode then
            local az_comment = get_az_comment(cand, env, initial_comment)
            if az_comment and az_comment ~= "" then
                final_comment = az_comment
            end
        end

        -- ⑤ 保留~标记并转换为|（优先级高于魔然提示）
        if initial_comment and (string.find(initial_comment, "~") or string.find(initial_comment, "\226\152\175")) then
            -- 将~或☯转换为|
            local converted_comment = initial_comment:gsub("~", " "):gsub("\226\152\175", " ")
            final_comment = converted_comment
        end

        -- ⑥ 魔然提示
        -- 处理用户标记
         if cand.type == "fixed" then                            -- 魔然简表
             final_comment = final_comment .. quick_code_indicator
         elseif cand.type == "user_phrase" then                  -- 用户字典（自造词）
             final_comment = final_comment  .. ""
         elseif cand.type == "user_table" then                         -- table
             final_comment = final_comment .. ""
         elseif cand.type == "pinned" then                       -- 魔然pin词
             final_comment = final_comment .. pin_indicator
         elseif cand.type == "down" then                         -- 魔然ijrq
             final_comment = final_comment .. ""
         elseif cand.type == "aux" then                         -- 魔然词辅
             final_comment = final_comment .. "󰚔"
         elseif cand.type == "sentence" then                         -- 万象句子
             final_comment = final_comment .. "󱙻"
         elseif cand.type == "pin_tip" then                       -- 魔然pin造词
             final_comment = "開始加詞" .. pin_indicator
         elseif cand.type == "model" then                        -- 模型
             final_comment = final_comment .. "󱚤"
        end

        -- 应用注释
        if final_comment ~= initial_comment then
            genuine_cand.comment = final_comment
        end
        yield(genuine_cand)
        ::continue::
    end
end
return ZH
