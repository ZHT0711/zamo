-- mixed_V.lua 混合 V：简易计算器 + 四舍六入五取偶 + 金额大写 + 日期/农历
--
-- 整合：light
-- 模块来源（版权归各自原作者）：
--   简易计算器   ChaosAlphard   rime-shuangpin-fuzhuma/pull/41
--   金额大写     moran_number   ksqsf       v0.1.1
--   公历转农历   moran_shijian  98wubi Group, Project Moran
-- Version: 0.2.4

-- 主要功能：
-- 1. V 前缀：金额大写、简易计算器、公历转农历（yyyy.mm.dd / mm.dd/）、当天信息
-- 2. rq 前缀：日期偏移（rq+3 / rq-1 ）
-- 3. Vrq：当天的日期
-- 4. Vsj: 当前时间

-- ChangeLog:
--
-- 0.2.4: 日期候选新增 yyyy-mm-dd（横线分隔）格式：V 空输入、公历日期转换、rq 偏移
--        三处输出同步增加。
--
-- 0.2.3: 农历换算改为整数日序 + 结构化年表（惰性解析并缓存）；删除 Dec2bin / system /
--        Analyze / IsLeap / leaveDate / diffDate，消除字符串位图解析的越界隐患。
--        修复 1970 年之前日期的整轮查询失败：Windows 的 mktime 不支持该范围，
--        os.time 会直接抛错并作废整轮候选；现改为只对 1971 年及以后计算星期。
--
-- 0.2.2: Analyze 补零由「补一位」改为循环补足 12 位，修复 1926/1935/1945/2007 四年
--        农历落在第 12、13 个月时查询报错的问题。
--        修正 9 项农历数据（1915、1916、1920、1955、1989、2025、2057、2089、2097）
--
-- 0.2.1: 数字转中文增加 13 位上限；translateInt 中原先恒为假的判断改为按位数限制，
--        避免大数生成错误的中文读法。
--        计算结果的「捨入」与中文候选限制在 |result| < 1e13，不再输出超长定点串。
--
-- 0.2.0: 新增 rq 入口用于日期偏移；Vrq 保留为当天，Vrq+n 不再生效。
--        计算器支持 k/m/b/t 数量级后缀。
--
-- 0.1.1: 修复 V.5 / V. 触发 Lua 错误。
--        修复 IsLeap 世纪年误判（1900、2100）。
--        计算结果不再显示 .0 后缀。
--        日期转换增加合法性校验，非法日期输出「日期无效」。
--        农历相关候选标签统一为繁体〔農曆〕〔錯誤〕。
--        清理失效的日期正则分支等死代码。
--        日期转换与 rq 共用 yield_date_group。
--
-- 0.1.0: 整合：简易计算器、四舍六入五取偶舍入、数字转中文大写金额、
--        公历转农历、日期偏移、V 空输入输出当天信息。


local function startsWith(str, start)
    return string.sub(str, 1, string.len(start)) == start
end

local function truncateFromStart(str, truncateStr)
    return string.sub(str, string.len(truncateStr) + 1)
end

-- ‌四舍六入五取偶法‌（来自 calculator.lua）
-- -- 基于 https://github.com/baopaau/rime-lua-collection/blob/master/calculator_translator.lua
local function round2(x, dc)
    local dc = dc or 1
    local fraction = x / dc
    local integer = math.floor(fraction)
    local remainder = fraction - integer

    if remainder < 0.5 then
        return integer * dc
    elseif remainder > 0.5 then
        return (integer + 1) * dc
    else
        if integer % 2 == 0 then
            return integer * dc
        else
            return (integer + 1) * dc
        end
    end
end

-- 添加的日期输出函数
local function yield_cand(seg, input, text, comment)
    local cand = Candidate('', seg.start, seg._end, text, comment)
    cand.quality = 10000
    yield(cand)
end

-- 星期名（文件级，日期组与 rq 共用）
local WEEKDAY_NAMES = { "周日", "周一", "周二", "周三", "周四", "周五", "周六" }

local function yield_weekday(seg, input, target_time)
    local weekday_text = os.date("%w", target_time)
    if not weekday_text then return end
    local wday = tonumber(weekday_text)
    if not wday then return end
    yield_cand(seg, input, WEEKDAY_NAMES[wday + 1], "")
end

local function format_number_without_trailing_zeros(num)
    local s = string.format("%.2f", num):gsub("0+$", ""):gsub("%.$", "")
    return s == "" and "0" or s
end

-- 整数值不再显示后缀'.0'
local function num_to_str(n)
    local i = math.tointeger(n)
    return i and tostring(i) or tostring(n)
end

-------------------------------------------------------------
---- 简单计算器部分
-- Author: https://github.com/ChaosAlphard
-- 说明 https://github.com/gaboolic/rime-shuangpin-fuzhuma/pull/41
-------------------------------------------------------------

-- 函数表
local FACTORIAL_ERROR = "阶乘仅支持0至170的整数"
local function factorial(x)
    if type(x) ~= "number" or x ~= x or x < 0 or x > 170 or x % 1 ~= 0 then
        error(FACTORIAL_ERROR, 0)
    end
    -- 20! 以内保持精确整数；更大结果用浮点数，避免整数回绕。
    local result = x <= 20 and 1 or 1.0
    for i = 2, x do result = result * i end
    return result
end

-- 2026-10-17: 阶乘范围保护与整数溢出修复；日期偏移范围保护。
local calcPlugin = {
    -- e, exp(1) = e^1 = e
    e = math.exp(1),
    -- π
    pi = math.pi,
    -- 国际单位数量级
    k = 10 ^ 3,    -- 千
    m = 10 ^ 6,    -- 百万
    b = 10 ^ 9,    -- 十亿
    t = 10 ^ 12,   -- 万亿
    -- 随机数
    rdm = function(...) return math.random(...) end,
    -- 三角函数
    sin = math.sin, cos = math.cos, tan = math.tan,
    asin = math.asin, acos = math.acos, atan = math.atan,
    sinh = math.sinh, cosh = math.cosh, tanh = math.tanh,
    atan2 = math.atan2,
    -- 角度转换
    deg = math.deg, rad = math.rad,
    -- 指数和对数
    exp = math.exp, sqrt = math.sqrt, ldexp = math.ldexp,
    log = function(x, y) return (x > 0 and y > 0) and math.log(y) / math.log(x) or nil end,
    loge = function(x) return x > 0 and math.log(x) or nil end,
    log10 = function(x) return x > 0 and math.log10(x) or nil end,
    -- 统计函数
    avg = function(...) local n = select("#", ...); if n == 0 then return nil end; local sum = 0; for i = 1, n do sum = sum + select(i, ...) end; return sum / n end,
    var = function(...) local n = select("#", ...); if n == 0 then return nil end; local sum, sum_sq = 0, 0; for i = 1, n do local v = select(i, ...); sum = sum + v; sum_sq = sum_sq + v * v end; return (sum_sq - sum * sum / n) / n end,
    -- 阶乘
    fact = factorial
}

-- 阶乘符号替换函数（保持原样，因为它已经是单行）
local function replaceToFactorial(str) return str:gsub("([0-9]+)!", "fact(%1)") end

-------------------------------------------------------------
-- 数字转中文大写金额部分（来自 moran_number.lua）
-- Author: ksqsf
-- License: GPLv3
-- Version: 0.1.1
-------------------------------------------------------------

local dot              = "点"
local digitRegular     = { [0] = "零", "一", "二", "三", "四", "五", "六", "七", "八", "九" }
local digitLower       = { [0] = "〇", "一", "二", "三", "四", "五", "六", "七", "八", "九" }
local digitUpper       = { [0] = "零", "壹", "贰", "叁", "肆", "伍", "陆", "柒", "捌", "玖" }
local digitHalfWidth   = { [0] = "0", "1", "2", "3", "4", "5", "6", "7", "8", "9" }
local unitLower        = { "", "十", "百", "千" }
local unitUpper        = { "", "拾", "佰", "仟" }
local bigUnit          = { "万", "亿" }
local currencyUnit     = "元"
local currencyFracUnit = { "角", "分", "厘", "毫" }

-- 解析浮點數字符串爲三元組 ( 整數部分字符串, 小數點字符串, 小數部分字符串 )
local function parseNumStr(str)
    local result = {}
    result.int, result.dot, result.frac = str:match("^(%d*)(%.?)(%d*)")
    if result.int == "" then result.int = "0" end
    -- if result.dot ~= "" and result.frac == "" then result.dot = "" end
    return result
end

-- 轉換 4 位整數節, 如 9909 -> 九千九百零九
local function translateIntSegment(int, digit, unit)
    local d = {
        int % 10,
        math.floor(int / 10) % 10,
        math.floor(int / 100) % 10,
        math.floor(int / 1000) % 10
    }
    local result = ""
    local lastPos = -1
    local i = 4
    while i >= 1 do
        if d[i] ~= 0 then
            if lastPos == -1 then
                lastPos = i
            end
            if lastPos - i > 1 then  -- 中間有空位, 增加'零'
                result = result .. digit[0]
            end
            result = result .. digit[d[i]] .. unit[i]
            lastPos = i
        end
        i = i - 1
    end
    return result
end

-- 將指數轉換成大數單位
-- 如 4->萬, 8->億
-- exponent 必須是4的倍數
local function translateBigUnit(exponent, bigUnit)
    exponent = math.floor(exponent / 4)
    local hiExp = #bigUnit    -- 最高大數單位
    local result = bigUnit[hiExp]:rep(math.floor(exponent / hiExp))
    exponent = exponent % hiExp
    local i = 1
    local prefix = ""
    while exponent ~= 0 do
        if exponent % 2 == 1 then
            prefix = bigUnit[i] .. prefix
        end
        exponent = math.floor(exponent / 2)
        i = i + 1
    end
    return prefix .. result
end

-- 轉換整數部分
local function translateInt(str, digit, unit, bigUnit)
    local int = tonumber(str)
    -- 原判断恒为假（传入的一定是整数串）；改为按位数限制，13 位以上不再转换
    if not int or math.floor(int) ~= int or #str > 13 then
        return "數值超限！"
    end
    if int == 0 then
        return digit[0]
    end
    local result = ""
    local exponent = 0
    local lastSegInt = 1000
    local first = true
    while int ~= 0 do
        local segInt = int % 10000
        local segStr = translateIntSegment(segInt, digit, unit)
        local unitStr = translateBigUnit(exponent, bigUnit)
        local filler = (lastSegInt < 1000 and not first) and digit[0] or ""
        result = segStr .. (segStr ~= "" and unitStr or "") .. filler .. result
        lastSegInt = segInt
        int = math.floor(int / 10000)
        exponent = exponent + 4
        if segInt ~= 0 then
            first = false
        end
    end
    return result
end

local function mapDigits(str, digit)
    return str:gsub("%d", function(c) return digit[tonumber(c)] or c end)
end

-- 轉換小數部分, 金額風格, 0123 -> 零角一分二釐
local function translateFracCurrency(str, digit, unit)
    local len = math.min(#unit, #str)
    local result = ""
    for i = 1, len do
        result = result .. digit[str:byte(i) - 0x30] .. unit[i]
    end
    local terminator = #str < 2 and "整" or ""
    return result .. terminator
end

-- 常規轉換
local function translateRegular(input)
    local res = translateInt(input.int, digitRegular, unitLower, bigUnit)
        .. (input.dot ~= "" and (dot .. mapDigits(input.frac, digitRegular)) or "")
    return res:gsub("^一十", "十")
end

local function translateUpper(input)
    return translateInt(input.int, digitUpper, unitUpper, bigUnit)
        .. (input.dot ~= "" and (dot .. mapDigits(input.frac, digitUpper)) or "")
end

local function translateLower(input)
    return translateInt(input.int, digitLower, unitLower, bigUnit)
        .. (input.dot ~= "" and (dot .. mapDigits(input.frac, digitLower)) or "")
end

local function translateHalfWidth(input)
    return mapDigits(input.int, digitHalfWidth)
        .. (input.dot ~= "" and ("." .. mapDigits(input.frac, digitHalfWidth)) or "")
end

-- 金額轉換
local function translateCurrency(input, digit, unit, bigUnit)
    local intPart = translateInt(input.int, digit, unit, bigUnit)
    local fracPart = translateFracCurrency(input.frac or "", digit, currencyFracUnit)
    return intPart .. currencyUnit .. fracPart
end

local function translateNumStr(str)
    local input = parseNumStr(str)
    local result = {
        { "〔常規〕", translateRegular(input), },
        { "〔編號〕", mapDigits(str, digitLower):gsub("%.", dot) },
        { "〔大寫〕", translateUpper(input) },
        { "〔金額大寫〕", translateCurrency(input, digitUpper, unitUpper, bigUnit) },
        { "〔金額小寫〕", translateCurrency(input, digitLower, unitLower, bigUnit) },
        { "〔半角〕", translateHalfWidth(input), },
    }
    return result
end

-------------------------------------------------------------
-- 公历转农历模块（来自 moran_shijian.lua）
-- from：Project Moran (https://github.com/rimeinn/rime-moran/blob/main/lua/moran_shijian.lua)
-- Author：98wubi Group (http://98wb.ys168.com/)
-------------------------------------------------------------

-- 常量
local cTianGan = {"甲","乙","丙","丁","戊","己","庚","辛","壬","癸"}
local cDiZhi   = {"子","丑","寅","卯","辰","巳","午","未","申","酉","戌","亥"}
local cShuXiang = {"鼠","牛","虎","兔","龙","蛇","马","羊","猴","鸡","狗","猪"}
local cMonName  = {"正月","二月","三月","四月","五月","六月","七月","八月","九月","十月","冬月","腊月"}
local cDayName  = {
    "初一","初二","初三","初四","初五","初六","初七","初八","初九","初十",
    "十一","十二","十三","十四","十五","十六","十七","十八","十九","二十",
    "廿一","廿二","廿三","廿四","廿五","廿六","廿七","廿八","廿九","三十"
}

-- 农历数据 (1900-2100)
local LunarData = {
    "AB500D2","4BD0883","4AE00DB","A5700D0","54D0581","D2600D8","D9500CC","655147D","56A00D5","9AD00CA",
    "55D027A","4AE00D2","A5B0682","A4D00DA","D2500CE","D25157E","B5400D6","D6A00CB","ADA027B","95B00D3",
    "49717C9","49700DC","A4B00D0","B4B0580","6A500D8","6D400CD","AB5147C","2B600D5","95700CA","52F027B",
    "49700D2","6560682","D4A00D9","EA500CE","6A9157E","5AD00D6","2B600CC","86E137C","92E00D3","C8D1783",
    "C9500DB","D4A00D0","D8A167F","B5500D7","56A00CD","A5B147D","25D00D5","92D00CA","D2B027A","A9500D2",
    "B550781","6CA00D9","B5500CE","535157F","4DA00D6","A5B00CB","457137C","52B00D4","A9A0883","E9500DA",
    "6AA00D0","AEA0680","AB500D7","4B600CD","AAE047D","A5700D5","52600CA","F260379","D9500D1","5B50782",
    "56A00D9","96D00CE","4DD057F","4AD00D7","A4D00CB","D4D047B","D2500D3","D550883","B5400DA","B6A00CF",
    "95A1680","95B00D8","49B00CD","A97047D","A4B00D5","B270ACA","6A500DC","6D400D1","AF40681","AB600D9",
    "95700CE","4AF057F","49700D7","64B00CC","74A037B","EA500D2","6B50883","5AC00DB","AB600CF","96D0580",
    "92E00D8","C9600CD","D95047C","D4A00D4","DA500C9","755027A","56A00D1","ABB0781","25D00DA","92D00CF",
    "CAB057E","A9500D6","B4A00CB","BAA047B","AD500D2","55D0983","4BA00DB","A5B00D0","5171680","52B00D8",
    "A9300CD","795047D","6AA00D4","AD500C9","5B5027A","4B600D2","A6E0681","A4E00D9","D2600CE","EA6057E",
    "D5300D5","5AA00CB","76A037B","96D00D3","4AF0B83","4AD00DB","A4D00D0","D0B1680","D2500D7","D5200CC",
    "DD4057C","B5A00D4","56D00C9","55B027A","49B00D2","A570782","A4B00D9","AA500CE","B25157E","6D200D6",
    "ADA00CA","4B6137B","93700D3","49F08C9","49700DB","64B00D0","68A1680","EA500D7","6AA00CC","A6C147C",
    "AAE00D4","92E00CA","D2E0379","C9600D1","D550781","D4A00D9","DA500CD","5D5057E","56A00D6","A6D00CB",
    "55D047B","52D00D3","A9B0883","A9500DB","B4A00CF","B6A067F","AD500D7","55A00CD","ABA047C","A5B00D4",
    "52B00CA","B27037A","69300D1","7330781","6AA00D9","AD500CE","4B5157E","4B600D6","A5700CB","54E047C",
    "D1600D2","E960882","D5200DA","DAA00CF","6AA167F","56D00D7","4AE00CD","A9D047D","A2D00D4","D1500C9",
    "F250279","D5200D1"
}

-- 公历闰年天数
local function year_days(year)
    year = tonumber(year)
    return (year % 400 == 0 or (year % 4 == 0 and year % 100 ~= 0)) and 366 or 365
end

-- 公历某月天数
local function month_days(year, month)
    if month == 2 then return year_days(year) == 366 and 29 or 28 end
    return ({ 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 })[month]
end

-- 公历整数日序（从公元 1 年 1 月 1 日起算，不含时区影响；闰年规则内建）
local function gregorian_day_number(year, month, day)
    local previous_year = year - 1
    local day_number = 365 * previous_year + math.floor(previous_year / 4)
        - math.floor(previous_year / 100) + math.floor(previous_year / 400) + day
    for previous_month = 1, month - 1 do
        day_number = day_number + month_days(year, previous_month)
    end
    return day_number
end

-- 农历年表：惰性解析 + 缓存，只在首次查询时构建一次
local lunar_years_cache = nil
local function lunar_years()
    if lunar_years_cache then return lunar_years_cache end
    local years = {}
    for year_index, encoded_year in ipairs(LunarData) do
        local year = year_index + 1898
        local month_size_bits = tonumber(encoded_year:sub(1, 3), 16)
        local leap_month = tonumber(encoded_year:sub(5, 5), 16)
        local new_year_mmdd = tonumber(encoded_year:sub(6, 7), 16)
        local months = {}
        for month = 1, 12 do
            months[#months + 1] = {
                month = month,
                leap = 0,
                days = 29 + math.floor(month_size_bits / 2 ^ (12 - month)) % 2,
            }
            if month == leap_month then
                months[#months + 1] = {
                    month = month,
                    leap = 1,
                    days = 29 + tonumber(encoded_year:sub(4, 4)),
                }
            end
        end
        years[year] = {
            new_year = gregorian_day_number(year, math.floor(new_year_mmdd / 100), new_year_mmdd % 100),
            months = months,
        }
    end
    lunar_years_cache = years
    return years
end

-- 公历 → 农历
local function solarToLunar(gregorian)
    gregorian = tostring(gregorian)
    local year = tonumber(gregorian:sub(1,4))
    local month = tonumber(gregorian:sub(5,6))
    local day = tonumber(gregorian:sub(7,8))
    if year < 1900 or year > 2100 then return "年份超出范围" end
    if not month or not day or month < 1 or month > 12 or day < 1 or day > month_days(year, month) then
        return "日期无效"
    end

    local years = lunar_years()
    local day_number = gregorian_day_number(year, month, day)
    local lunarYear = year
    if day_number < years[lunarYear].new_year then lunarYear = lunarYear - 1 end
    local remaining_days = day_number - years[lunarYear].new_year

    local lunarMonth, isLeap, lunarDay
    for _, month_info in ipairs(years[lunarYear].months) do
        if remaining_days < month_info.days then
            lunarMonth = month_info.month
            isLeap = month_info.leap == 1
            lunarDay = remaining_days + 1
            break
        end
        remaining_days = remaining_days - month_info.days
    end
    if not lunarDay then return "年份超出范围" end

    local gan = (lunarYear - 4) % 10 + 1
    local zhi = (lunarYear - 4) % 12 + 1
    local sx  = (lunarYear - 4) % 12 + 1
    local monthStr = isLeap and ("闰" .. cMonName[lunarMonth]) or cMonName[lunarMonth]
    return string.format("%s%s年(%s) %s%s",
        cTianGan[gan], cDiZhi[zhi], cShuXiang[sx], monthStr, cDayName[lunarDay])
end

-- 公历日期合法性校验
local function is_valid_date(y, m, d)
    y, m, d = tonumber(y), tonumber(m), tonumber(d)
    if not y or not m or not d then return false end
    if m < 1 or m > 12 or d < 1 then return false end
    return d <= month_days(y, m)
end

-- 输出一个公历日期的标准候选（不含时间戳）
local function yield_date_group(seg, input, y, m, d)
    if #y == 2 then y = "20" .. y end
    if #m == 1 then m = "0" .. m end
    if #d == 1 then d = "0" .. d end
    if not is_valid_date(y, m, d) then
        yield_cand(seg, input, "日期无效", "〔錯誤〕")
        return
    end
    local lunar_res = solarToLunar(y .. m .. d)
    if not lunar_res or lunar_res == "年份超出范围" then
        yield_cand(seg, input, "日期无效", "〔錯誤〕")
        return
    end
    yield_cand(seg, input, y .. "/" .. m .. "/" .. d, "")
    yield_cand(seg, input, y .. "-" .. m .. "-" .. d, "")
    yield_cand(seg, input, y .. m .. d, "")
    -- Windows 的 mktime 不支持 1970 年之前的日期，os.time 会直接抛错并作废整轮候选；
    -- 故只对 1971 年及以后计算星期，1970 及以前跳过星期候选（留一年余量以避开时区边界）。
    local year_number = tonumber(y)
    if year_number and year_number >= 1971 then
        local ts = os.time{ year = year_number, month = tonumber(m), day = tonumber(d), hour = 12 }
        if ts then yield_weekday(seg, input, ts) end
    end
    yield_cand(seg, input, lunar_res:match("%) (.+)") or lunar_res, "〔農曆〕")
    yield_cand(seg, input, lunar_res, "〔農曆〕")
end

-------------------------------------------------------------
-- 引导部分
-------------------------------------------------------------
local M = {}

function M.init(env)
    env.name_space = env.name_space:gsub('^*', '')
    M.prefix = 'V'
end

function M.func(input, seg, env)
    local express, is_rq
    if startsWith(input, M.prefix) then
        express = truncateFromStart(input, M.prefix)
        is_rq = false
    elseif input:match("^rq[+-]") then
        express = input
        is_rq = true
    else
        return
    end
    local current_time = os.time()
    -- 无任何内容：输出当前日期、时间戳、农历
    if express == "" then
        local lunar = solarToLunar(os.date('%Y%m%d', current_time))
        yield_cand(seg, input, os.date('%Y/%m/%d', current_time), "")
        yield_cand(seg, input, os.date('%Y-%m-%d', current_time), "")
        yield_cand(seg, input, os.date('%Y%m%d', current_time), "")
        yield_cand(seg, input, string.format('%d', current_time), "")
        yield_cand(seg, input, lunar:match("%) (.+)") or lunar, "")
        return
    end
    -- 公历转农历：支持 yyyy.mm.dd 或 mm.dd/ 格式
    local y, m, d
    y, m, d = express:match("^(%d%d%d?%d?)/(%d%d?)/(%d%d?)/?$")
    if not y then
        -- 再尝试点分隔
        y, m, d = express:match("^(%d%d%d?%d?)%.(%d%d?)%.(%d%d?)/?$")
    end
    if y then
        yield_date_group(seg, input, y, m, d)
        return
    end
    -- 处理仅月.日/ 格式
    local mm, dd = express:match("^(%d%d?)[%.%/](%d%d?)/$")
    if mm and dd then
        yield_date_group(seg, input, os.date('%Y', current_time), mm, dd)
        return
    end
    -- 日期偏移：rq 入口管偏移，Vrq 继续管“今天”
    local rq_offset = nil
    if is_rq then
        local sign, num = express:match("^rq([+-])(%d*)$")
        if sign then
            rq_offset = tonumber(num) or 0
            if sign == '-' then rq_offset = -rq_offset end
        end
    elseif express == 'rq' then
        rq_offset = 0
    end
    if rq_offset then
        if rq_offset ~= rq_offset or math.abs(rq_offset) > 3660000 then
            yield_cand(seg, input, "日期偏移超出范围", "〔錯誤〕")
            return
        end
        local target_time = current_time + rq_offset * 86400
        local ok_date, target_date = pcall(os.date, '%Y/%m/%d', target_time)
        local ok_compact, target_compact = pcall(os.date, '%Y%m%d', target_time)
        if not ok_date or not ok_compact or not target_date or not target_compact then
            yield_cand(seg, input, "日期偏移超出范围", "〔錯誤〕")
            return
        end
        yield_cand(seg, input, target_date, "")
        yield_cand(seg, input, (target_date:gsub("/", "-")), "")
        yield_cand(seg, input, target_compact, "")
        yield_weekday(seg, input, target_time)
        local lunar_full = solarToLunar(target_compact)
        local lunar_md = lunar_full:match("%) (.+)") or lunar_full
        yield_cand(seg, input, lunar_md, "〔農曆〕")
        yield_cand(seg, input, lunar_full, "〔農曆〕")
        return
    end
    -- 时间格式
    if express == 'sj' then
        yield_cand(seg, input, os.date('%Y-%m-%d %H:%M:%S', current_time), "本地")
        yield_cand(seg, input, os.date('!%Y-%m-%d %H:%M:%S', current_time), "UTC")
        yield_cand(seg, input, os.date('%Y-%m-%dT%H:%M:%S+08:00', current_time), "ISO8601")
        yield_cand(seg, input, os.date('%Y%m%d%H%M%S', current_time), "")
        return
    end
    -- 星期
    if express == 'week' or express == 'xq' then
        yield_weekday(seg, input, current_time)
        local wday = tonumber(os.date("%w", current_time))
        local weekdayTs = {"星期天", "星期一", "星期二", "星期三", "星期四", "星期五", "星期六"}
        yield_cand(seg, input, weekdayTs[wday+1], "")
        return
    end
    -- 长度不足2时不做计算
    -- if #express < 2 then return end
    -- 计算器部分
    local part_int, part_dot, part_dec = string.match(express, "^(%d*)(%.?)(%d*)$")
    if not part_int or not part_dot or not part_dec then
        local code = replaceToFactorial(express:gsub("(%d)([kmbt])", "%1*%2"))
        local success, result = pcall(load("return " .. code, "calculate", "t", calcPlugin))
        if success then
            if type(result) ~= "number" then
                yield(Candidate(input, seg.start, seg._end, express, "表達式"))
                return
            end
            local result_str = num_to_str(result)
            yield(Candidate(input, seg.start, seg._end, result_str, ""))
            yield(Candidate(input, seg.start, seg._end, express .. "=" .. result_str, ""))

            -- 使用新的数字转换函数：|result| >= 1e13 时 0.01 精度已无意义，跳过
            if math.abs(result) < 1e13 then
                local approx = string.format("%.2f", round2(result, 0.01))
                local new_param = format_number_without_trailing_zeros(approx)
                local conversions = translateNumStr(new_param)
                yield(Candidate(input, seg.start, seg._end, approx, "〔捨入〕"))
                yield(Candidate(input, seg.start, seg._end, conversions[1][2], conversions[1][1]))
                -- yield(Candidate(input, seg.start, seg._end, conversions[3][2], conversions[3][1]))
            end
        else
            local comment = result == FACTORIAL_ERROR and FACTORIAL_ERROR or "表達式"
            yield(Candidate(input, seg.start, seg._end, express, comment))
        end
    else
        -- 纯数字输入，直接转换
        local conversions = translateNumStr(express)
        for i = 1, #conversions do
            yield(Candidate(input, seg.start, seg._end, conversions[i][2], conversions[i][1]))
        end
    end
end

return M
