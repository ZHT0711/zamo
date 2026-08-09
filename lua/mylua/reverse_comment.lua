-- 作者: XiHanQWQ（超级大🐑）
-- https://github.com/XiHanQWQ
-- commit_reverse_comment.lua
-- 功能：使用配置的按键上屏当前选中候选词的注释（仅在segment:has_tag("wanxiang_reverse")也就是部件笔画反查时触发）

local function init(env)
    -- 从配置获取触发按键，默认为Tab
    local config = env.engine.schema.config
    env.commit_comment_key = config:get_string("key_binder/commit_comment_key") or "Tab"
    
    -- 初始化状态
    env.last_commit_comment = ""
end

local function fini(env)
    -- 清理工作
end

local function processor(key_event, env)
    local context = env.engine.context
    
    -- 检查是否按下配置的按键
    if key_event:repr() ~= env.commit_comment_key then
        return 2
    end
    
    -- 检查是否有候选菜单
    if not context:has_menu() then
        return 2
    end
    
    -- 获取当前选中的segment并检查是否有wanxiang_reverse标签
    local composition = context.composition
    if not composition then
        return 2
    end
    
    local segment = composition:back()
    if not segment or not segment:has_tag("wanxiang_reverse") then
        return 2
    end
    
    -- 获取当前选中的候选词
    local selected_candidate = context:get_selected_candidate()
    if not selected_candidate then
        return 2
    end
    
    -- 获取候选词的注释
    local genuine_cand = selected_candidate:get_genuine()
    local comment = genuine_cand.comment   -- 获取当前候选字的注释
    
    if not comment or comment == "" then
        return 2
    end
    -- 获取候选字的文本内容（字头）
    local candidate_text = selected_candidate.text
    -- 移除注释中的括号
    comment = comment:gsub("〔", ""):gsub("〕", "")
    -- 构建新的上屏内容：字头 + 注释
    local final_comment = candidate_text .. "・" .. comment
    -- 上屏注释内容
    env.engine:commit_text(final_comment)
    context:clear()
    
    -- 记录最后一次提交的注释
    env.last_commit_comment = final_comment
    
    return 1
end

return { init = init, fini = fini, func = processor }