-- 整合：light
--简易计算器+‌四舍六入五取偶法‌
--金额大写
--日期输入


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

local function format_number_without_trailing_zeros(num)
    local s = string.format("%.2f", num):gsub("0+$", ""):gsub("%.$", "")
    return s == "" and "0" or s
end

-------------------------------------------------------------
---- 简单计算器部分
-- Author: https://github.com/ChaosAlphard
-- 说明 https://github.com/gaboolic/rime-shuangpin-fuzhuma/pull/41
-------------------------------------------------------------

-- 函数表
local calcPlugin = {
    -- e, exp(1) = e^1 = e
    e = math.exp(1),
    -- π
    pi = math.pi,
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
    fact = function(x) if x < 0 then return nil elseif x <= 1 then return 1 else local r = 1; for i = 2, x do r = r * i end; return r end end
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
local unitLower        = { "", "十", "百", "千" }
local unitUpper        = { "", "拾", "佰", "仟" }
local bigUnit          = { "万", "亿" }
local currencyUnit     = "元"
local currencyFracUnit = { "角", "分", "厘", "毫" }

-- 解析浮點數字符串爲三元組 ( 整數部分字符串, 小數點字符串, 小數部分字符串 )
local function parseNumStr(str)
    local result = {}
    result.int, result.dot, result.frac = str:match("^(%d*)(%.?)(%d*)")
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
    if math.floor(int) ~= int then
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
    "55D027A","4AE00D2","A5B0682","A4D00DA","D2500CE","D25157E","B5500D6","56A00CC","ADA027B","95B00D3",
    "49717C9","49B00DC","A4B00D0","B4B0580","6A500D8","6D400CD","AB5147C","2B600D5","95700CA","52F027B",
    "49700D2","6560682","D4A00D9","EA500CE","6A9157E","5AD00D6","2B600CC","86E137C","92E00D3","C8D1783",
    "C9500DB","D4A00D0","D8A167F","B5500D7","56A00CD","A5B147D","25D00D5","92D00CA","D2B027A","A9500D2",
    "B550781","6CA00D9","B5500CE","535157F","4DA00D6","A5B00CB","457037C","52B00D4","A9A0883","E9500DA",
    "6AA00D0","AEA0680","AB500D7","4B600CD","AAE047D","A5700D5","52600CA","F260379","D9500D1","5B50782",
    "56A00D9","96D00CE","4DD057F","4AD00D7","A4D00CB","D4D047B","D2500D3","D550883","B5400DA","B6A00CF",
    "95A1680","95B00D8","49B00CD","A97047D","A4B00D5","B270ACA","6A500DC","6D400D1","AF40681","AB600D9",
    "93700CE","4AF057F","49700D7","64B00CC","74A037B","EA500D2","6B50883","5AC00DB","AB600CF","96D0580",
    "92E00D8","C9600CD","D95047C","D4A00D4","DA500C9","755027A","56A00D1","ABB0781","25D00DA","92D00CF",
    "CAB057E","A9500D6","B4A00CB","BAA047B","AD500D2","55D0983","4BA00DB","A5B00D0","5171680","52B00D8",
    "A9300CD","795047D","6AA00D4","AD500C9","5B5027A","4B600D2","96E0681","A4E00D9","D2600CE","EA6057E",
    "D5300D5","5AA00CB","76A037B","96D00D3","4AF0B83","4AD00DB","A4D00D0","D0B1680","D2500D7","D5200CC",
    "DD4057C","B5A00D4","56D00C9","55B027A","49B00D2","A570782","A4B00D9","AA500CE","B25157E","6D200D6",
    "ADA00CA","4B6137B","93700D3","49F08C9","49700DB","64B00D0","68A1680","EA500D7","6B200CC","A6C147C",
    "AAE00D4","92E00CA","D2E0379","C9600D1","D550781","D4A00D9","DA500CD","5D5057E","56A00D6","A6D00CB",
    "55D047B","52D00D3","A9B0883","A9500DB","B4A00CF","B6A067F","AD500D7","55A00CD","ABA047C","A5B00D4",
    "52B00CA","B27037A","69300D1","7330781","6AA00D9","AD500CE","4B5157E","4B600D6","A5700CB","54E047C",
    "D2600D2","E960882","D5200DA","DAA00CF","6AA167F","56D00D7","4AE00CD","A9D047D","A4D00D4","D1500C9",
    "F250279","D5200D1"
}

-- 辅助函数
local function Dec2bin(n)
    local t = {}
    while math.floor(n / 2) >= 1 do
        table.insert(t, 1, n % 2)
        n = math.floor(n / 2)
        if n == 1 then table.insert(t, 1, 1) end
    end
    return table.concat(t):gsub("^0+", "")
end

local function system(x, inType, outType)
    x = tostring(x)
    if inType == 2 then
        if outType == 10 then return tonumber(x, 2)
        elseif outType == 16 then return string.format("%X", tonumber(x, 2)) end
    elseif inType == 10 then
        if outType == 2 then return Dec2bin(tonumber(x))
        elseif outType == 16 then return string.format("%X", x) end
    elseif inType == 16 then
        if outType == 2 then return Dec2bin(tonumber(x, 16))
        elseif outType == 10 then return tonumber(x, 16) end
    end
end

local function Analyze(Data)
    local rtn1 = system(Data:sub(1,3), 16, 2)
    if #rtn1 < 12 then rtn1 = "0" .. rtn1 end
    local rtn2 = Data:sub(4,4)
    local rtn3 = system(Data:sub(5,5), 16, 10)
    local rtn4 = system(Data:sub(-2,-1), 16, 10)
    if #tostring(rtn4) == 3 then rtn4 = "0" .. rtn4 end
    return {rtn1, rtn2, rtn3, rtn4}
end

local function IsLeap(y)
    y = tonumber(y)
    return (y % 400 ~= 0 and y % 4 == 0) or (y % 400 == 0)
end

local function leaveDate(yyyymmdd)
    local y = tonumber(yyyymmdd:sub(1,4))
    local m = tonumber(yyyymmdd:sub(5,6))
    local d = tonumber(yyyymmdd:sub(7,8))
    local days = IsLeap(y) and {31,29,31,30,31,30,31,31,30,31,30,31}
                            or {31,28,31,30,31,30,31,31,30,31,30,31}
    local total = 0
    for i = 1, m-1 do total = total + days[i] end
    return total + d
end

local function diffDate(date1, date2)
    if date2 < date1 then return -1 end
    local y1, y2 = date1:sub(1,4), date2:sub(1,4)
    if y1 == y2 then
        return leaveDate(date2) - leaveDate(date1)
    end
    local total = IsLeap(y1) and 366 or 365
    total = total - leaveDate(date1) + leaveDate(date2)
    for y = tonumber(y1)+1, tonumber(y2)-1 do
        total = total + (IsLeap(y) and 366 or 365)
    end
    return total
end

-- 公历 → 农历
local function solarToLunar(gregorian)
    gregorian = tostring(gregorian)
    local year = tonumber(gregorian:sub(1,4))
    local month = tonumber(gregorian:sub(5,6))
    local day = tonumber(gregorian:sub(7,8))
    if year < 1900 or year > 2100 then return "年份超出范围" end

    local pos = year - 1900 + 2
    local Data1 = LunarData[pos]
    local tb1 = Analyze(Data1)
    local monthInfo, leapInfo, leap, newyear = tb1[1], tb1[2], tb1[3], tb1[4]
    local date1 = year .. newyear
    local date3 = diffDate(date1, gregorian)
    if date3 < 0 then
        year = year - 1
        local Data0 = LunarData[pos-1]
        tb1 = Analyze(Data0)
        monthInfo, leapInfo, leap, newyear = tb1[1], tb1[2], tb1[3], tb1[4]
        date1 = year .. newyear
        date3 = diffDate(date1, gregorian)
    end
    date3 = date3 + 1
    local lunarYear = year
    local thisMonthInfo = leap > 0 and (monthInfo:sub(1,leap) .. leapInfo .. monthInfo:sub(leap+1)) or monthInfo
    local lunarMonth, isLeap, lunarDay
    for i = 1, 13 do
        local days = 29 + thisMonthInfo:sub(i,i)
        if date3 > days then
            date3 = date3 - days
        else
            if leap > 0 then
                if leap >= i then
                    lunarMonth, isLeap = i, false
                else
                    lunarMonth, isLeap = i - 1, (i - leap == 1)
                end
            else
                lunarMonth, isLeap = i, false
            end
            lunarDay = math.floor(date3)
            break
        end
    end

    local gan = (lunarYear - 4) % 10 + 1
    local zhi = (lunarYear - 4) % 12 + 1
    local sx  = (lunarYear - 4) % 12 + 1
    local monthStr = isLeap and ("闰" .. cMonName[lunarMonth]) or cMonName[lunarMonth]
    return string.format("%s%s年(%s) %s%s",
        cTianGan[gan], cDiZhi[zhi], cShuXiang[sx], monthStr, cDayName[lunarDay])
end

-------------------------------------------------------------
-- 引导部分
-------------------------------------------------------------
local M = {}

function M.init(env)
    local config = env.engine.schema.config
    env.name_space = env.name_space:gsub('^*', '')
    M.prefix = 'V'
end

function M.func(input, seg, env)
    if not startsWith(input, M.prefix) then return end
    -- 提取算式
    local express = truncateFromStart(input, M.prefix)    --移除前缀
    local current_time = os.time()
    local lunar = solarToLunar(os.date('%Y%m%d', current_time))
    
    -- 新增：只输入V时输出日期
    if express == "" then
        yield_cand(seg, input, os.date('%Y/%m/%d', current_time), "")
        yield_cand(seg, input, os.date('%Y%m%d', current_time), "")
        yield_cand(seg, input, string.format('%d', current_time), "")
        yield_cand(seg, input, lunar:match("^.*%) (.*)$"), "")
        return
    end
    
    -- 新功能：公历转农历，格式 xxxx.xx.xx 或 xx.xx.xx
    local y, m, d = express:match("^(%d%d%d?%d?)[%.%/](%d%d?)[%.%/](%d%d?)$")
    if y and m and d then
        -- 补全两位年份
        if #y == 2 then y = "20" .. y end
        if #m == 1 then m = "0" .. m end
        if #d == 1 then d = "0" .. d end
        local gregorian = y .. m .. d
        local lunar = solarToLunar(gregorian)
        if lunar and lunar ~= "年份超出范围" then
            yield(Candidate(input, seg.start, seg._end, lunar, "〔农历〕"))
        else
            yield(Candidate(input, seg.start, seg._end, "日期无效", "〔错误〕"))
        end
        return
    end
    local m, d = express:match("^(%d%d?)[%.%/](%d%d?)%/$")
    if m and d then
        -- 补全两位年份
        y = os.date('%Y', current_time)
        if #m == 1 then m = "0" .. m end
        if #d == 1 then d = "0" .. d end
        local gregorian = y .. m .. d
        local lunar = solarToLunar(gregorian)
        if lunar and lunar ~= "年份超出范围" then
            yield(Candidate(input, seg.start, seg._end, lunar, "〔农历〕"))
            return
        else
            yield(Candidate(input, seg.start, seg._end, "日期无效", "〔错误〕"))
        end
    end

    -- 日期对应
    if express == 'rq' then
        -- local year,lunar = solarToLunar(os.date('%Y%m%d', current_time))
        yield_cand(seg, input, os.date('%Y/%m/%d', current_time), "")
        yield_cand(seg, input, os.date('%Y%m%d', current_time), "")
        yield_cand(seg, input, os.date('%Y-%m-%d', current_time), "")
        yield_cand(seg, input, lunar:match("^.*%) (.*)$"), "农历")
        yield_cand(seg, input, lunar, "农历")
        return
    end
    
    -- 算式长度 < 2 直接终止(没有计算意义)
    if (string.len(express) < 2) then return end

    local part_int, part_dot, part_dec = string.match(express, "^(%d*)(%.?)(%d*)$")
    if not part_int or not part_dot or not part_dec then
        local code = replaceToFactorial(express)   --将阶乘符号换成lua的格式 
        local success, result = pcall(load("return " .. code, "calculate", "t", calcPlugin))
        if success then
            -- 确保 result 是数字类型
            if type(result) ~= "number" then
                -- 不是数字（可能是函数），视为解析失败
                yield(Candidate(input, seg.start, seg._end, express, "解析失败"))
                return
            end

            local result_str = tostring(result)
            yield(Candidate(input, seg.start, seg._end, result_str, ""))
            yield(Candidate(input, seg.start, seg._end, express .. "=" .. result_str, ""))

            -- 使用新的数字转换函数
            local approx = string.format("%.2f", round2(result, 0.01))
            local new_param = format_number_without_trailing_zeros(approx)
            local conversions = translateNumStr(new_param)
            yield(Candidate(input, seg.start, seg._end, approx, "〔捨入〕"))
            yield(Candidate(input, seg.start, seg._end, conversions[1][2], conversions[1][1]))
            yield(Candidate(input, seg.start, seg._end, conversions[3][2], conversions[3][1]))
        else
            yield(Candidate(input, seg.start, seg._end, express, "解析失败"))
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