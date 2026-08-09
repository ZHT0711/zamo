
local moran = require("moran")
local tone_map = {
    ['ā']='a', ['á']='a', ['ǎ']='a', ['à']='a',
    ['ē']='e', ['é']='e', ['ě']='e', ['è']='e',
    ['ī']='i', ['í']='i', ['ǐ']='i', ['ì']='i',
    ['ō']='o', ['ó']='o', ['ǒ']='o', ['ò']='o', ['ň']='n',
    ['ū']='u', ['ú']='u', ['ǔ']='u', ['ù']='u', ['ǹ']='n',
    ['ǖ']='ü', ['ǘ']='ü', ['ǚ']='ü', ['ǜ']='ü', ['ń']='n',
}

local function remove_pinyin_tone(s)
    local result = {}
    for uchar in s:gmatch("[%z\1-\127\194-\244][\128-\191]*") do
        table.insert(result, tone_map[uchar] or uchar)
    end
    return table.concat(result)
end

-- 文件操作辅助函数（替代 wanxiang 中的功能）
local function file_exists(filename)
    local f = io.open(filename, "r")
    if f ~= nil then
        io.close(f)
        return true
    else
        return false
    end
end

local function load_file_with_fallback(filename, mode)
    mode = mode or "r"
    local _path = filename:gsub("^/+", "")
    
    -- 尝试用户目录
    local user_data_dir = rime_api.get_user_data_dir()
    if user_data_dir then
        local user_path = user_data_dir .. '/' .. _path
        if file_exists(user_path) then
            return io.open(user_path, mode), function(f) if f then f:close() end end
        end
    end
    
    -- 尝试共享目录
    local shared_data_dir = rime_api.get_shared_data_dir()
    if shared_data_dir then
        local shared_path = shared_data_dir .. '/' .. _path
        if file_exists(shared_path) then
            return io.open(shared_path, mode), function(f) if f then f:close() end end
        end
    end
    
    return nil, function() end, "File not found"
end


local function is_function_mode_active(context)
    if not context or not context.composition or context.composition:empty() then
        return false
    end

    local seg = context.composition:back()
    if not seg then return false end

    return seg:has_tag("number")
        or seg:has_tag("unicode")
        or seg:has_tag("calculator")
        or seg:has_tag("shijian")
        or seg:has_tag("Ndate")
end

-- ----------------------
-- # 辅助码拆分提示模块
-- PRO 专用
-- ----------------------
local CF = {}
function CF.fini(env)
    env.chaifen_dict = nil
    collectgarbage()
end

function CF.get_comment(cand, env)
    -- 首次使用时创建延迟加载的 Thunk
    if not env.chaifen_dict then
        env.chaifen_dict = moran.Thunk(function()
            return ReverseLookup("chaifen")
        end)
    end

    -- 获取实际字典对象（可能为 nil）
    local dict = env.chaifen_dict()
    if not dict then return "" end

    -- 查询拆分结果
    local raw = dict:lookup(cand.text)
    return raw or ""
end

-- ----------------------
-- # 错音错字提示模块
-- ----------------------
local CR = {}
local corrections_cache = nil -- 用于缓存已加载的词典
function CR.init(env)
    -- CR.style = env.settings.corrector_type or '{comment}'
    local auto_delimiter = env.settings.auto_delimiter
    local path = "dicts/cuoyin.pro.dict.yaml"
    
    local file, close_file, err = load_file_with_fallback(path)
    if not file then
        log.error(string.format("[simple_comment]: 加载失败 %s，错误: %s", path, err))
        return
    end
    
    corrections_cache = {}
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

function CR.get_comment(cand)
    local correction = corrections_cache and corrections_cache[cand.comment] or nil
    if not (correction and cand.text == correction.text) then
        return nil
    end
    return correction.comment
end


-- ----------------------
-- 部件组字返回的注释
-- ----------------------
local function get_charset_label(text)
    if not text or text == "" then return nil end
    local cp = utf8.codepoint(text)
    if not cp then return nil end

    -- 按照 Unicode 区块频率排序
    if cp >= 0x4E00   and cp <= 0x9FFF  then return "基本" end
    if cp >= 0x3400   and cp <= 0x4DBF  then return "扩A" end
    if cp >= 0x20000  and cp <= 0x2A6DF then return "扩B" end
    if cp >= 0x2A700  and cp <= 0x2B73F then return "扩C" end
    if cp >= 0x2B740  and cp <= 0x2B81F then return "扩D" end
    if cp >= 0x2B820  and cp <= 0x2CEAF then return "扩E" end
    if cp >= 0x2CEB0  and cp <= 0x2EBEF then return "扩F" end
    if cp >= 0x30000  and cp <= 0x3134F then return "扩G" end
    if cp >= 0x31350  and cp <= 0x323AF then return "扩H" end
    if cp >= 0x2EBF0  and cp <= 0x2EE5F then return "扩I" end
    if cp >= 0x323B0  and cp <= 0x3347f then return "扩J" end
    if cp >= 0x31c0  and cp <= 0x31ef then return "笔画" end
    if cp >= 0x2e80  and cp <= 0x2eff then return "部首" end
    if cp >= 0x2f00  and cp <= 0x2fdf then return "康熙部首" end
    if cp >= 0x2ff0  and cp <= 0x2fff then return "汉字结构" end
    
    -- 兼容区
    if cp >= 0xF900   and cp <= 0xFAFF  then return "兼容" end
    if cp >= 0x2F800  and cp <= 0x2FA1F then return "兼容补充" end

    return nil
end

local function C2U(char)
    local unicode_d = utf8.codepoint(char)
    local unicode_h = string.format('%X', unicode_d)
    return unicode_h
end

local function get_az_comment(cand, env, initial_comment)
    local inner_parts = {}
    
    -- 音形注释拆解逻辑
    if initial_comment and initial_comment ~= "" then
    local segments = {}
        for segment in string.gmatch(initial_comment, "[^%s]+") do
        table.insert(segments, segment)
    end
        
        if #segments > 0 then
            local semicolon_count = select(2, string.gsub(segments[1], ";", ""))
    local pinyins = {}
    local fuzhu = nil
    for _, segment in ipairs(segments) do
                local pinyin = string.match(segment, "^[^;~]+")
        local fz = nil

        if semicolon_count == 1 then
                    fz = string.match(segment, ";(.+)$")
        end

        if pinyin then table.insert(pinyins, pinyin) end
        if not fuzhu and fz and fz ~= "" then fuzhu = fz end
    end

    -- 拼接结果
    if #pinyins > 0 then
        local pinyin_str = table.concat(pinyins, "/")
                table.insert(inner_parts, string.format("音%s", pinyin_str))
                
        if fuzhu then
                    table.insert(inner_parts, string.format("辅%s", fuzhu))
                end
            end
        end
    end

    if cand and cand.text then
        local label = get_charset_label(cand.text)
        local unicode_h = C2U(cand.text)
        if label then
            table.insert(inner_parts, label)
        end
        if unicode_h then
            table.insert(inner_parts, "U"..unicode_h)
        end
    end

    if #inner_parts == 0 then
        return "〔无〕"
    end
    -- 使用间隔号连接
    return "〔" .. table.concat(inner_parts, ",") .. "〕"
end
-- ----------------------
-- # 辅助码提示或带调全拼注释模块 (Fuzhu)
-- ----------------------
local function get_fz_comment(cand, env, initial_comment)
    local length = utf8.len(cand.text)
    if length > env.settings.candidate_length then
        return ""
    end
    local auto_delimiter = env.settings.auto_delimiter or " "
    local segments = {}
    for segment in string.gmatch(initial_comment, "[^" .. auto_delimiter .. "]+") do
        table.insert(segments, segment)
    end

    -- 根据 option 动态决定是否强制使用 tone
    local use_tone = env.engine.context:get_option("tone_hint")
    local fuzhu_type = use_tone and "tone" or "fuzhu"

    local first_segment = segments[1] or ""
    local semicolon_count = select(2, first_segment:gsub(";", ""))
    local fuzhu_comments = {}
    -- 没有分号的情况
    if semicolon_count == 0 then
        return initial_comment:gsub(auto_delimiter, " ")
    else
        -- 有分号：按类型提取
        for _, segment in ipairs(segments) do
            if fuzhu_type == "tone" then
                -- 取第一个分号"前"的内容
                local before = segment:match("^(.-);")
                if before and before ~= "" then
                    table.insert(fuzhu_comments, before)
                end
            else -- "fuzhu"
                -- 取第一个分号"后"的内容（到行尾）
                local after = segment:match(";(.+)$")
                if after and after ~= "" then
                    table.insert(fuzhu_comments, after)
                end
            end
        end
    end

    -- 最终拼接输出，fuzhu用 `,`，tone用 /连接
    if #fuzhu_comments > 0 then
        return table.concat(fuzhu_comments, " ")
    else
        return ""
    end
end

-- kagiroi特殊处理
-- local function is_kagiroi_reverse_lookup(env)
--     local seg = env.engine.context.composition:back()
--     if not seg then
--         return false
--     end
--     return seg:has_tag("kagiroi")
-- end

-- ----------------------
-- 主函数：根据优先级处理候选词的注释和preedit
-- ----------------------
local ZH = {}
function ZH.init(env)
    local config = env.engine.schema.config
    local delimiter = config:get_string('speller/delimiter') or " '"
    local auto_delimiter = delimiter:sub(1, 1)
    local manual_delimiter = delimiter:sub(2, 2)
    env.settings = {
        delimiter = delimiter,
        auto_delimiter = auto_delimiter,
        manual_delimiter = manual_delimiter,
        corrector_enabled = config:get_bool("simple_comment/corrector") or true,
        -- corrector_type = config:get_string("simple_comment/corrector_type") or "{comment}",
        -- chaifen = config:get_string("simple_comment/chaifen") or "〔chaifen〕",
        candidate_length = tonumber(config:get_string("simple_comment/candidate_length")) or 1,
    }
    CR.init(env)
    -- CF.init(env)
end

function ZH.fini(env)
    -- 清理
    CF.fini(env)
end

function ZH.func(input, env)
    -- 每 10% 的翻譯觸發一次 GC
    if math.random() < 0.1 then
        collectgarbage()
    end
    local quick_code_indicator = env.engine.schema.config:get_string("moran/quick_code_indicator") or "⚡️"
    local pin_indicator = env.engine.schema.config:get_string("moran/pin/indicator") or "📌"
    local config = env.engine.schema.config
    local context = env.engine.context
    local input_str = context.input
    local is_radical_mode = moran.is_reverse_lookup(env)
    local should_skip_candidate_comment = is_function_mode_active(context) or input_str == ""
    local is_tone_comment = env.engine.context:get_option("tone_hint")
    local is_comment_hint = env.engine.context:get_option("fuzhu_hint")
    local is_chaifen_enabled = env.engine.context:get_option("chaifen_switch")
    --preedit相关声明
    local delimiter = env.settings.delimiter
    local auto_delimiter = env.settings.auto_delimiter
    local manual_delimiter = env.settings.manual_delimiter
    local is_tone_display = context:get_option("tone_display")
    local is_full_pinyin = context:get_option("full_pinyin")
    local index = 0
    -- kagiroi特殊处理
    local seg = context.composition:back()
    local kagiroi_tag=env.engine.schema.config:get_string('kagiroi/tag') or "kagiroi"
    local is_kagiroi = seg and seg:has_tag(kagiroi_tag)


    for cand in input:iter() do
        local genuine_cand = is_kagiroi and cand or cand:get_genuine()      -- kagiroi需要cand
        local preedit = genuine_cand.preedit or ""
        local initial_comment = genuine_cand.comment
        initial_comment = initial_comment:gsub(quick_code_indicator, '')    -- 移除魔然的符号
        initial_comment = initial_comment:gsub(pin_indicator, '')           -- 移除pin的符号
        local final_comment = initial_comment
        index = index + 1

        -- preedit相关处理只跳过 preedit，不影响注释
        if is_radical_mode then
            goto after_preedit
        end
        if not is_tone_display and not is_full_pinyin then
            goto after_preedit
        end
        if (not initial_comment or initial_comment == "") then
            goto after_preedit
        end
        do
            -- 拆分 preedit
            local input_parts = {}
            local current_segment = ""
            for i = 1, #preedit do
                local char = preedit:sub(i, i)
                if char == auto_delimiter or char == manual_delimiter then
                    if #current_segment > 0 then
                        table.insert(input_parts, current_segment)
                        current_segment = ""
                    end
                    table.insert(input_parts, char)
                else
                    current_segment = current_segment .. char
                end
            end
            if #current_segment > 0 then
                table.insert(input_parts, current_segment)
            end

            -- 拆分拼音段（comment）
            local pinyin_segments = {}
            for segment in string.gmatch(initial_comment, "[^" .. auto_delimiter .. manual_delimiter .. "]+") do
                local pinyin = segment:match("^[^;]+")
                if pinyin then
                    -- pinyin = pinyin:gsub("[%[%]]", "")  --去掉英文词库编码中的[]
                    table.insert(pinyin_segments, pinyin)
                end
            end

            -- 替换逻辑
            local pinyin_index = 1
            for i, part in ipairs(input_parts) do
                if part == auto_delimiter or part == manual_delimiter then
                    input_parts[i] = " "  --声调用空格隔开
                else
                    local body, tone = part:match("([%a]+)([^%a]+)") --后面加号很必要
                    local py = pinyin_segments[pinyin_index]

                    if py then
                        input_parts[i] = py
                        pinyin_index = pinyin_index + 1
                    end
                end
            end

            if is_full_pinyin then      -- 如果是非音调仅全拼
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
        -- 进入注释处理阶段
        -- ① 辅助码注释或者声调注释
        if is_comment_hint or is_tone_comment then
            local fz_comment = get_fz_comment(cand, env, initial_comment)
            if fz_comment then
                final_comment = fz_comment
            end
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
            local cr_comment = CR.get_comment(cand)
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

        --  ⑤ 魔然提示
        -- 处理用户标记
        if cand.type == "fixed" then                            -- 魔然简表
            final_comment = final_comment .. quick_code_indicator
        elseif cand.type == "model" then                        -- 模型
            final_comment = final_comment .. "φ"
        elseif cand.type == "pinned" then                       -- 魔然pin词
            final_comment = final_comment:gsub(pin_indicator, '') .. pin_indicator
        elseif cand.type == "pin_tip" then                       -- 魔然pin造词
            final_comment = "開始加詞" .. pin_indicator
        elseif cand.type == "down" then                         -- 魔然ijrq
            final_comment = final_comment .. "▾"
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