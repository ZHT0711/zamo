-- lua/escape_formatter.lua
-- 功能：候选文本转义序列格式化（始终开启）
-- 支持：
--   \n(换行) \r(回车) \t(制表) \s(空格) \z(零宽空格)
--   字符重复：字\数字  例如 "好\3" → "好好好"
--   动态时间令牌：\Y年 \m月 \d日 \T时辰 \K刻 \A时段(上午/下午) 等
--   [[...]] 内的内容不会被转义

local find = string.find
local gsub = string.gsub

local escape_map = {
    ["\\n"] = "\n",
    ["\\r"] = "\r",
    ["\\t"] = "\t",
    ["\\s"] = " ",
    ["\\z"] = "\226\128\139",   -- 零宽空格
}

-- 时辰数据
local shichen_data = {
    {name="子时", start=23, stop=1},  {name="丑时", start=1, stop=3},
    {name="寅时", start=3, stop=5},   {name="卯时", start=5, stop=7},
    {name="辰时", start=7, stop=9},   {name="巳时", start=9, stop=11},
    {name="午时", start=11, stop=13}, {name="未时", start=13, stop=15},
    {name="申时", start=15, stop=17}, {name="酉时", start=17, stop=19},
    {name="戌时", start=19, stop=21}, {name="亥时", start=21, stop=23},
}
local ke_names = {"初刻","二刻","三刻","四刻","五刻","六刻","七刻","八刻"}

local function get_shichen_and_ke(hour, min)
    local total = hour*60 + min
    for _, sc in ipairs(shichen_data) do
        local start_min = sc.start*60
        local stop_min = sc.stop*60
        if sc.start > sc.stop then stop_min = stop_min + 1440 end
        if total >= start_min and total < stop_min then
            local offset = total - start_min
            local ke = math.floor(offset/15)
            if ke >= 8 then ke = 7 end
            return sc.name, ke_names[ke+1]
        end
    end
    return "未知时辰", "未知刻"
end

local function process_datetime(s)
    local dt = os.date("*t")
    local h12 = dt.hour % 12; if h12 == 0 then h12 = 12 end
    local ampm = dt.hour < 12 and "am" or "pm"
    local raw_tz = os.date("%z") or "+0800"
    local tz_colon = raw_tz:sub(1,3) .. ":" .. raw_tz:sub(4,5)
    local zh = dt.hour < 6 and "凌晨" or dt.hour < 12 and "上午" or dt.hour < 13 and "中午" or dt.hour < 18 and "下午" or "晚上"
    local sc, ke = get_shichen_and_ke(dt.hour, dt.min)
    local map = {
        Y = string.format("%04d", dt.year),
        y = string.format("%02d", dt.year%100),
        m = string.format("%02d", dt.month),
        d = string.format("%02d", dt.day),
        N = tostring(dt.month),
        j = tostring(dt.day),
        W = ({"星期日","星期一","星期二","星期三","星期四","星期五","星期六"})[dt.wday],
        w = ({"周日","周一","周二","周三","周四","周五","周六"})[dt.wday],
        H = string.format("%02d", dt.hour),
        G = tostring(dt.hour),
        I = string.format("%02d", h12),
        l = tostring(h12),
        T = sc, K = ke,
        M = string.format("%02d", dt.min),
        S = string.format("%02d", dt.sec),
        p = ampm, P = ampm:upper(),
        O = tz_colon, o = raw_tz,
        A = zh,
    }
    return (s:gsub("\\(%a)", function(c) return map[c] or c end))
end

-- UTF-8 单字符匹配模式
local utf8_char = "[%z\1-\127\194-\244][\128-\191]*"

local function apply_escape(text)
    if not text or not find(text, "\\", 1, true) then
        return text, false
    end
    -- 保护 [[...]]
    local blocks = {}
    local s = text:gsub("%[%[(.-)%]%]", function(txt)
        blocks[#blocks+1] = txt
        return "\0BLK" .. #blocks .. "\0"
    end)
    -- 基础转义 \n \r \t \s \z
    s = s:gsub("\\[ntrsz]", escape_map)
    -- 字符重复 a\3 -> aaa
    s = s:gsub("("..utf8_char..")\\(%d+)", function(char, count)
        local n = tonumber(count)
        if n and n>0 and n<200 then
            return string.rep(char, n)
        end
        return char .. "\\" .. count
    end)
    -- 动态时间
    s = process_datetime(s)
    -- 还原 [[...]]
    s = s:gsub("\0BLK(%d+)\0", function(i) return blocks[tonumber(i)] or "" end)
    return s, s ~= text
end

-- Filter 入口
local function filter(input, env)
    for cand in input:iter() do
        local txt = cand.text
        if txt and txt ~= "" then
            local new_txt, changed = apply_escape(txt)
            if changed then
                local nc = Candidate(cand.type, cand.start, cand._end, new_txt, cand.comment)
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