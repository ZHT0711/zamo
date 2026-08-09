local Module = {}

---A more robust io.open
---@param rel_path string a relative path
function Module.open_rime_file(rel_path, pathsep)
    -- Case 1: user dir
    local path = rime_api.get_user_data_dir() .. pathsep .. rel_path
    local file, err = io.open(path)
    if file then
        return file
    else
        log.error('加载失败：' .. path .. ',错误原因: ' .. err)
    end
    
    -- Case 2: shared dir
    if pathsep == '\\' then
        return nil
    end
    local prefixes = {
        '/usr/local/share/rime-data/',
        '/usr/share/rime-data/'
    }
    for _, prefix in pairs(prefixes) do
        path = prefix .. rel_path
        file, err = io.open(path)
        if file then
            return file
        else
            log.error('加载失败：' .. path .. ',错误原因: ' .. err)
        end
    end
    return nil
end

---Load cuoyin.pro.dict.yaml bundled with the standard Moran distribution.
---@return table<integer,table<string>>
function Module.load_cuoyin()
    if Module.corrections_cache then
        return Module.corrections_cache
    end
    local auto_delimiter = " "
    local pathsep = (package.config or '/'):sub(1, 1)
    local file = Module.open_rime_file('dicts' .. pathsep .. 'cuoyin.pro.dict.yaml', pathsep)
    if not file then
        log.error('无法打开cuoyin.pro.dict.yaml')
        return nil
    end
    local corrections_cache = {}
    for line in file:lines() do
        if not line:match("^#") then
            local text, code, weight, comment = line:match("^(.-)\t(.-)\t(.-)\t(.-)$")
            if text and code then
                text = text:match("^%s*(.-)%s*$")
                code = code:match("^%s*(.-)%s*$")
                comment = comment and comment:match("^%s*(.-)%s*$") or ""
                comment = comment:gsub("%s+", auto_delimiter)
                code = code:gsub("%s+", auto_delimiter)
                corrections_cache[code] = { text = text, comment = comment }
            end
        end
    end
    file:close()
    Module.corrections_cache = corrections_cache
    return Module.corrections_cache
end

---判断是否在命令模式
---@param context Context | nil
---@return boolean
function Module.is_function_mode_active(context)
    if not context or not context.composition or context.composition:empty() then
        return false
    end

    local seg = context.composition:back()
    if not seg then return false end

    return seg:has_tag("number")
        or seg:has_tag("unicode")
        or seg:has_tag("calculator")
        or seg:has_tag("shijian")
        or seg:has_tag("Ndate")
        or seg:has_tag("kagiroi")
        or seg:has_tag("mixed_V")
end

function Module.segment_is_reverse_lookup(seg)
    if seg:has_tag("kagiroi") then
        return true
    end

    -- 所有反查都不過濾：
    for tag, _ in pairs(seg.tags) do
        if tag:match("^reverse_") then
            return true
        end
    end
    return false
end

function Module.is_reverse_lookup(env)
    local seg = env.engine.context.composition:back()
    if not seg then
        return false
    end
    return Module.segment_is_reverse_lookup(seg)
end

function Module.Thunk(functor)
    local result = nil
    return function()
        if result == nil then
            result = functor()
        end
        return result
    end
end

return Module