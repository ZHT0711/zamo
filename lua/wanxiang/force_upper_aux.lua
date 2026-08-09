-- lua/force_upper_aux.lua
-- @description: 自动施加辅助码。按一下：全长度N锁定当前；按两下：N-1长度回退历史。按下退格键解除锁定
-- @author: amzxyz

local ForceUpperAux = {}
local wanxiang = require("wanxiang/wanxiang")

-- 获取 UTF-8 字符
local function get_utf8_char(str, index)
    local start_byte = utf8.offset(str, index)
    if not start_byte then return nil end
    local end_byte = utf8.offset(str, index + 1)
    return string.sub(str, start_byte, (end_byte and end_byte - 1) or nil)
end

-- 获取 UTF-8 前缀
local function get_utf8_prefix(str, n)
    if not str or str == "" or n <= 0 then return "" end
    local offset = utf8.offset(str, n + 1)
    return offset and string.sub(str, 1, offset - 1) or str
end

-- 【核心替换】：直接利用底层 spans 顶点切分，抛弃属性传递与正则 (保留第一版逻辑)
local function get_script_text_parts(ctx)
    local parts = {}
    local spans = ctx.composition:spans()
    
    local count = type(spans.count) == "function" and spans:count() or spans.count
    if not spans or count == 0 then return parts end
    
    local vertices = type(spans.vertices) == "function" and spans:vertices() or spans.vertices
    if not vertices or #vertices < 2 then return parts end

    for i = 1, #vertices - 1 do
        local start_byte = vertices[i] + 1 
        local end_byte = vertices[i + 1]   
        local raw_syl = ctx.input:sub(start_byte, end_byte)
        if raw_syl and raw_syl ~= "" then
            table.insert(parts, raw_syl)
        end
    end
    return parts
end

-- 查询辅助码
local function lookup_aux_code(env, char)
    if not env.dict then return "" end 
    if env.aux_cache[char] then return env.aux_cache[char] end
    local raw_code = env.dict:lookup(char)
    if not raw_code or raw_code == "" then return "" end
    local aux_part = raw_code:match(";([^,]+)") or raw_code:match("^([^;]+)") or ""
    local final_code = aux_part:gsub("[^a-zA-Z]", ""):sub(1, 2):upper()
    env.aux_cache[char] = final_code
    return final_code
end

-- 初始化
function ForceUpperAux.init(env)
    local config = env.engine.schema.config
    env.trigger_key = config:get_string("force_upper_aux/hotkey") or "Tab"
    env.aux_cache = {}
    
    local dict_name = config:get_string("translator/dictionary") or "wanxiang_pro"
    env.dict = ReverseLookup(dict_name)
    
    env.history_first = {}   
    env.press_count = 0      
    env.is_cycling = false   
    env.snapshot_parts = nil 
    env.snapshot_current_full = ""
    env.original_input = ""
    
    env.on_update = function(ctx)
        local raw_in = ctx.input or ""
        if raw_in == "" or not raw_in:match("^[a-zA-Z0-9]") then
            return
        end

        local is_special_mode = wanxiang.s2t_conversion and wanxiang.s2t_conversion(ctx)
        if env.is_cycling or wanxiang.is_function_mode_active(ctx) or is_special_mode then 
            return 
        end
        
        if not ctx:is_composing() then
            env.history_first = {}
            env.press_count = 0
            env.is_cycling = false
            return
        end
        
        local parts = get_script_text_parts(ctx)
        local parts_count = #parts
        if parts_count == 0 then return end
        
        local comp = ctx.composition
        if not comp:empty() then
            local segment = comp:back()
            local cand = segment:get_candidate_at(0)
            if cand and cand.text then
                env.history_first[parts_count] = get_utf8_prefix(cand.text, parts_count)
            end
        end
    end
    env.update_conn = env.engine.context.update_notifier:connect(env.on_update)
end

function ForceUpperAux.fini(env)
    if env.update_conn then 
        env.update_conn:disconnect()
        env.update_conn = nil
    end
    env.dict = nil
    env.aux_cache = nil
    env.history_first = nil
    env.snapshot_parts = nil
end

-- 核心逻辑
function ForceUpperAux.func(key_event, env)
    if key_event:release() then return 2 end
    local ctx = env.engine.context
    local raw_in = ctx.input or ""
    if raw_in == "" or not raw_in:match("^[a-zA-Z0-9]") then
        return 2
    end
    
    local is_special_mode = wanxiang.s2t_conversion and wanxiang.s2t_conversion(ctx)
    if wanxiang.is_function_mode_active(ctx) or is_special_mode then 
        return 2 
    end

    local current_key = key_event:repr()
    
    if current_key == env.trigger_key then
        if not ctx:is_composing() then return 2 end
        
        if env.press_count == 0 then
            env.original_input = ctx.input
            env.snapshot_parts = get_script_text_parts(ctx)
            local comp = ctx.composition
            if not comp:empty() then
                local cand = comp:back():get_candidate_at(0)
                if cand then
                    env.snapshot_current_full = get_utf8_prefix(cand.text, #env.snapshot_parts)
                end
            end
        end
        
        local parts = env.snapshot_parts
        if not parts or #parts == 0 then
            return 2 
        end
        
        env.press_count = env.press_count + 1
        env.is_cycling = true 
        
        local parts_count = #parts
        local candidate_text = ""
        local apply_until = 0
        
        if env.press_count % 2 == 1 then
            candidate_text = env.snapshot_current_full
            apply_until = parts_count 
        else
            apply_until = parts_count - 1
            if apply_until > 0 then
                candidate_text = env.history_first[apply_until] or get_utf8_prefix(env.snapshot_current_full, apply_until)
            else
                if env.original_input and env.original_input ~= "" then
                    ctx.input = env.original_input
                end
                return 1
            end
        end
        
        local new_input_parts = {}
        local text_len = utf8.len(candidate_text) or 0
        local found_any_aux = false 
        
        for i = 1, parts_count do
            local syl = parts[i]
            if i <= apply_until and i <= text_len then
                local pinyin_offset = utf8.offset(syl, 3)
                local pinyin = pinyin_offset and string.sub(syl, 1, pinyin_offset - 1) or syl
                
                local char = get_utf8_char(candidate_text, i)
                local aux = lookup_aux_code(env, char)
                if aux and aux ~= "" then
                    new_input_parts[i] = pinyin .. aux
                    found_any_aux = true
                else
                    new_input_parts[i] = syl
                end
            else
                new_input_parts[i] = syl
            end
        end
        if not found_any_aux then
            env.press_count = 0
            env.is_cycling = false
            env.snapshot_parts = nil
            return 2
        end

        local new_input = table.concat(new_input_parts)
        
        if new_input ~= "" and new_input ~= ctx.input then
            ctx.input = new_input
        end
        
        return 1 
        
    elseif current_key == "BackSpace" and env.is_cycling then
        if env.original_input and env.original_input ~= "" then
            ctx.input = env.original_input
        end
        
        env.press_count = 0
        env.is_cycling = false
        env.snapshot_parts = nil
        env.original_input = ""
        return 1
        
    else
        env.press_count = 0
        env.is_cycling = false
        env.snapshot_parts = nil
        env.original_input = ""
        return 2 
    end
end
return ForceUpperAux