

local M = {}

-- 主处理函数
function M.func(input, env)
    for cand in input:iter() do
        -- 直接获取拆分注释
        -- {"type", "text", "comment", "quality", "start", "_end", "preedit"}
        if cand.type ~= "" then
            cand.comment = cand.type .. "|" .. cand.quality
        end
        yield(cand)
    end
end

return { func = M.func }