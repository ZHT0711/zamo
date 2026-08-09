-- lua/super_english_format_only.lua
-- 极简版：仅保留「逐词大小写对应」格式化
-- 用法：在 Rime 的 xxx.schema.yaml 的 engine/filters 中加入此文件

local function pure(s)
    return (string.gsub(s, "[^a-zA-Z]", ""))
end

local allowed_symbols = {  -- 允许的 ASCII 符号
    [32]=true, [33]=true, [39]=true, [44]=true, [45]=true, [46]=true,
    [48]=true,[49]=true,[50]=true,[51]=true,[52]=true,
    [53]=true,[54]=true,[55]=true,[56]=true,[57]=true,
}

local function is_ascii_phrase(s)
    if not s or s == "" then return false end
    local has_alpha = false
    for i = 1, #s do
        local b = string.byte(s, i)
        if (b >= 65 and b <= 90) or (b >= 97 and b <= 122) then
            has_alpha = true
        elseif not allowed_symbols[b] then
            return false
        end
    end
    return has_alpha
end

-- 核心：根据输入码的大小写模式，格式化一个英文候选文本
local function apply_format(text, input_code)
    if not input_code or input_code == "" then return text end
    local parts = {}
    local pos = 1
    for word in string.gmatch(text, "%S+") do
        local clean_word = pure(word)
        local wlen = #clean_word
        if wlen > 0 then
            local seg_end = math.min(pos + wlen - 1, #input_code)
            local segment = string.sub(input_code, pos, seg_end)
            pos = seg_end + 1
            -- 非纯字母词（含标点）只做首字母大写
            if string.find(word, "[^a-zA-Z]") then
                if string.find(segment, "^%u") then
                    word = string.gsub(word, "^%a", string.upper)
                end
            else
                -- 纯字母词：全大写 / 首字母大写 / 原样
                if string.find(segment, "^%u%u") then
                    word = string.upper(word)
                elseif string.find(segment, "^%u") then
                    word = string.gsub(word, "^%a", string.upper)
                end
            end
        end
        table.insert(parts, word)
    end
    return table.concat(parts, " ")
end

-- Filter 入口
local function filter(input, env)
    local ctx = env.engine.context
    local raw_input = ctx.input
    for cand in input:iter() do
        local text = cand.text
        if raw_input and raw_input ~= "" and is_ascii_phrase(text) then
            local new_text = apply_format(text, raw_input)
            if new_text ~= text then
                local nc = Candidate(cand.type, cand.start, cand._end, new_text, cand.comment)
                nc.preedit = cand.preedit
                cand = nc
            end
        end
        yield(cand)
    end
end

return {
    func = filter,
    init = function() end,
    fini = function() end,
}