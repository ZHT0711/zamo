-- @amzxyz  https://github.com/amzxyz/rime-wanxiang
-- 2026-10-17: 日期字段按需计算并共享一次过滤的时间快照，保护块最后恢复。
-- 提供以下核心修饰能力：
-- 功能 A：转义序列解析（常驻）
--         将候选词中的 \n, \t, \s(空格) 等文本转义符格式化为实际效果。
-- 功能 B：成对符号包裹与候选锁定
--         输入 `\` 瞬间锁定并展示当前候选快照，追加对应字母即可为候选词快速穿上各类括号/引号（如【】、“”）。
local wanxiang = require("wanxiang/wanxiang")
local M = {}

-- 全局通信通道
_G.WanxiangSharedState = _G.WanxiangSharedState
    or {
        sorter_active = false,
        last_input = "",
        page_cache = {},
    }

-- 性能优化：本地化字符串函数
local find = string.find
local gsub = string.gsub
local upper = string.upper
local sub = string.sub
local utf8_codes = utf8.codes

local function get_first_utf8_char(s)
    if not s or s == "" then
        return ""
    end
    local offset = utf8.offset(s, 2)
    return offset and sub(s, 1, offset - 1) or s
end

local function fast_type(c)
    local t = c.type
    if t then
        return t
    end

    local g = c.get_genuine and c:get_genuine() or nil
    return (g and g.type) or ""
end

-- 1. 内部常量与工具函数
local zwsp = "\226\128\139"

local escape_map = {
    ["\\n"] = zwsp .. "\n",  --用来应对electron开发的软件行尾字符被转移到内容最后一行的问题
    ["\\r"] = "\r",
    ["\\t"] = "\t",
    ["\\s"] = " ",
    ["\\z"] = zwsp,
}

local utf8_char_pattern = "[%z\1-\127\194-\244][\128-\191]*"

local shichen_data = {
    { name = "子时", start_hour = 23, end_hour = 1 },
    { name = "丑时", start_hour = 1, end_hour = 3 },
    { name = "寅时", start_hour = 3, end_hour = 5 },
    { name = "卯时", start_hour = 5, end_hour = 7 },
    { name = "辰时", start_hour = 7, end_hour = 9 },
    { name = "巳时", start_hour = 9, end_hour = 11 },
    { name = "午时", start_hour = 11, end_hour = 13 },
    { name = "未时", start_hour = 13, end_hour = 15 },
    { name = "申时", start_hour = 15, end_hour = 17 },
    { name = "酉时", start_hour = 17, end_hour = 19 },
    { name = "戌时", start_hour = 19, end_hour = 21 },
    { name = "亥时", start_hour = 21, end_hour = 23 },
}

local ke_names = { "初刻", "二刻", "三刻", "四刻", "五刻", "六刻", "七刻", "八刻" }

local function get_shichen_and_ke(hour, min)
    local total_minutes = hour * 60 + min
    for _, shichen in ipairs(shichen_data) do
        local shichen_name = shichen.name
        local start_hour = shichen.start_hour
        local end_hour = shichen.end_hour
        local start_minutes = start_hour * 60
        local end_minutes = end_hour * 60
        local is_match = false
        if start_hour > end_hour then
            if total_minutes >= start_minutes or total_minutes < end_minutes then
                is_match = true
            end
        else
            if total_minutes >= start_minutes and total_minutes < end_minutes then
                is_match = true
            end
        end
        if is_match then
            local calc_minutes = total_minutes
            if start_hour > end_hour and total_minutes < end_minutes then
                calc_minutes = total_minutes + 1440
            end

            local offset_minutes = calc_minutes - start_minutes
            local ke_index = math.floor(offset_minutes / 15)
            if ke_index >= 8 then
                ke_index = 7
            end

            return shichen_name, ke_names[ke_index + 1]
        end
    end

    return "未知时辰", "未知刻"
end

-- 简易 ISO 周数计算
local function iso_week_number(year, month, day)
    local function get_iso_weekday(y, m, d)
        local t = os.time({ year = y, month = m, day = d })
        local w = tonumber(os.date("%w", t))
        return (w == 0) and 7 or w
    end

    local t = os.time({ year = year, month = month, day = day })
    local iso_day = get_iso_weekday(year, month, day)
    local thursday_time = t + (4 - iso_day) * 86400
    local thursday = os.date("*t", thursday_time)

    local first_thursday = os.time({ year = thursday.year, month = 1, day = 4 })
    local first_thursday_weekday = get_iso_weekday(thursday.year, 1, 4)
    local start_of_week1 = first_thursday - (first_thursday_weekday - 1) * 86400

    local week_number = math.floor((thursday_time - start_of_week1) / (7 * 86400)) + 1
    return thursday.year, week_number
end

local time_tokens_pattern = "\\[ACDEFGHIKMNOPSTYdjlmopwy]"
local datetime_fields = {
    Y = {"%04d", "year"}, m = {"%02d", "month"}, d = {"%02d", "day"},
    H = {"%02d", "hour"}, M = {"%02d", "min"}, S = {"%02d", "sec"},
}
local weekday_names = {
    C = {"星期日", "星期一", "星期二", "星期三", "星期四", "星期五", "星期六"},
    D = {"周日", "周一", "周二", "周三", "周四", "周五", "周六"},
    E = {"Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"},
    F = {"Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"},
}

-- 2. 核心：处理动态时间
local function process_datetime_internal(s, dt, cache, timestamp)
    if not string.find(s, time_tokens_pattern) then
        return s
    end

    cache = cache or {}
    return s:gsub("\\(%a)", function(char)
        if cache[char] ~= nil then return cache[char] end
        local value
        local field = datetime_fields[char]
        if field then value = string.format(field[1], dt[field[2]])
        elseif char == "y" then value = string.format("%02d", dt.year % 100)
        elseif char == "N" then value = tostring(dt.month)
        elseif char == "j" then value = tostring(dt.day)
        elseif char == "G" then value = tostring(dt.hour)
        elseif weekday_names[char] then value = weekday_names[char][dt.wday]
        elseif char == "w" then
            value = ""
            if dt.year and dt.year > 0 then
                local _, week = iso_week_number(dt.year, dt.month, dt.day)
                value = tostring(week)
            end
        elseif char == "I" or char == "l" then
            local hour = dt.hour % 12
            if hour == 0 then hour = 12 end
            value = char == "I" and string.format("%02d", hour) or tostring(hour)
        elseif char == "T" or char == "K" then
            cache.T, cache.K = get_shichen_and_ke(dt.hour, dt.min)
            value = cache[char]
        elseif char == "p" or char == "P" then
            value = dt.hour < 12 and "am" or "pm"
            if char == "P" then value = value:upper() end
        elseif char == "O" or char == "o" then
            local raw = cache.o or os.date("%z", timestamp) or "+0800"
            cache.o = raw
            local sign, hour, minute = raw:match("^([%+%-])(%d%d)(%d%d)$")
            value = char == "O" and sign and (sign .. hour .. ":" .. minute) or raw
        elseif char == "A" then
            local hour = dt.hour
            value = hour < 6 and "凌晨" or hour < 12 and "上午" or hour < 13 and "中午"
                or hour < 18 and "下午" or "晚上"
        end
        value = value or ("\\" .. char)
        cache[char] = value
        return value
    end)
end

-- 3. 转义处理
local function apply_escape_fast(text)
    if not text or not string.find(text, "\\", 1, true) then
        return text, false, false
    end

    local blocks = {}
    local s = text:gsub("%[%[(.-)%]%]", function(txt)
        blocks[#blocks + 1] = txt
        return "\0BLK" .. #blocks .. "\0"
    end)

    s = s:gsub("\\[ntrsz]", escape_map)

    s = s:gsub("(" .. utf8_char_pattern .. ")\\(%d+)", function(char, count)
        local n = tonumber(count)
        if n and n > 0 and n < 200 then
            return string.rep(char, n)
        end
        return char .. "\\" .. count
    end)
    local need_time = string.find(s, time_tokens_pattern) ~= nil
    if need_time then return s, s ~= text, true, blocks end
    s = s:gsub("\0BLK(%d+)\0", function(i)
        return blocks[tonumber(i)] or ""
    end)
    return s, s ~= text, need_time
end

local function format_and_autocap(cand, env, datetime)
    local text = cand.text
    if not text or text == "" then
        return cand
    end

    local t2, text_changed, need_time, blocks = apply_escape_fast(text)
    if need_time then
        datetime = datetime or {}
        if not datetime.dt then
            datetime.timestamp = os.time()
            datetime.dt = os.date("*t", datetime.timestamp)
            datetime.values = {}
        end
        local time_replaced = process_datetime_internal(t2, datetime.dt, datetime.values, datetime.timestamp)
        time_replaced = time_replaced:gsub("\0BLK(%d+)\0", function(i)
            return blocks[tonumber(i)] or ""
        end)
        if time_replaced ~= t2 then
            t2 = time_replaced
            text_changed = true -- 时间替换也算文本变化
        end
    end

    local genuine = cand:get_genuine()
    local current_comment = genuine.comment or ""
    local symbol = env.cand_type_symbols[fast_type(cand)]
    local comment_changed = false

    if symbol and symbol ~= "" and current_comment ~= "~" then
        local escaped_symbol = symbol:gsub("[%-%^%$%(%)%%%.%[%]%*%+%?]", "%%%1")
        if not current_comment:match(escaped_symbol .. "$") then
            current_comment = current_comment .. symbol
            comment_changed = true
        end
    end

    -- 分流处理
    if text_changed then
        local nc = Candidate(cand.type, cand.start, cand._end, t2, current_comment)
        nc.preedit = cand.preedit
        return nc
    elseif comment_changed then
        genuine.comment = current_comment
        return cand
    else
        return cand
    end
end

local function clone_candidate(c)
    local nc = Candidate(c.type, c.start, c._end, c.text, c.comment or "")
    nc.preedit = c.preedit
    nc.quality = c.quality
    return nc
end
--  包裹映射
local default_wrap_map = {
    -- 单字母：常用成对括号/引号（每项恰好两个字符）
    a = "[]", -- 方括号
    b = "【】", -- 黑方头括号
    c = "❲❳", -- 双大括号 / 装饰括号
    d = "〔〕", -- 方头括号
    e = "⟮⟯", -- 小圆括号 / 装饰括号
    f = "⟦⟧", -- 双方括号 / 数学集群括号
    g = "「」", -- 直角引号
    -- h 预留用于 Markdown 一级标题
    i = "『』", -- 双直角引号
    j = "<>", -- 尖括号
    k = "《》", -- 书名号（双）
    l = "〈〉", -- 书名号（单）
    m = "‹›", -- 法文单书名号
    n = "«»", -- 法文双书名号
    o = "⦅⦆", -- 白圆括号
    p = "⦇⦈", -- 白方括号
    q = "()", -- 圆括号
    r = "|儿", --儿化候选
    s = "［］", -- 全角方括号
    t = "⟨⟩", -- 数学角括号
    u = "〈〉", -- 数学尖括号
    v = "❰❱", -- 装饰角括号
    w = "（）", -- 全角圆括号
    x = "｛｝", -- 全角花括号
    y = "⟪⟫", -- 双角括号
    z = "{}", -- 花括号

    --  扩展括号族 / 引号
    dy = "''", -- 英文单引号
    sy = '""', -- 英文双引号
    zs = "“”", -- 中文弯双引号
    zd = "‘’", -- 中文弯单引号
    fy = "``", -- 反引号

    --  双字母括号族
    aa = "〚〛", -- 双中括号
    bb = "〘〙", -- 双中括号（小）
    cc = "〚〛", -- 双中括号（重复，可用于 Lua 匹配）
    dd = "❨❩", -- 小圆括号装饰
    ee = "❪❫", -- 小圆括号装饰
    ff = "❬❭", -- 小尖括号装饰
    gg = "⦉⦊", -- 双弯方括号
    ii = "⦍⦎", -- 双弯方括号
    jj = "⦏⦐", -- 双弯方括号
    kk = "⦑⦒", -- 双弯方括号
    ll = "❮❯", -- 小尖括号装饰
    mm = "⌈⌉", -- 上取整 / 数学符号
    nn = "⌊⌋", -- 下取整 / 数学符号
    oo = "⦗⦘", -- 双方括号装饰（补齐）
    pp = "⦙⦚", -- 双方括号装饰（补齐）
    qq = "⟬⟭", -- 小双角括号
    rr = "❴❵", -- 花括号装饰
    ss = "⌜⌝", -- 数学上角符号
    tt = "⌞⌟", -- 数学下角符号
    uu = "⸢⸣", -- 装饰方括号
    vv = "⸤⸥", -- 装饰方括号
    ww = "﹁﹂", -- 中文书名号 / 注释引号
    xx = "﹃﹄", -- 中文书名号 / 注释引号
    yy = "⌠⌡", -- 数学 / 程序符号
    zz = "⟅⟆", -- 数学 / 装饰括号

    --  Markdown / 标记
    md = "**|**", -- Markdown 粗体
    jc = "**|**", -- 加粗
    it = "__|__", -- 斜体
    st = "~~|~~", -- 删除线
    eq = "==|==", -- 高亮
    ln = "`|`", -- 行内代码
    cb = "```|```", -- 代码块
    qt = "> |", -- 引用
    ul = "- |", -- 无序列表项
    ol = "1. |", -- 有序列表项
    lk = "[|](url)", -- 链接
    im = "![|](img)", -- 图片
    h = "# |", -- 一级标题
    hh = "## |", -- 二级标题
    hhh = "### |", -- 三级标题
    hhhh = "#### |", -- 四级标题
    sp = "\\|", -- 反斜杠转义
    br = "|  ", -- 换行
    cm = "", -- 注释

    --  运算与标记符
    pl = "++",
    mi = "--",
    sl = "//",
    bs = "\\\\",
    at = "@@",
    dl = "$$",
    pc = "%%",
    an = "&&",
    cr = "^^",
    cl = "::",
    sc = ";;",
    ex = "!!",
    qu = "??",
    sb = "sb",
}
local function load_mapping_from_config(config)
    local symbol_map = {}

    for k, v in pairs(default_wrap_map) do
        symbol_map[k] = v
    end

    local ok_map, map = pcall(function()
        return config:get_map("paired_symbols/symkey")
    end)

    if ok_map and map then
        local ok_keys, keys = pcall(function()
            return map:keys()
        end)

        if ok_keys and keys then
            for _, key in ipairs(keys) do
                local ok_val, v = pcall(function()
                    return config:get_string("paired_symbols/symkey/" .. key)
                end)
                if ok_val and v and #v > 0 then
                    symbol_map[string.lower(key)] = v
                end
            end
        end
    end

    return symbol_map
end

local function precompile_wrap_parts(wrap_map, delimiter)
    delimiter = delimiter or "|"
    local parts = {}

    for k, wrap_str in pairs(wrap_map) do
        if not wrap_str or wrap_str == "" then
            parts[k] = { l = "", r = "" }
        else
            local pos = find(wrap_str, delimiter, 1, true)
            if pos then
                parts[k] = {
                    l = sub(wrap_str, 1, pos - 1) or "",
                    r = sub(wrap_str, pos + 1) or "",
                }
            else
                local first, last
                local count = 0

                for _, cp in utf8_codes(wrap_str) do
                    local char = utf8.char(cp)
                    if count == 0 then
                        first = char
                    end
                    last = char
                    count = count + 1
                end

                if count == 0 then
                    parts[k] = { l = "", r = "" }
                elseif count == 1 then
                    parts[k] = { l = first, r = "" }
                elseif count == 2 then
                    parts[k] = { l = first, r = last }
                else
                    parts[k] = { l = first, r = last }
                end
            end
        end
    end

    return parts
end

function M.init(env)
    local cfg = env.engine and env.engine.schema and env.engine.schema.config

    env.wrap_map = cfg and load_mapping_from_config(cfg) or default_wrap_map
    env.wrap_delimiter = "|"

    if cfg then
        local d = cfg:get_string("paired_symbols/delimiter")
        if d and #d > 0 then
            env.wrap_delimiter = get_first_utf8_char(d)
        end
    end

    env.wrap_parts = precompile_wrap_parts(env.wrap_map, env.wrap_delimiter)

    env.symbol = "\\"
    if cfg then
        local sym = cfg:get_string("paired_symbols/symbol") or cfg:get_string("paired_symbols/trigger")
        if sym and #sym > 0 then
            env.symbol = get_first_utf8_char(sym)
        end
    end

    env.page_size = (cfg and cfg:get_int("menu/page_size")) or 5

    -- 状态初始化
    env.page_cache = {}
    -- 读取全局类型符号配置
    env.cand_type_symbols = {}
    local map = cfg and cfg:get_map("super_comment/cand_type")
    if map then
        for _, key in ipairs(map:keys()) do
            local val = cfg:get_string("super_comment/cand_type/" .. key)
            if val and val ~= "" then
                env.cand_type_symbols[key] = val
            end
        end
    end
end

function M.fini(env)
    env.wrap_map = nil
    env.wrap_parts = nil
end

function M.func(input, env)
    local datetime = {}
    local ctx = env and env.engine and env.engine.context or nil
    local code = ctx and (ctx.input or "") or ""
    local comp = ctx and ctx.composition or nil
    -- 1. 空环境清理
    if not code or code == "" or (comp and comp:empty()) then
        env.page_cache = {}
        for cand in input:iter() do
            yield(cand)
        end
        return
    end

    local code_len = #code

    -- 2. 探查触发符号（斜杠 \）
    -- 包裹键必须从完整 context.input 解析，不能依赖最后一个 segment。
    -- 手动排序刷新 composition 后，触发符号及其后缀可能被切成独立尾段；
    -- 此时符号位于尾段首位，旧逻辑的 pos > 1 会导致 wrap_key 永远无法识别。
    local symbol = env.symbol
    local sym_len = #symbol
    local symbol_pos = symbol and sym_len > 0 and find(code, symbol, 1, true)
    local code_has_symbol = symbol_pos and symbol_pos > 1 or false

    if not code_has_symbol then
        env.page_cache = {}
    end

    local wrap_key = nil
    if code_has_symbol then
        local right = sub(code, symbol_pos + sym_len)
        local key = right:lower()
        if key ~= "" and env.wrap_map[key] then
            wrap_key = key
        end
    end

    -- 检查是否连续打出双斜杠 \\（取消包裹）
    local is_double = (code_len >= sym_len * 2) and (sub(code, -(sym_len * 2)) == symbol .. symbol)
    if is_double then
        code_has_symbol = false
    end

    -- 定位排序脚本是否存活并获取目标缓存
    local raw_code = ""
    if code_has_symbol then
        local pos = find(code, symbol, 1, true)
        if pos then
            raw_code = sub(code, 1, pos - 1)
        end
    end

    -- 排序脚本的缓存是最终排序结果；只要输入精确匹配且缓存非空，就应当优先使用。
    -- 不能再按缓存数量比较，否则排序去重后数量稍少时，会错误回退到本地未排序快照。
    local target_cache = env.page_cache
    local shared = _G.WanxiangSharedState
    if shared.sorter_active and shared.last_input == raw_code and shared.page_cache and #shared.page_cache > 0 then
        target_cache = shared.page_cache
    end

    -- PHASE 1: 缓存快照输出
    if code_has_symbol and target_cache and #target_cache > 0 then
        for _, c in ipairs(target_cache) do
            local final_cand = c

            if wrap_key then
                local pr = env.wrap_parts[wrap_key] or { l = "", r = "" }
                local wrapped_text = (pr.l or "") .. c.text .. (pr.r or "")

                -- 快照候选来自输入触发符之前；包裹后必须覆盖完整当前输入，
                -- 否则独立尾段中的触发符和包裹键不会被候选消费。
                final_cand = Candidate(c.type, c.start, code_len, wrapped_text, "")
                final_cand.preedit = c.preedit or ""
            else
                -- 仅输入触发符、尚未形成合法包裹键时，继续锁定原候选快照，
                -- 并把已输入的尾部附加到 preedit。
                local cand_end = tonumber(c._end) or 0
                local typed_tail = cand_end < code_len and sub(code, cand_end + 1, code_len) or ""
                final_cand = Candidate(c.type, c.start, code_len, c.text, "")
                final_cand.preedit = (c.preedit or "") .. typed_tail
            end

            yield(final_cand)
        end
        return
    end

    -- PHASE 2: 直通车
    local suppress_set = {}
    local wrap_limit = env.page_size * 2
    local eager_buffer = {}
    local iterator, iterator_state, iterator_control = input:iter()

    local function next_candidate()
        local cand = iterator(iterator_state, iterator_control)
        iterator_control = cand
        return cand
    end

    -- 先从同一个上游迭代器预取两页，确保包裹快照在首个候选 yield 前完整建立。
    while #eager_buffer < wrap_limit do
        local cand = next_candidate()
        if not cand then break end

        local text = cand.text

        if not suppress_set[text] then
            suppress_set[text] = true

            local formatted_cand = format_and_autocap(cand, env, datetime)
            if not code_has_symbol then
                env.page_cache[#env.page_cache + 1] = clone_candidate(formatted_cand)
            end

            eager_buffer[#eager_buffer + 1] = formatted_cand
        end
    end

    for _, cand in ipairs(eager_buffer) do
        yield(cand)
    end

    -- 继续消费同一个上游迭代器，避免重新从头拉取并依赖 suppress_set 跳过前两页。
    while true do
        local cand = next_candidate()
        if not cand then break end

        local text = cand.text

        if not suppress_set[text] then
            suppress_set[text] = true
            yield(format_and_autocap(cand, env, datetime))
        end
    end
end
return M
