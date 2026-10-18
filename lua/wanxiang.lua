-- 兼容旧模块路径；公共工具统一维护在 lua/wanxiang/wanxiang.lua。
local core = require("wanxiang/wanxiang")
local legacy = setmetatable({ version = "v14.7.0" }, { __index = core })

-- 保留旧接口对标点的判断，避免合并公共代码时改变现有行为。
function legacy.s2t_conversion(context)
    if not context or not context.composition or context.composition:empty() then
        return false
    end
    local seg = context.composition:back()
    if not seg then return false end
    return seg:has_tag("number") or
        seg:has_tag("unicode") or
        seg:has_tag("calculator") or
        seg:has_tag("shijian") or
        seg:has_tag("Ndate") or
        seg:has_tag("wanxiang_reverse")
end

return legacy
