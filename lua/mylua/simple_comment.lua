
local zaran = require("zaran")
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
        result[#result + 1] = tone_map[uchar] or uchar
    end
    return table.concat(result)
end

-- ----------------------
-- # 辅助码拆分提示模块
-- ----------------------
local function get_chaifen_comment(cand, env)
    if not env.chaifen_dict then return "" end
    local dict = env.chaifen_dict()
    return dict and dict:lookup(cand.text) or ""
end

-- ----------------------
-- # 错音错字提示模块
-- ----------------------
local function get_cr_comment(cand, env)
    local correction = env.corrections_cache[cand.comment]
    if not correction or cand.text ~= correction.text then
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

local function get_reverse_lookup_comment(cand, initial_comment)
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
            table.insert(inner_parts, "U" .. unicode_h)
        end
    end

    if #inner_parts == 0 then
        return "〔无〕"
    end
    -- 使用间隔号连接
    return "〔" .. table.concat(inner_parts, ",") .. "〕"
end


-- ----------------------
-- 主函数：根据优先级处理候选词的注释和preedit
-- ----------------------
local ZH = {}
function ZH.init(env)
    local config = env.engine.schema.config
    env.corrector_enabled = config:get_bool("simple_comment/corrector") or true
    env.chaifen_dict = zaran.Thunk(function()
        return ReverseLookup("chaifen")
    end)
    env.corrections_cache = zaran.load_cuoyin()
    env.quick_code_indicator = config:get_string("moran/quick_code_indicator") or "⚡️"
    env.pin_indicator = config:get_string("moran/pin/indicator") or "📌"
    env.kagiroi_tag=config:get_string('kagiroi/tag') or "kagiroi"
end

function ZH.fini(env)
    -- 清理
    env.chaifen_dict = nil
    env.corrections_cache = nil
    -- collectgarbage()
end

function ZH.func(input, env)
    -- 每 10% 的翻譯觸發一次 GC
    if math.random() < 0.1 then
        collectgarbage()
    end
    local config = env.engine.schema.config
    local context = env.engine.context
    local input_str = context.input or ""
    local is_reverse_lookup_mode = zaran.is_reverse_lookup(env)
    local should_skip_candidate_comment = zaran.is_function_mode_active(context) or input_str == ""
    local is_chaifen_enabled = context:get_option("chaifen_switch")
    --preedit相关声明
    local is_tone_display = context:get_option("tone_display")
    local is_full_pinyin = context:get_option("full_pinyin")

    for cand in input:iter() do
        if should_skip_candidate_comment then
            yield(cand)
            goto continue
        end
        local genuine_cand = cand:get_genuine()
        local preedit = genuine_cand.preedit or ""
        local initial_comment = genuine_cand.comment

        -- preedit相关处理只跳过 preedit，不影响注释
        if is_reverse_lookup_mode then
            goto after_preedit
        end
        if not is_tone_display and not is_full_pinyin then
            goto after_preedit
        end
        if (not initial_comment or initial_comment == "") then
            goto after_preedit
        end
        do
            -- 拆分拼音段（comment）
            local pinyin_segments = {}
            for segment in string.gmatch(initial_comment,"[^ ]+") do
                local pinyin = segment:match("^[^;]+")
                if pinyin then
                    if is_full_pinyin then pinyin = remove_pinyin_tone(pinyin) end -- 全拼模式：提前去除声调
                    table.insert(pinyin_segments, pinyin)
                end
            end
            genuine_cand.preedit = table.concat(pinyin_segments, " ")
        end
        ::after_preedit::

        -- 进入注释处理阶段
        local final_comment = ""

        -- 拆分注释
        if is_chaifen_enabled then
            local chaifen_comment = get_chaifen_comment(cand, env)
            if chaifen_comment and chaifen_comment ~= "" then
                final_comment = chaifen_comment
            end
        end

        -- 错音错字提示
        if env.corrector_enabled then
            local cr_comment = get_cr_comment(cand, env)
            if cr_comment and cr_comment ~= "" then
                final_comment = cr_comment
            end
        end

        -- 反查模式提示
        if is_reverse_lookup_mode then
            local reverse_lookup_comment = get_reverse_lookup_comment(cand, initial_comment)
            if reverse_lookup_comment and reverse_lookup_comment ~= "" then
                final_comment = reverse_lookup_comment
            end
        end

        --  ⑤ 处理用户标记
        if cand.type == "fixed" then                            -- 魔然简表
            final_comment = final_comment .. env.quick_code_indicator
        elseif cand.type == "model" then                        -- 模型
            final_comment = final_comment .. "φ"
        elseif cand.type == "pinned" then                       -- 魔然pin词
            final_comment = final_comment .. env.pin_indicator
        elseif cand.type == "pin_tip" then                       -- 魔然pin造词
            final_comment = "開始加詞" .. env.pin_indicator
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