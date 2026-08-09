-- author: amzxyz  https://github.com/amzxyz/rime_wanxiang
-- 英文自造词模块单独提取
-- 配置说明
-- 需要放在uniquifier前面
-- engine/segmentors/@before 1:lua_translator@*add_word

local M = {}

local function is_ascii_word(text)
    if not text or text == "" then
        return false
    end
    local has_alpha = false
    for i = 1, #text do
        local b = text:byte(i)
        if b > 127 then
            return false
        end
        if (b >= 65 and b <= 90) or (b >= 97 and b <= 122) then
            has_alpha = true
        end
    end
    return has_alpha
end

function M.init(env)
    -- 初始化造词功能
    env.en_memory = Memory(env.engine, env.engine.schema, "wanxiang_english")
    
    local config = env.engine.schema.config
    env.enable_english_phrase = true
    env.trigger_symbol = "/"  -- 触发符号
    env.min_word_length = 2    -- 最小单词长度
    env.max_word_length = 20   -- 最大单词长度
    env.filter_other_candidates = true
    
    -- 连接提交事件用于造词
    local ctx = env.engine.context
    if env.en_memory then
        env._commit_conn = ctx.commit_notifier:connect(function(c)
            M.commit_handler(c, env)
        end)
    end
end

function M.fini(env)
    if env._commit_conn then
        env._commit_conn:disconnect()
        env._commit_conn = nil
    end
    if env.en_memory then
        env.en_memory:disconnect()
        env.en_memory = nil
    end
end

-- 造词处理器
function M.commit_handler(ctx, env)
    if not env.enable_english_phrase or not env.en_memory then
        return
    end
    
    if not ctx then
        return
    end
    
    local commit_text = ctx:get_commit_text() or ""
    local raw_input = ctx.input or ""
    local symbol = env.trigger_symbol
    
    -- 检查长度限制
    if #commit_text < env.min_word_length or #commit_text > env.max_word_length then
        return
    end
    
    -- 检查触发条件：输入以触发符号结尾
    if raw_input ~= "" and raw_input:sub(-#symbol) == symbol and is_ascii_word(commit_text) then
        -- 清理编码
        local code_body = raw_input:gsub(symbol .. "+$", "")  -- 去掉连续的触发符号
        code_body = code_body:gsub("%s+$", "")               -- 去掉尾部空白
        
        if code_body ~= "" then
            code_body = code_body:lower()   -- 将编码改成小写
            local entry = DictEntry()
            entry.text = commit_text
            entry.weight = 1
            entry.custom_code = code_body .. " "
            
            env.en_memory:update_userdict(entry, 1, "")
        end
    end
end

-- 快速判断候选类型
local function fast_type(c)
    local t = c.type
    if t then return t end
    local g = c.get_genuine and c:get_genuine() or nil
    return (g and g.type) or ""
end

-- 过滤器主函数
function M.func(input, env)
    if not env.enable_english_phrase then
        for cand in input:iter() do
            yield(cand)
        end
        return
    end
    
    local ctx = env.engine and env.engine.context
    if not ctx then
        for cand in input:iter() do
            yield(cand)
        end
        return
    end
    
    local code = ctx.input or ""
    local symbol = env.trigger_symbol
    local symbol_len = #symbol
    local comp = ctx.composition
    local force_english_text = nil
    
    -- 检测末尾单符号触发（强制上屏功能）
    if code:find(symbol, 1, true) then
        local last_seg = comp and comp:back()
        if last_seg then
            local segm = comp and comp:toSegmentation()
            local confirmed = 0
            if segm and segm.get_confirmed_position then 
                confirmed = segm:get_confirmed_position() or 0 
            end
            
            local fully_consumed = (last_seg.start == confirmed) and (last_seg._end == #code)
            
            if fully_consumed then
                local last_text = string.sub(code, last_seg.start + 1, last_seg._end)
                local len = #last_text
                
                -- 检测末尾是否为一个符号
                if len >= symbol_len then
                    local last_symbol = string.sub(last_text, len - symbol_len + 1, len)
                    
                    if last_symbol == symbol then
                        -- 去掉末尾符号
                        local base = string.sub(last_text, 1, len - symbol_len)
                        
                        if base and #base > 0 then
                            local ascii_only = true
                            for i = 1, #base do
                                local b = string.byte(base, i)
                                if b > 127 then
                                    ascii_only = false
                                    break
                                end
                            end
                            
                            if ascii_only then
                                force_english_text = base
                            end
                        end
                    end
                end
            end
        end
    end
    
    -- 如果有强制英文文本
    if force_english_text then
        local start_pos = 0
        local end_pos = #code
        
        local last_seg = comp and comp:back()
        if last_seg then
            start_pos = last_seg.start
            end_pos = last_seg._end
        end
        
        -- 生成英文候选（强制上屏候选）
        local eng_candidate = Candidate(
            "Engword",
            start_pos,
            end_pos,
            force_english_text,
            "「加词」"
        )
        yield(eng_candidate)
        
        -- 如果需要过滤其他候选
        if env.filter_other_candidates then
            for cand in input:iter() do
                if fast_type(cand) ~= "sentence" then
                    yield(cand)
                end
            end
            return
        end
    end
    
    -- 正常输出所有候选
    for cand in input:iter() do
        yield(cand)
    end
end

return M