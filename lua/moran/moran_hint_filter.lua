-- Moran Translator (for Express Editor)
-- Copyright (c) 2023-2026 ksqsf
--
-- Ver: 0.4.1 (增加 tips 简码提示)
-- 2026-10-17: tips 内容检查改为 5 秒节流，保留热更新和强制重载。
--
-- This file is part of Project Moran
-- Licensed under GPLv3
--
-- 0.4.1: 增加 tips_user.txt 简码提示功能（基于 v0.2.1 解析逻辑）
-- 0.4.0: 適配多字詞重排。
-- 0.3.0: 增加 quick_code_hint_indicator 選項
-- 0.2.0: 若開啓 inject_fixed_words ，則提示長詞
-- 0.1.0: 合併原 moran_aux_hint 和 moran_quick_code_hint
--
local moran = require("moran")
local Module = {}

-- Tips reverse cache (text -> array of codes)
local tips_reverse_cache = {}
local tips_reverse_loaded = false
local tips_file_content
local tips_last_check
local TIPS_CHECK_INTERVAL = 5

-- Build reverse mapping from tips_user.txt (format: prefix：text<TAB>code)
function Module.build_tips_reverse_cache(force_reload)
    local now = os.time()
    -- 热更新最多延迟 5 秒；时钟回拨和强制加载均立即检查。
    if tips_reverse_loaded and not force_reload and tips_last_check
        and now >= tips_last_check and now - tips_last_check < TIPS_CHECK_INTERVAL then
        return
    end
    tips_last_check = now

    local tips_user_path = rime_api.get_user_data_dir() .. "/lua/data/tips_user.txt"
    local file = io.open(tips_user_path, "rb")
    local content = false
    if file then
        content = file:read("*a") or false
        file:close()
    end
    -- 比较完整内容，同长度编辑也能生效；未改变时保留已解析的表。
    if tips_reverse_loaded and not force_reload and content == tips_file_content then
        return
    end

    local reverse_cache = {}
    for line in (content or ""):gmatch("[^\r\n]+") do
        -- Parse: "类型：文本\t编码"
        local value, key = line:match("([^\t]+)\t([^\t]+)")
        if key and value then
            -- Extract text after "：" or ":" (trim whitespace)
            local text = value:match("：%s*(.-)%s*$") or value:match(":%s*(.-)%s*$")
            if text and #text > 0 and #key > 0 then
                if not reverse_cache[text] then
                    reverse_cache[text] = {}
                end
                table.insert(reverse_cache[text], key)
            end
        end
    end
    
    tips_reverse_cache = reverse_cache
    tips_file_content = content
    tips_reverse_loaded = true
end

function Module.init(env)
    env.enable_aux_hint = env.engine.schema.config:get_bool("moran/enable_aux_hint")
    if env.enable_aux_hint then
        env.aux_table = moran.load_zrmdb()
        if not env.aux_table then
            env.enable_aux_hint = false
        end
    else
        env.aux_table = nil
    end

    env.is_auxfilter = env.name_space == "auxfilter"
    env.enable_quick_code_hint = env.engine.schema.config:get_bool("moran/enable_quick_code_hint")
    if env.enable_quick_code_hint and not env.is_auxfilter then
        local dict = env.engine.schema.config:get_string("fixed/dictionary")
        env.quick_code_hint_reverse = ReverseLookup(dict)
        env.quick_code_hint_skip_chars = env.engine.schema.config:get_bool("moran/quick_code_hint_skip_chars") or false
    else
        env.quick_code_hint_reverse = nil
    end
    env.quick_code_hint_indicator = env.engine.schema.config:get_string("moran/quick_code_hint_indicator")
    if env.quick_code_hint_indicator == nil then
        env.quick_code_hint_indicator = env.engine.schema.config:get_string("moran/quick_code_indicator") or ""
    end

    env.inject_fixed_words = env.engine.schema.config:get_bool("moran/inject_fixed_words") or false

    -- Tips 简码提示
    env.enable_tips_code_hint = env.engine.schema.config:get_bool("moran/enable_tips_code_hint")
    if env.enable_tips_code_hint == nil then
        env.enable_tips_code_hint = true
    end
    if env.enable_tips_code_hint then
        Module.build_tips_reverse_cache(false)
    end
end

function Module.fini(env)
    env.enable_aux_hint = false
    env.aux_table = nil
    env.enable_quick_code_hint = nil
    env.quick_code_hint_reverse = nil
    env.enable_tips_code_hint = nil
    tips_reverse_cache = {}
    tips_reverse_loaded = false
    tips_file_content = nil
    tips_last_check = nil
    collectgarbage()
end

-- Get tips code (returns first code from array)
function Module.get_tips_code(env, gcand)
    if not env.enable_tips_code_hint then return nil end
    local codes = tips_reverse_cache[gcand.text]
    if codes and #codes > 0 then
        return codes[1]
    end
    return nil
end

function Module.get_auxcode_hint(env, cand, gcand)
    if not env.enable_aux_hint or not env.aux_table then
        return nil
    end
    local text = gcand.text
    local len = utf8.len(text)
    if len == 1 then
        local cp = utf8.codepoint(text)
        local codes = env.aux_table[cp]
        if not codes then
            return nil
        end
        return codes:sub(2)
    elseif len ~= 1 and env.is_auxfilter and (gcand.type == "phrase" or gcand.type == "user_phrase") then
        local result = ""
        for i, cp in moran.codepoints(gcand.text) do
            local cpaux = env.aux_table[cp]
            if cpaux and #cpaux > 0 then
                cpaux = cpaux:match("^[a-z]+")
                if result == "" then
                    result = cpaux
                else
                    result = result .. ' ' .. cpaux
                end
            else
                return nil
            end
        end
        if #result == 0 then
            return nil
        end
        return result
    else
        return nil
    end
end

function Module.get_quickcode_hint(env, cand, gcand)
    if not env.enable_quick_code_hint or not env.quick_code_hint_reverse then
        return nil
    end
    local text = gcand.text
    local len = utf8.len(text)
    if len == 1 and env.quick_code_hint_skip_chars then
        return nil
    end
    local all_codes = env.quick_code_hint_reverse:lookup(text)
    if not all_codes then
        return nil
    end
    
    local in_use = false
    local current_input = cand.preedit:gsub("%s", "") or ""
    local current_len = #current_input
    local shortest_code = nil
    local shortest_length = 99
    
    for code in all_codes:gmatch("%S+") do
        if #code < 4 or (env.inject_fixed_words and len >= 3) then
            if code == current_input then
                in_use = true
            elseif #code < current_len then
                if #code < shortest_length then
                    shortest_length = #code
                    shortest_code = code
                end
            end
        end
    end
    
    if shortest_code then
        return shortest_code
    end
    return nil
end

function Module.func(translation, env)
    if not env.enable_aux_hint and not env.enable_quick_code_hint and not env.enable_tips_code_hint then
        for cand in translation:iter() do
            yield(cand)
        end
        return
    end

    -- 按间隔检查 tips 文件是否更新
    if env.enable_tips_code_hint then
        Module.build_tips_reverse_cache(false)
    end

    local major_sep = "¦"
    local minor_sep = env.quick_code_hint_indicator
    if #minor_sep == 0 then
        minor_sep = major_sep
    end
    for cand in translation:iter() do
        if cand.type == "punct" then
            yield(cand)
            goto continue
        end
        local gcand = cand:get_genuine()
        local auxhint = Module.get_auxcode_hint(env, cand, gcand)
        local qchint = Module.get_quickcode_hint(env, cand, gcand)
        local tips_code = Module.get_tips_code(env, gcand)

        -- 若 tips 与词简码相同则不重复显示
        if tips_code and qchint and tips_code == qchint then
            tips_code = nil
        end

        -- 根据原有逻辑组合提示，并加入 tips
        if auxhint and qchint then
            local hint = auxhint .. minor_sep .. qchint
            if tips_code then
                hint = hint .. minor_sep .. tips_code
            end
            if #gcand.comment == 0 or gcand.comment == env.quick_code_hint_indicator then
                gcand.comment = hint
            else
                gcand.comment = gcand.comment .. major_sep .. hint
            end
        elseif auxhint then
            local hint = auxhint
            if tips_code then
                hint = hint .. minor_sep .. tips_code
            end
            if not env.is_auxfilter and #gcand.comment == 0 then
                gcand.comment = hint
            elseif not env.is_auxfilter and (gcand.comment == env.quick_code_hint_indicator) then
                gcand.comment = hint .. gcand.comment
            else
                gcand.comment = gcand.comment .. major_sep .. hint
            end
        elseif qchint then
            -- 原有 qchint 逻辑：注意 indicator 添加方式
            local hint = qchint
            if tips_code then
                hint = hint .. minor_sep .. tips_code
            end
            if #gcand.comment == 0 then
                gcand.comment = gcand.comment .. env.quick_code_hint_indicator .. hint
            elseif gcand.comment == env.quick_code_hint_indicator then
                gcand.comment = gcand.comment .. hint
            else
                gcand.comment = gcand.comment .. env.quick_code_hint_indicator .. hint
            end
        elseif tips_code then
            -- 仅 tips 单独出现时，用括号包裹以与简码区分
            if #gcand.comment == 0 then
                gcand.comment = "‹" .. tips_code .. "›"
            else
                gcand.comment = gcand.comment .. major_sep .. "‹" .. tips_code .. "›"
            end
        end
        yield(cand)
        ::continue::
    end
end

return Module

-- Local Variables:
-- lua-indent-level: 4
-- End:
