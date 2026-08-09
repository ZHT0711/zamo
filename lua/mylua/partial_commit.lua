-- @amzxyz  https://github.com/amzxyz/rime_wanxiang
-- @skowosy 进行记忆功能的整合
-- Ctrl+1..9,0：上屏首选前 N 字；Shift+Ctrl+1..7：从开头选中 N 个音节
local wanxiang = require("wanxiang/wanxiang")

local M = {}

local function is_chinese_only(text)
    if not text or text == "" or text:match("[%w%p]") then
        return false
    end
    for _, cp in utf8.codes(text) do
        if not (
            (cp >= 0x4E00 and cp <= 0x9FFF) or
            (cp >= 0x3400 and cp <= 0x4DBF) or
            (cp >= 0x20000 and cp <= 0x2EBEF)
        ) then
            return false
        end
    end
    return true
end

-- 从候选的词典编码中取得规范音节。不能使用 context.input 的前缀，
-- 因为它可能是双拼或经过 algebra 变换的用户输入码。
local function decode_candidate(memory, cand, limit)
    if not memory or not cand or limit <= 0 then
        return nil
    end

    local genuine = cand
    if type(cand.get_genuine) == "function" then
        local ok, value = pcall(function() return cand:get_genuine() end)
        if ok and value then genuine = value end
    end

    local sources = { genuine }
    if type(genuine.get_genuines) == "function" then
        local ok, values = pcall(function() return genuine:get_genuines() end)
        if ok and type(values) == "table" then
            for _, value in ipairs(values) do
                table.insert(sources, value)
            end
        end
    end

    local seen = {}
    for _, source in ipairs(sources) do
        if source and not seen[source] then
            seen[source] = true

            local entries = {}
            if type(source.to_sentence) == "function" then
                local ok, sentence = pcall(function() return source:to_sentence() end)
                if ok and sentence and sentence.entrys then
                    for _, entry in ipairs(sentence.entrys) do
                        table.insert(entries, entry)
                    end
                end
            end
            if #entries == 0 and type(source.to_phrase) == "function" then
                local ok, phrase = pcall(function() return source:to_phrase() end)
                if ok and phrase then
                    if phrase.entry then table.insert(entries, phrase.entry) end
                    if #entries == 0 and phrase.code then
                        table.insert(entries, phrase)
                    end
                end
            end
            if #entries == 0 and source.entry then
                table.insert(entries, source.entry)
            end
            if #entries == 0 then
                table.insert(entries, source)
            end

            local parts = {}
            for _, entry in ipairs(entries) do
                local code = entry and entry.code
                if code then
                    local ok, decoded = pcall(function() return memory:decode(code) end)
                    if ok and type(decoded) == "table" then
                        for _, syllable in ipairs(decoded) do
                            if syllable and syllable ~= "" then
                                table.insert(parts, syllable)
                            end
                        end
                    end
                end
            end

            if #parts >= limit then
                local result = {}
                for i = 1, limit do result[i] = parts[i] end
                return result
            end
        end
    end

    return nil
end

-- 数字键映射（主键盘 + 小键盘）
local DIGIT = { [0x31]=1,[0x32]=2,[0x33]=3,[0x34]=4,[0x35]=5,[0x36]=6,[0x37]=7,[0x38]=8,[0x39]=9,[0x30]=10 }
local KP    = { [0xFFB1]=1,[0xFFB2]=2,[0xFFB3]=3,[0xFFB4]=4,[0xFFB5]=5,[0xFFB6]=6,[0xFFB7]=7,[0xFFB8]=8,[0xFFB9]=9,[0xFFB0]=10 }

-- Windows 前端可能把 Shift+数字报告为符号键码，所以两种形式都要识别。
local SHIFT_CTRL_DIGIT = {
    [0x31]=1, [0x32]=2, [0x33]=3, [0x34]=4, [0x35]=5, [0x36]=6, [0x37]=7,
    [0x21]=1, [0x40]=2, [0x23]=3, [0x24]=4, [0x25]=5, [0x5E]=6, [0x26]=7,
}
local SHIFT_CTRL_NAME = {
    ["1"]=1, ["2"]=2, ["3"]=3, ["4"]=4, ["5"]=5, ["6"]=6, ["7"]=7,
    exclam=1, at=2, numbersign=3, dollar=4, percent=5, asciicircum=6, ampersand=7,
    ["!"]=1, ["@"]=2, ["#"]=3, ["$"]=4, ["%"]=5, ["^"]=6, ["&"]=7,
}

local function get_shift_ctrl_digit(key)
    if not key:ctrl() or not key:shift() or key:release() then
        return nil
    end
    local n = SHIFT_CTRL_DIGIT[key.keycode]
    if n then return n end
    local repr = key:repr() or ""
    return SHIFT_CTRL_NAME[repr:match("([^+]+)$")]
end

local function select_from_home(env, n)
    local sequence = { "{Home}" }
    for _ = 1, n do
        table.insert(sequence, "{Shift+Right}")
    end
    for _, event in ipairs(KeySequence(table.concat(sequence)):toKeyEvent()) do
        env.engine:process_key(event)
    end
end

-- 取候选前 n 个字符
local function utf8_head(s, n)
    if not s or s == "" or n <= 0 then return "" end
    local offset = utf8.offset(s, n + 1)
    return offset and s:sub(1, offset - 1) or s
end

-- 事务级状态挂起模块
local function set_pending(env, rest)
    env._cpc_pending_rest = rest or ""
end
local function has_pending(env)
    return type(env._cpc_pending_rest) == "string" and env._cpc_pending_rest ~= nil
end
local function take_pending(env)
    local r = env._cpc_pending_rest
    env._cpc_pending_rest = nil
    return r
end

function M.init(env)
    local ctx = env.engine.context

    -- 局部提交绕过了正常的 translator memorize 流程，因此单独写入主用户词典。
    env._cpc_memory = Memory(env.engine, env.engine.schema, "frequency")

    -- 监听器：在上屏动作完成后，立刻将截断后的剩余拼音恢复到输入框
    env._cpc_update_conn = ctx.update_notifier:connect(function(c)
        if not has_pending(env) then return end
        local rest = take_pending(env) or ""

        c.input = rest
        if c.clear_non_confirmed_composition then
            c:clear_non_confirmed_composition()
        end
        if c.caret_pos ~= nil then
            c.caret_pos = #rest
        end
    end)

    -- 核心拦截器
    env._cpc_key_handler = function(key)
        local c = env.engine.context

        local select_count = get_shift_ctrl_digit(key)
        if select_count then
            if not c:is_composing() then
                return wanxiang.RIME_PROCESS_RESULTS.kNoop
            end
            select_from_home(env, select_count)
            return wanxiang.RIME_PROCESS_RESULTS.kAccepted
        end

        if not key:ctrl() or key:shift() or key:release() then
            return wanxiang.RIME_PROCESS_RESULTS.kNoop
        end

        local n = DIGIT[key.keycode] or KP[key.keycode]
        if not n then return wanxiang.RIME_PROCESS_RESULTS.kNoop end

        if not c:is_composing() then
            return wanxiang.RIME_PROCESS_RESULTS.kNoop
        end

        local cand = c:get_selected_candidate() or c:get_candidate(0)
        if not cand or not cand.text or #cand.text == 0 then
            return wanxiang.RIME_PROCESS_RESULTS.kNoop
        end

        -- 直接调用底层 spans 获取物理切分坐标
        local spans = c.composition:spans()
        if not spans then return wanxiang.RIME_PROCESS_RESULTS.kNoop end
        local count = type(spans.count) == "function" and spans:count() or spans.count
        if not count or count == 0 then return wanxiang.RIME_PROCESS_RESULTS.kNoop end
        
        local vertices = type(spans.vertices) == "function" and spans:vertices() or spans.vertices
        if not vertices or #vertices < 2 then return wanxiang.RIME_PROCESS_RESULTS.kNoop end

        -- 防呆保护：取 期望长度(N)、实际拼音音节数、候选词字符数 三者中的最小值
        local available_syllables = #vertices - 1
        local cand_len = utf8.len(cand.text) or 0
        n = math.min(n, available_syllables, cand_len)
        if n <= 0 then return wanxiang.RIME_PROCESS_RESULTS.kNoop end
        -- 获取需要上屏的中文候选字串
        local head = utf8_head(cand.text, n)

        -- 记忆由前 N 个音节形成的词。单字不写入词典；候选没有可解码词典编码时跳过。
        if n > 1 and is_chinese_only(head) and env._cpc_memory then
            local code_parts = decode_candidate(env._cpc_memory, cand, n)
            if code_parts then
                local entry = DictEntry()
                entry.text = head
                entry.weight = 1
                entry.custom_code = table.concat(code_parts, " ") .. " "
                env._cpc_memory:update_userdict(entry, 1, "")
            end
        end

        -- 【神级一刀切】：利用 vertices 拿到第 n 个音节的精确字节偏移量
        local cut_byte = vertices[n + 1]
        -- 截取剩余的 raw_input
        local rest = c.input:sub(cut_byte + 1)
        -- 如果剩余输入首字符是手动输入的分隔符（比如 ' ），顺手切掉保证清爽
        if rest:sub(1, 1) == "'" or rest:sub(1, 1) == " " then 
            rest = rest:sub(2) 
        end
        -- 提交前 n 个字
        env.engine:commit_text(head)
        -- 挂起剩余拼音，触发 update_notifier 恢复
        set_pending(env, rest)
        c:refresh_non_confirmed_composition()

        return wanxiang.RIME_PROCESS_RESULTS.kAccepted
    end
end

function M.fini(env)
    if env._cpc_update_conn then
        env._cpc_update_conn:disconnect()
        env._cpc_update_conn = nil
    end
    if env._cpc_memory then
        env._cpc_memory:disconnect()
        env._cpc_memory = nil
    end
    env._cpc_key_handler = nil
end

function M.func(key, env)
    if not env._cpc_key_handler then
        return wanxiang.RIME_PROCESS_RESULTS.kNoop
    end
    return env._cpc_key_handler(key)
end

return M
