-- 使用触发键对双拼进行形码的输入
-- 参考: https://github.com/HowcanoeWang/rime-lua-aux-code
-- 
-- 功能特性：
-- 1. 支持数据库和内存两种存储模式，可通过配置切换
-- 2. 可自定义触发键，默认为分号";"
-- 3. 支持设置辅助码注释显示方式（始终显示/触发后显示/始终不显示）
-- 4. 支持单字优先和词组优先两种候选排序模式，开关名字为char_priority
-- 5. 自动检测辅助码文件变化并重建数据库
-- 6. 支持多方案辅助码文件，根据name_space自动选择
-- 7. 持续选词上屏时保持辅助码分隔符存在
-- 8. 支持用触发键分割辅助码，依次匹配词组中的每个字
-- 9. 支持辅助码触发后仅输出词语（过滤单字候选），单字候选完全跳过辅助码计算，提升触发后的候选性能
-- 
-- 配置示例：
--   aux_code:
--     storage: "db"           # 存储模式：db=数据库，text=内存
--     trigger_word: ";"       # 触发键
--     show_aux_notice: "always" # 显示辅助码注释方式：always=总是显示，trigger=触发后显示，none=始终不显示
--     phrase_only: true        # 辅助码触发后是否只输出词语，过滤掉单字候选（默认false，不影响主输入模式）

local AuxFilter = {}
local bit = require("lib/bit")
local userdb = require("lib/userdb")
local wanxiang = require("wanxiang")

-- 配置项默认值
local DEFAULT_CONFIG = {
    storage = "db",           -- 存储模式：db=数据库，text=内存
    trigger_word = ";",       -- 触发键
    show_aux_notice = "always", -- 显示辅助码注释方式
    phrase_only = false       -- 辅助码触发后是否只输出词语，过滤单字候选
}

-- 获取文件内容哈希值，使用 FNV-1a 哈希算法
local function calculate_file_hash(filepath)
    local file, close_file, actual_path = wanxiang.load_file_with_fallback(filepath, "rb")
    if not file then return nil end

    -- FNV-1a 哈希参数（32位）
    local FNV_OFFSET_BASIS = 0x811C9DC5
    local FNV_PRIME = 0x01000193

    local hash = FNV_OFFSET_BASIS
    while true do
        local chunk = file:read(4096)
        if not chunk then break end
        for i = 1, #chunk do
            local byte = string.byte(chunk, i)
            hash = bit.bxor(hash, byte)
            hash = (hash * FNV_PRIME) % 0x100000000
            hash = bit.band(hash, 0xFFFFFFFF)
        end
    end

    close_file()
    return string.format("%08x", hash)
end

local function alt_lua_punc(s)
    if s then
        return s:gsub('([%.%+%-%*%?%[%]%^%$%(%)%%])', '%%%1')
    else
        return ''
    end
end

-- 元数据键
local META_KEY = {
    file_hash = "file_hash",
}

local AUX_CODE_CACHE_LIMIT = 8192
local AUX_SLOT_CACHE_LIMIT = 4096
local FULL_AUX_CACHE_LIMIT = 4096
local COMMENT_CACHE_LIMIT = 4096

-- 触发辅助码后，单次按键最多处理这么多候选就停止遍历。
-- 候选框本来也显示不了那么多，超出部分继续跑 get_aux_code/fullAux 纯属浪费。
local MAX_PROCESSED_AFTER_TRIGGER = 60

-- The filter runs once per keystroke and visits every candidate. Keep its
-- static dictionary results bounded so a long-running input method stays fast.
local function cache_put(env, cache_name, queue_name, head_name, limit, key, value)
    local cache = env[cache_name]
    if cache[key] ~= nil then
        cache[key] = value
        return
    end
    local queue = env[queue_name]
    if #queue < limit then
        queue[#queue + 1] = key
    else
        -- 固定大小的环形队列：淘汰时不再复制整个队列。
        local head = env[head_name]
        cache[queue[head]] = nil
        queue[head] = key
        env[head_name] = head % limit + 1
    end
    cache[key] = value
end

-- 从文件加载数据到内存
local function load_memory_dict(env, filename)
    env.memory_aux_code = {}
    
    local file, close_file = wanxiang.load_file_with_fallback(filename, "r")
    if not file then
        return {}
    end

    for line in file:lines() do
        line = line:match("[^\r\n]+") or ""
        local key, value = line:match("([^=]+)=(.+)")
        if key and value then
            if env.memory_aux_code[key] then
                env.memory_aux_code[key] = env.memory_aux_code[key] .. " " .. value
            else
                env.memory_aux_code[key] = value
            end
        end
    end
    close_file()
    
    return env.memory_aux_code
end

-- 从文件初始化数据库
local function init_db_from_file(env, filename)
    local aux_db = env.aux_db
    local file, close_file = wanxiang.load_file_with_fallback(filename, "r")
    if not file then
        return
    end

    for line in file:lines() do
        line = line:match("[^\r\n]+") or ""
        local key, value = line:match("([^=]+)=(.+)")
        if key and value then
            local db_key = env.current_aux_file .. ":" .. key
            local existing = aux_db:fetch(db_key) or ""
            if existing ~= "" then
                existing = existing .. " " .. value
            else
                existing = value
            end
            aux_db:update(db_key, existing)
        end
    end
    close_file()
end

function AuxFilter.init(env)
    local engine = env.engine
    local config = engine.schema.config

    -- 读取存储模式配置
    env.storage_mode = config:get_string("aux_code/storage") or DEFAULT_CONFIG.storage
    
    -- 设置默认触发键为分号，并从配置中读取自定义的触发键
    env.trigger_key = config:get_string("aux_code/trigger_word") or DEFAULT_CONFIG.trigger_word
    env.trigger_key_string = alt_lua_punc(env.trigger_key)
    
    -- 设定是否显示辅助码，默认为显示
    env.show_aux_notice = config:get_string("aux_code/show_aux_notice") or DEFAULT_CONFIG.show_aux_notice

    -- 是否在辅助码触发后只输出词语（过滤单字候选，单字不参与辅助码计算，提升性能）
    local phrase_only_cfg = config:get_bool("aux_code/phrase_only")
    if phrase_only_cfg == nil then
        phrase_only_cfg = DEFAULT_CONFIG.phrase_only
    end
    env.phrase_only = phrase_only_cfg

    env.aux_code_cache = {}
    env.aux_code_cache_queue = {}
    env.aux_code_cache_head = 1
    env.aux_slot_cache = {}
    env.aux_slot_cache_queue = {}
    env.aux_slot_cache_head = 1
    env.full_aux_cache = {}
    env.full_aux_cache_queue = {}
    env.full_aux_cache_head = 1
    env.comment_cache = {}
    env.comment_cache_queue = {}
    env.comment_cache_head = 1

    -- 确定辅助码文件
    local filename = "lua/aux_code/ZRM_Aux-code.txt"
    if env.name_space and env.name_space ~= "" then
        local custom_filename = "lua/aux_code/" .. env.name_space .. ".txt"
        local custom_file_path = wanxiang.get_filename_with_fallback(custom_filename)
        if custom_file_path and wanxiang.file_exists(custom_file_path) then
            filename = custom_filename
        end
    end
    
    env.current_aux_file = filename:match("([^/]+)%.txt$") or "ZRM_Aux-code"
    env.aux_db_prefix = env.current_aux_file .. ":"
    
    -- 初始化数据库引用
    env.aux_db = nil
    
    if env.storage_mode == "db" then
        local aux_db = userdb.LevelDb("lua/aux_code")
        env.aux_db = aux_db
        aux_db:open()
        
        local needs_rebuild = false
        local file_hash = calculate_file_hash(filename) or ""
        local stored_file_hash = aux_db:meta_fetch(env.current_aux_file .. ":" .. META_KEY.file_hash)
        if stored_file_hash ~= file_hash then
            needs_rebuild = true
        end
        
        if needs_rebuild then
            aux_db:query_with(env.current_aux_file .. ":", function(key, value)
                aux_db:erase(key)
            end)
            init_db_from_file(env, filename)
            aux_db:meta_update(env.current_aux_file .. ":" .. META_KEY.file_hash, file_hash)
        end
        
        aux_db:close()
        aux_db:open_read_only()
    else
        env.memory_aux_code = load_memory_dict(env, filename)
    end

    -- 持续选词上屏，保持辅助码分隔符存在
    env.notifier = engine.context.select_notifier:connect(function(ctx)
        local input = ctx.input
        local no_aux = input:match('^(.-)' .. env.trigger_key_string)
        if not no_aux or #no_aux == 0 then return end

        local preedit = ctx:get_preedit()
        local edit = preedit.text:match('^(.-)' .. env.trigger_key_string)
        if edit and edit:match('[%w/]') then
            ctx.input = no_aux .. env.trigger_key
        else
            ctx.input = no_aux
            ctx:commit()
        end
    end)
end

function AuxFilter.get_aux_code(env, char)
    local cached = env.aux_code_cache[char]
    if cached ~= nil then
        return cached or nil
    end

    local code
    if env.storage_mode == "db" then
        if not env.current_aux_file then return nil end
        local db_key = env.aux_db_prefix .. char
        code = env.aux_db:fetch(db_key)
    else
        code = env.memory_aux_code[char]
    end

    cache_put(env, "aux_code_cache", "aux_code_cache_queue", "aux_code_cache_head",
        AUX_CODE_CACHE_LIMIT, char, code or false)
    return code
end

local function table_keys(t)
    local keys = {}
    for key, _ in pairs(t) do
        table.insert(keys, key)
    end
    return keys
end

function AuxFilter.fullAux(env, word)
    local cached = env.full_aux_cache[word]
    if cached ~= nil then
        return cached
    end

    local fullAuxCodes = {}
    local charIndex = 0
    for _, codePoint in utf8.codes(word) do
        local char = utf8.char(codePoint)
        local charSlots = env.aux_slot_cache[char]
        if charSlots == nil then
            local charAuxCodes = AuxFilter.get_aux_code(env, char)
            if charAuxCodes then
                charSlots = {}
                for code in charAuxCodes:gmatch("%S+") do
                    for i = 1, #code do
                        charSlots[i] = charSlots[i] or {}
                        charSlots[i][code:sub(i, i)] = true
                    end
                end
                for i, chars in pairs(charSlots) do
                    charSlots[i] = table.concat(table_keys(chars), "")
                end
            else
                charSlots = false
            end
            cache_put(env, "aux_slot_cache", "aux_slot_cache_queue", "aux_slot_cache_head",
                AUX_SLOT_CACHE_LIMIT, char, charSlots)
        end

        if charSlots then
            local base = charIndex * 2
            for i, chars in pairs(charSlots) do
                fullAuxCodes[base + i] = chars
            end
            charIndex = charIndex + 1
        end
    end

    cache_put(env, "full_aux_cache", "full_aux_cache_queue", "full_aux_cache_head",
        FULL_AUX_CACHE_LIMIT, word, fullAuxCodes)
    return fullAuxCodes
end

-- 辅助码注释字符串按词缓存，避免同一个词每次按键都重新拼接一遍
function AuxFilter.get_comment(env, word, auxCodes, fullAuxCodes)
    local cached = env.comment_cache[word]
    if cached ~= nil then
        return cached or nil
    end

    local comment = nil
    if auxCodes and #auxCodes > 0 then
        comment = auxCodes:gsub(' ', ',')
    elseif #fullAuxCodes >= 1 then
        local parts_comment = {}
        local i = 1
        while i <= #fullAuxCodes do
            local group = (fullAuxCodes[i] or "") .. (fullAuxCodes[i + 1] or "")
            table.insert(parts_comment, group)
            i = i + 2
        end
        comment = table.concat(parts_comment, "/")
    end

    cache_put(env, "comment_cache", "comment_cache_queue", "comment_cache_head",
        COMMENT_CACHE_LIMIT, word, comment or false)
    return comment
end

-- 辅助函数：按触发键分割后的片段，依次匹配候选词中的每个字
local function match_by_parts(charCount, parts, fullAuxCodes)
    for i, part in ipairs(parts) do
        if i > charCount then break end   -- 忽略超出字数的片段
        local base = (i - 1) * 2
        local slot1 = fullAuxCodes[base + 1]
        local slot2 = fullAuxCodes[base + 2]
        if not slot1 and not slot2 then return false end
        if #part == 1 then
            local found = (slot1 and slot1:find(part, 1, true)) or (slot2 and slot2:find(part, 1, true))
            if not found then return false end
        else
            local firstChar = part:sub(1,1)
            local secondChar = part:sub(2,2)
            if not (slot1 and slot1:find(firstChar, 1, true)) then return false end
            if not (slot2 and slot2:find(secondChar, 1, true)) then return false end
        end
    end
    return true
end

function AuxFilter.match(fullAux, auxStr)
    if #fullAux == 0 then return false end
    local maxSlot = #fullAux
    local charCount = math.ceil(maxSlot / 2)
    local first, second = auxStr:sub(1, 1), auxStr:sub(2, 2)
    for c = 0, charCount - 1 do
        local base = c * 2
        local slot1 = fullAux[base + 1]
        local slot2 = fullAux[base + 2]
        local firstKeyMatched = slot1 and slot1:find(first) ~= nil
        if #auxStr == 1 then
            if firstKeyMatched then return true end
        else
            local secondKeyMatched = slot2 and slot2:find(second) ~= nil
            if firstKeyMatched and secondKeyMatched then return true end
        end
    end
    return false
end

function AuxFilter.matchSecondOnly(fullAux, auxStr)
    if #fullAux == 0 or #auxStr ~= 1 then return false end
    local maxSlot = #fullAux
    local charCount = math.ceil(maxSlot / 2)
    for c = 0, charCount - 1 do
        local base = c * 2
        local slot1 = fullAux[base + 1]
        local slot2 = fullAux[base + 2]
        local firstKeyMatched = slot1 and slot1:find(auxStr) ~= nil
        local secondKeyMatched = slot2 and slot2:find(auxStr) ~= nil
        if (not firstKeyMatched) and secondKeyMatched then return true end
    end
    return false
end

-- 单码只扫描一次；任意字的首码匹配优先于所有次码匹配。
local function match_single_rank(fullAux, key)
    local second_matched = false
    for base = 1, #fullAux, 2 do
        local first, second = fullAux[base], fullAux[base + 1]
        if first and first:find(key) then return 1 end
        if second and second:find(key) then second_matched = true end
    end
    return second_matched and 2 or 0
end

function AuxFilter.func(input, env)
    local context = env.engine.context
    local inputCode = context.input
    local char_priority = context:get_option('char_priority') or false
    local has_trigger = inputCode:find(env.trigger_key, 1, true) ~= nil

    -- 主输入无需注释时，连辅助码解析和排序数组也不创建。
    if not has_trigger and env.show_aux_notice ~= "always" then
        for cand in input:iter() do yield(cand) end
        return
    end

    local trigger_pattern = env.trigger_key_string
    local localSplit = inputCode:match(trigger_pattern .. "([^,]+)")
    local auxStr = nil
    local parts = {}
    local is_split = false

    -- 解析辅助码：检查是否包含触发键来决定是否为分割模式
    if localSplit then
        if localSplit:find(env.trigger_key, 1, true) then
            is_split = true
            for part in localSplit:gmatch("[^" .. env.trigger_key .. "]+") do
                part = part:sub(1, 2)
                if part ~= "" then
                    table.insert(parts, part)
                end
            end
        else
            auxStr = localSplit:sub(1, 2)
        end
    end

    local phrase_candidates = {}
    local first_char_candidates = {}
    local second_char_candidates = {}
    local other_candidates = {}
    local sentence_candidates = {}
    local processed_count = 0
    local needs_match = (is_split and #parts > 0) or
        (not is_split and auxStr ~= nil and #auxStr > 0)
    local show_notice = env.show_aux_notice ~= "none"
    local single_key = auxStr and #auxStr == 1

    for cand in input:iter() do
        if has_trigger and processed_count >= MAX_PROCESSED_AFTER_TRIGGER then
            break
        end

        local candType = cand.type
        local word = cand.text
        local char_count = utf8.len(word) or #word
        local is_phrase = char_count > 1
        local is_single_char = not is_phrase and candType ~= 'sentence' and candType ~= 'model'

        if env.phrase_only and has_trigger and is_single_char then
            -- 词语模式：辅助码触发后，单字候选完全跳过辅助码计算与输出，提升性能
        else
            processed_count = processed_count + 1
            local fullAuxCodes
            if needs_match and candType ~= 'sentence' and candType ~= 'model' then
                fullAuxCodes = AuxFilter.fullAux(env, word)
            end

            -- 添加辅助码注释（按词缓存，避免重复拼接）
            if show_notice then
                local codeComment = env.comment_cache[word]
                if codeComment == nil then
                    local auxCodes = AuxFilter.get_aux_code(env, word)
                    if not auxCodes or #auxCodes == 0 then
                        fullAuxCodes = fullAuxCodes or AuxFilter.fullAux(env, word)
                    end
                    codeComment = AuxFilter.get_comment(env, word, auxCodes, fullAuxCodes)
                end
                if codeComment then
                    if cand:get_dynamic_type() == "Shadow" then
                        local shadowText = cand.text
                        local shadowComment = cand.comment
                        local originalCand = cand:get_genuine()
                        cand = ShadowCandidate(originalCand, originalCand.type, shadowText,
                            originalCand.comment .. shadowComment .. '(' .. codeComment .. ')')
                    elseif env.show_aux_notice == "trigger" then
                        if has_trigger then
                            cand.comment = cand.comment .. '(' .. codeComment .. ')'
                        end
                    else
                        cand.comment = cand.comment .. '(' .. codeComment .. ')'
                    end
                end
            end

            -- 筛选逻辑
            if candType == 'sentence' or candType == 'model' then
                table.insert(sentence_candidates, cand)
            else
                if is_split then
                    -- 分割模式：所有指定字位置必须匹配
                    if #parts == 0 then
                        yield(cand)   -- 无有效辅助码，直接输出
                    else
                        local matched = match_by_parts(char_count, parts, fullAuxCodes)
                        if matched then
                            if is_phrase then
                                table.insert(phrase_candidates, cand)
                            else
                                table.insert(first_char_candidates, cand)
                            end
                        else
                            table.insert(other_candidates, cand)
                        end
                    end
                else
                    -- 传统模式
                    if not auxStr or #auxStr == 0 then
                        yield(cand)
                    elseif fullAuxCodes then
                        local rank
                        if single_key then
                            rank = match_single_rank(fullAuxCodes, auxStr)
                        else
                            rank = AuxFilter.match(fullAuxCodes, auxStr) and 1 or 0
                        end
                        if rank == 1 then
                            if is_phrase then
                                table.insert(phrase_candidates, cand)
                            else
                                table.insert(first_char_candidates, cand)
                            end
                        elseif rank == 2 then
                            if is_phrase then
                                table.insert(phrase_candidates, cand)
                            else
                                table.insert(second_char_candidates, cand)
                            end
                        else
                            table.insert(other_candidates, cand)
                        end
                    else
                        table.insert(other_candidates, cand)
                    end
                end
            end
        end
    end

    -- 按模式输出
    if is_split then
        if char_priority then
            for _, cand in ipairs(first_char_candidates) do yield(cand) end
            for _, cand in ipairs(phrase_candidates) do yield(cand) end
        else
            for _, cand in ipairs(phrase_candidates) do yield(cand) end
            for _, cand in ipairs(first_char_candidates) do yield(cand) end
        end
        for _, cand in ipairs(other_candidates) do yield(cand) end
        for _, cand in ipairs(sentence_candidates) do yield(cand) end
    else
        if char_priority then
            for _, cand in ipairs(first_char_candidates) do yield(cand) end
            for _, cand in ipairs(second_char_candidates) do yield(cand) end
            for _, cand in ipairs(phrase_candidates) do yield(cand) end
        else
            for _, cand in ipairs(phrase_candidates) do yield(cand) end
            for _, cand in ipairs(first_char_candidates) do yield(cand) end
            for _, cand in ipairs(second_char_candidates) do yield(cand) end
        end
        for _, cand in ipairs(other_candidates) do yield(cand) end
        for _, cand in ipairs(sentence_candidates) do yield(cand) end
    end
end

function AuxFilter.fini(env)
    if env.notifier then
        env.notifier:disconnect()
        env.notifier = nil
    end
    env.aux_db = nil
    env.memory_aux_code = nil
    for _, name in ipairs({"aux_code_cache", "aux_slot_cache", "full_aux_cache", "comment_cache"}) do
        env[name] = nil
        env[name .. "_queue"] = nil
        env[name .. "_head"] = nil
    end
end

return AuxFilter

-- Local Variables:
-- lua-indent-level: 4
-- End:
