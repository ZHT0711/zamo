-- paired_punct.lua
-- 作者: kuroame
-- 许可证: MIT
-- 功能: 雙符成形 - 自动配对输出标点符号（如括号、引号等）

-- 配置說明
-- 在你的schema文件裏引入這個segmentor，需要放在abc_segmentor的前面
-- 例如
-- segmentors:
--   - ascii_segmentor
--   - matcher
--   - lua_segmentor@*paired_punct
--   - abc_segmentor
--   ...
--
-- 同時定義如下配置
-- paired_punct:
--   pattern: '^([aswdfg])/'
--   defer:
--     - "，"
--     - "、"
--   dict:
--     a: ['《','》']
--     w: ['（','）']
--     s: ['「','」']
--     d: ['『','』']
--     f: ['"','"']
--     g: ['','']
-- pattern 是一個觸發雙符的正則表達式，用來匹配用戶輸入
-- 其中的捕獲組, 用於捕獲查詢 dict 時的 key
-- dict 是符號的詞典，符號從左到右定義
-- 例如上面 a/danshi 可能會打出 《但是》
-- defer 是一個列表，定義了什麼上屏內容會導致延遲輸出右符號
-- 例如 a/danshi, ->  《但是，
-- 繼續輸入，yexu ->  也許》

local tag_prefix = "paired_punct_"  -- 用于标记段的前缀

-- 从segment的tags中提取key字符
local function get_key_char(segment)
    for tag in pairs(segment.tags) do
        if tag:sub(1, #tag_prefix) == tag_prefix then
            return tag:sub(#tag_prefix + 1)  -- 返回tag中除了前缀的部分
        end
    end
    return nil
end

-- 在segmentation中查找带有双符标记的segment
local function get_pp_seg(segmentation)
    for i = 0, segmentation.size - 1 do
        local seg = segmentation:get_at(i)
        if seg and get_key_char(seg) ~= nil then
            return seg  -- 找到并返回第一个匹配的segment
        end
    end
    return nil
end

-- 检查文本是否以defer列表中的字符结尾
local function end_with_defer(text, env)
    if not env.defer then
        return false
    end
    for i = 0, env.defer.size do
        local item_value = env.defer:get_value_at(i)
        if item_value then
            local item_str = item_value:get_string()
            if item_str and text == item_str then
                return true  -- 文本匹配defer列表中的某个字符
            end
        end
    end
    return false
end

-- 当上下文更新或选择候选词时调用的函数
local function on_update_or_select(env)
    return function(ctx)
        -- 如果找到本 segmentor 添加的 segment, 繼續處理
        local segmentation = ctx.composition:toSegmentation()
        local pp_seg = get_pp_seg(segmentation)
        if pp_seg then
            -- 根據 tag 信息查找標點符號對，並給 pp_seg 一個翻譯
            local key_char = get_key_char(pp_seg)
            log.info("paired_punct: translating key: " .. key_char)
            local punct_pair = env.pp_map:get(key_char)
            if not punct_pair or punct_pair:get_list().size < 2 then
                return  -- 如果没有找到对应的标点对，直接返回
            end
            local opening_punct = punct_pair:get_list():get_at(0):get_value():get_string()  -- 获取开符号
            env.closing_punct = punct_pair:get_list():get_at(1):get_value():get_string()   -- 获取闭符号并保存到env
            local translation = env.echo_translator:query(opening_punct, pp_seg)
            if translation then
                local menu = Menu()
                menu:add_translation(translation)
                pp_seg.menu = menu
                pp_seg.menu:prepare(1)
                local cand = menu:get_candidate_at(0)
                if cand then
		    cand.preedit = cand.text  -- 设置候选词的preedit为文本本身
		end
            end
            if segmentation:get_confirmed_position() >= pp_seg.start then
                pp_seg.status = "kConfirmed" -- 自动确认该segment
            end
            ctx.composition:back().prompt = env.closing_punct  -- 在composition末尾显示闭符号提示
        elseif ctx.composition:back() and env.closing_punct and env.waiting_end then
            ctx.composition:back().prompt = env.closing_punct  -- 如果有等待的闭符号，显示提示
        end
    end
end

-- 当提交文本时调用的函数
local function on_commit(env)
    return function(ctx)
	if env.closing_punct then
	    local back = ctx.composition:back()
	    if back then
		local candidate = back:get_selected_candidate()
		if candidate and end_with_defer(candidate.text, env) then
                    env.waiting_end = true  -- 如果以defer字符结尾，设置等待标志
		    return
		end
	    end
	    local segmentation = ctx.composition:toSegmentation()
	    local pp_seg = get_pp_seg(segmentation)
            if pp_seg or env.waiting_end then
                env.engine:commit_text(env.closing_punct)  -- 提交闭符号
            end
	    env.closing_punct = nil  -- 重置闭符号
	    env.waiting_end = false  -- 重置等待标志
	end
    end
end

-- segmentor模块定义
local segmentor = {}

-- 初始化函数
function segmentor.init(env)
    env.pp_pattern = env.engine.schema.config:get_string("paired_punct/pattern")  -- 获取匹配模式
    env.pp_map = env.engine.schema.config:get_map("paired_punct/dict")            -- 获取符号字典
    env.defer = env.engine.schema.config:get_list("paired_punct/defer")           -- 获取延迟列表
    env.echo_translator = Component.Translator(env.engine, "", "echo_translator") -- 创建回显翻译器
    env.closing_punct = nil                                                       -- 初始化闭符号
    env.waiting_end = false                                                       -- 初始化等待标志
    env.update_notifier = env.engine.context.update_notifier:connect(on_update_or_select(env))  -- 连接更新通知器
    env.select_notifier = env.engine.context.select_notifier:connect(on_update_or_select(env))  -- 连接选择通知器
    env.commit_notifier = env.engine.context.commit_notifier:connect(on_commit(env))           -- 连接提交通知器
end

-- 清理函数
function segmentor.fini(env)
    env.update_notifier:disconnect()   -- 断开更新通知器
    env.select_notifier:disconnect()   -- 断开选择通知器
    env.commit_notifier:disconnect()   -- 断开提交通知器
    env.echo_translator = nil          -- 清理回显翻译器
end

-- 分段处理函数
function segmentor.func(segmentation, env)
    if segmentation:empty() then
        return true  -- 如果segmentation为空，直接返回
    end
    local input = segmentation.input:sub(segmentation:get_current_start_position() + 1)  -- 获取当前输入
    log.info("paired_punct match: ".. input)
    local match_start, match_end, key_char = string.find(input, env.pp_pattern)  -- 匹配输入模式
    if not match_start then
        return true  -- 如果没有匹配，直接返回
    end
    match_start = match_start + segmentation:get_current_start_position() - 1  -- 计算匹配起始位置
    match_end = match_end + segmentation:get_current_start_position()          -- 计算匹配结束位置
    log.info("paired_punct matched: " .. "start pos: " .. match_start .. " end pos: " .. match_end .. " key: " ..
        key_char)
    local punct_pair = env.pp_map:get(key_char)
    if not punct_pair or punct_pair:get_list().size < 2 then
	return true  -- 如果没有对应的标点对，直接返回
    end
    local seg = Segment(match_start, match_end)                              -- 创建新的segment
    seg.tags = Set({ tag_prefix .. key_char })                               -- 设置tag标记
    segmentation:add_segment(seg)                                            -- 添加segment到segmentation
    segmentation:forward()                                                   -- 向前移动segmentation
    return true
end

return segmentor  -- 返回segmentor模块