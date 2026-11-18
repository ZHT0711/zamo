-- Moran Translator (for Express Editor)
-- Copyright (c) 2023, 2024, 2025, 2026 ksqsf
--
-- Ver: 0.12.2
-- 2026-10-17: 將按鍵期間隨機完整 GC 改為小步回收；處理模型空候選。
--
-- This file is part of Project Moran
-- Licensed under GPLv3
--
-- 0.12.2: 增加 disable_sentence_candidates_upto 設置，用於在特定碼數
-- 前禁止整句輸出。
--
-- 0.12.1: 造詞模式阻止輸出簡碼碼表多字詞
--
-- 0.12.0: 引入惰性加載
--
-- 0.11.0: 引入 quick_code_in_sentence_making 配置項。
-- 該配置項改進了魔然最初的一項設計（造詞時禁止輸出固定選項）以維持造詞能力，
-- 但事實上配合 reorder_filter 可以取消這一限制。
-- (輔篩模式此前的 fix/use_dict 已經實現該功能。)
--
-- 0.10.1: 配合主方案變更的次要修改。
--
-- 0.10.0: 增加 inject_prioritize 支持。
--
-- 0.9.0: show_words_anyway 和 show_chars_anyway 分別更名爲
-- inject_fixed_words 和 inject_fixed_chars。爲保持兼容性，原名還可以
-- 繼續使用（優先級高於新名），但未來可能被刪除。
--
-- 0.8.1: 支持 word_filter_match_indicator。
--
-- 0.8.0: 適配 hint_filter，支持詞輔提前提示。
--
-- 0.7.2: 修正詞輔在三字詞可能不生效的問題。
--
-- 0.7.1: 修正詞輔與整句輔的一處兼容性問題，並優化了性能。
--
-- 0.7.0: 定義 show_words_anyway、show_chars_anyway 和固詞模式同時開啓
-- 時的語義。
--
-- 0.6.1, 0.6.2: show_words_anyway 在四碼時跳過二字詞。
--
-- 0.6.0: 增加 show_chars_anyway 和 show_words_anyway 設置，允許將
-- fixed 碼表的單字全碼放置在第二位，不再需要打全碼。如輸入「jwrg」就
-- 可以在第二位得到「佳」，按分號選取之。
--
-- 0.5.2: 修復與 quick_code_hint 的兼容性問題。
--
-- 0.5.1: 修復「出簡讓全」的性能問題。
--
-- 0.5.0: 修復詞庫維護問題。使用簡碼鍵入的字的字頻，不會被增加到
-- script translator 的用戶詞庫中，導致長時間使用後，生僻字的字頻反而
-- 更高，構詞和整句會被干擾。
--
-- 在方案中引用時，需增加 @with_reorder 標記，並把
-- moran_reorder_filter 添加爲第一個 filter。
--
-- 0.4.2: 修復內存泄露。
--
-- 0.4.0: 增加詞輔功能。
--
-- 0.3.2: 允許用戶自定義出簡讓全的各項設置：是否啓用、延遲幾位候選、是
-- 否顯示簡快碼提示。
--
-- 0.3.1: 允許自定義簡快碼提示符。
--
-- 0.3.0: 增加單字輸出的出簡讓全。
--
-- 0.2.0: 增加固定二字詞模式。
--
-- 0.1.0: 本翻譯器用於解決 Rime 原生的翻譯流程中，多翻譯器會互相干擾、
-- 導致造詞機能受損的問題。以「驚了」造詞爲例：用戶輸入 jym le，選擇第
-- 一個字「驚」後，再選「了」字，這時候將無法造出「驚了」這個詞。這是
-- 因爲「了」是從碼表翻譯器輸出的，在 script 翻譯器的視角看來，並不知
-- 道用戶輸出了「驚了」兩個字，所以造不出詞。
--
-- 目前版本的解決方法是：用戶選過字後，臨時禁用 table 翻譯器，使得
-- script 可以看到所有輸入，從而解決造詞問題。


-- 以下是zaran修改内容
-- 1. 添加万象词库所需的固词翻译器输出sentence
-- 2. 支持多句子输出

local moran = require("moran")
local top = {}

local kAny = 0
local kChar = 1
local kWord = 2
local short_code_cache_size = 512
local no_short_codes = {}

local function prepare_injections(env, fixed_cands, is_sentence_making)
    local first, later = {}, nil
    for _, cand in ipairs(fixed_cands) do
        local len = utf8.len(cand.text)
        local char = len == 1
        if (char and env.inject_fixed_chars) or (len > 2 and env.inject_fixed_words and not is_sentence_making) then
            if not char or not env.quick_code_indicator_skip_chars then
                cand:get_genuine().comment = env.quick_code_indicator
            end
            if (char and env.inject_prioritize == kWord) or (not char and env.inject_prioritize == kChar) then
                later = later or {}
                later[#later + 1] = cand
            else
                first[#first + 1] = cand
            end
        end
    end
    if later then
        for _, cand in ipairs(later) do
            first[#first + 1] = cand
        end
    end
    return first
end

local function collect_fixed(translation)
    local candidates = {}
    for cand in translation:iter() do
        candidates[#candidates + 1] = cand
    end
    return candidates
end

function top.init(env)
    -- Rime 組件
    env.fixed = Component.Translator(env.engine, "", "table_translator@fixed")
    env.smart = Component.Translator(env.engine, "", "script_translator@frequency")
    env.rfixed = moran.Thunk(function()
        return ReverseLookup(env.engine.schema.config:get_string("fixed/dictionary") or "moran_fixed")
    end)
    env.fixtranslator = Component.Translator(env.engine, "", "script_translator@translator")

    -- 簡快碼相關配置項
    env.quick_code_indicator = env.engine.schema.config:get_string("moran/quick_code_indicator") or "⚡️"
    env.quick_code_in_sentence_making = moran.get_config_bool(env, "moran/quick_code_in_sentence_making", true)
    if env.name_space == 'with_reorder' then
        -- `F 表示碼表輸出，會被 reorder_filter 重排
        env.quick_code_indicator = '`F'
    else
        -- 若不啓用 reorder_filter，則不允許造句時產生碼表輸出
        env.quick_code_in_sentence_making = false
    end

    -- 出簡讓全相關配置項
    env.ijrq_enable = env.engine.schema.config:get_bool("moran/ijrq/enable")
    if env.ijrq_enable then
        env.short_codes = {}
        env.short_code_queue = {}
        env.short_code_head = 1
    end
    env.ijrq_defer = env.engine.schema.config:get_int("moran/ijrq/defer") or env.engine.schema.config:get_int("menu/page_size") or 5
    env.ijrq_hint = env.engine.schema.config:get_bool("moran/ijrq/show_hint")
    env.ijrq_suffix = env.engine.schema.config:get_string("moran/ijrq/suffix") or 'o'
    env.enable_word_filter = env.engine.schema.config:get_bool("moran/enable_word_filter")
    env.word_filter_match_indicator = env.engine.schema.config:get_string("moran/word_filter_match_indicator")
    env.enable_aux_hint = env.engine.schema.config:get_bool("moran/enable_aux_hint")
    env.inject_fixed_chars = env.engine.schema.config:get_bool("moran/show_chars_anyway") or env.engine.schema.config:get_bool("moran/inject_fixed_chars")
    env.inject_fixed_words = env.engine.schema.config:get_bool("moran/show_words_anyway") or env.engine.schema.config:get_bool("moran/inject_fixed_words")

    local inject_prioritize = env.engine.schema.config:get_string("moran/inject_prioritize")
    if inject_prioritize == 'word' then
        env.inject_prioritize = kWord
    elseif inject_prioritize == 'char' then
        env.inject_prioritize = kChar
    else
        env.inject_prioritize = kAny
    end

    -- quick_code_hint 開啓時出簡讓全不應該輸出 comment，簡碼會由 quick_code_hint 輸出。
    env.enable_quick_code_hint = env.engine.schema.config:get_bool("moran/enable_quick_code_hint") or false
    env.quick_code_indicator_skip_chars = env.engine.schema.config:get_bool("moran/quick_code_indicator_skip_chars") or false

    -- disable_sentence_candidates_upto
    env.disable_sentence_candidates_upto = env.engine.schema.config:get_int("moran/disable_sentence_candidates_upto") or 0

    -- 候選總數上限：限制 smart 迭代器的 yield 總量，避免長句時全量遍歷。
    -- 可在 schema 中用 moran/max_candidates 配置，默認 150（約 30 頁）。
    env.max_candidates = env.engine.schema.config:get_int("moran/max_candidates") or 150
end

function top.fini(env)
    env.fixed = nil
    env.smart = nil
    env.rfixed = nil
    env.short_codes = nil
    env.short_code_queue = nil
    env.fixtranslator = nil
    collectgarbage()
end

-- 固定碼表在本方案實例內不變。只保留可參與讓全的一至三碼，維持詞典中的先後順序。
local function short_codes_for(env, text)
    local codes = env.short_codes[text]
    if codes then return codes end

    codes = no_short_codes
    for code in env.rfixed():lookup(text):gmatch("%S+") do
        if #code < 4 then
            if codes == no_short_codes then codes = {} end
            codes[#codes + 1] = code
        end
    end
    local queue = env.short_code_queue
    if #queue == short_code_cache_size then
        local head = env.short_code_head
        env.short_codes[queue[head]] = nil
        queue[head] = text
        env.short_code_head = head % short_code_cache_size + 1
    else
        queue[#queue + 1] = text
    end
    env.short_codes[text] = codes
    return codes
end

-- 通常在 Rime 取走首選後回收。若候選流提前丟棄，下一次查詢補做這一步。
local function collect_pending(env)
    if env.gc_pending then
        env.gc_pending = false
        collectgarbage("step", 0)
    end
end

local function output_from_fixed(env, cand, is_sentence_making, len, output)
    if len == 1 then
        if not env.quick_code_indicator_skip_chars then
            cand.comment = env.quick_code_indicator
        end
        output(cand)
    elseif not is_sentence_making or len == 2 then
        cand.comment = env.quick_code_indicator
        output(cand)
    end
end

-- 模型與動態詞頻使用各自的配置。模型只取其首選。
local function output_model(env, input, seg, output)
    local cand = moran.query_translation(env.fixtranslator, input, seg)()
    if cand then
        cand.type = 'model'
        output(cand)
    end
end

local function transform_aux_comment(cand)
    local cand_len = utf8.len(cand.text)
    if cand_len == 2 or cand_len == 3 then
        cand:get_genuine().comment = cand.comment:gsub("[a-z]+;([a-z])[a-z] ?", "%1")
    end
    return cand
end

function top.func(input, seg, env)
    collect_pending(env)
    env.gc_pending = true

    local input_len = utf8.len(input)
    local context = env.engine.context
    local indicator = env.quick_code_indicator
    local suppress_smart = env.disable_sentence_candidates_upto >= input_len

    local is_sentence_making = context.input ~= input
    local allow_fixed = not is_sentence_making or env.quick_code_in_sentence_making
    local fixed_scanned = false
    local fixed_cands
    local fixed_translation
    local inject_pending = false
    local output_count = 0

    local function output(cand)
        yield(cand)
        output_count = output_count + 1
        if output_count == 1 then
            collect_pending(env)
            if inject_pending then
                if fixed_translation then
                    fixed_cands = collect_fixed(fixed_translation)
                    fixed_translation = nil
                end
                local injected = prepare_injections(env, fixed_cands, is_sentence_making)
                fixed_cands = nil
                for _, injected_cand in ipairs(injected) do
                    yield(injected_cand)
                    output_count = output_count + 1
                end
            end
        end
    end

    if input_len == 4 then
        local direct = allow_fixed and context:get_option("inflexible")
        local chars = env.inject_fixed_chars
        local words = env.inject_fixed_words
        if direct then
            fixed_scanned = true
            for cand in moran.query_translation(env.fixed, input, seg) do
                local len = utf8.len(cand.text)
                if (chars and words) or len == 2 or (chars and len == 1) or (words and len > 1) then
                    output_from_fixed(env, cand, is_sentence_making, len, output)
                end
                -- 只有整批都未直接輸出才需要注入或兜底。
                if output_count == 0 then
                    fixed_cands = fixed_cands or {}
                    fixed_cands[#fixed_cands + 1] = cand
                else
                    fixed_cands = nil
                end
            end
        elseif chars or (words and not is_sentence_making) then
            -- 在當前 segment 建立碼表查詢，等 Rime 取走首選才讀取次選。
            fixed_scanned = true
            fixed_translation = env.fixed:query(input, seg)
        end
        inject_pending = (fixed_translation or fixed_cands) and (chars or (words and not is_sentence_making))
    elseif not is_sentence_making or (input_len < 4 and allow_fixed) then
        -- 非四碼只走一遍碼表；造詞時，兜底也只會接受這裏已檢查過的單字。
        for cand in moran.query_translation(env.fixed, input, seg) do
            local len = utf8.len(cand.text)
            if not is_sentence_making or len == 1 then
                output_from_fixed(env, cand, is_sentence_making, len, output)
            end
        end
        fixed_scanned = true
    end

    -- 詞輔在正常輸出之前，以提高其優先級
    if env.enable_word_filter and not suppress_smart and (input_len == 5 or input_len == 7) then
        local real_input = input:sub(1, input_len - 1)
        local user_ac = input:sub(input_len, input_len)
        local iter = moran.query_translation(env.smart, real_input, seg, transform_aux_comment)
        for cand in iter do
            local preedit = cand.preedit
            local len_match = (input_len == 7 and #preedit == 8) or (input_len == 5 and #preedit == 5)
            if len_match and cand.comment:find(user_ac) and preedit:byte(3) == 32
                and (#preedit < 6 or preedit:byte(6) == 32) then
                cand._end = cand._end + 1
                cand.preedit = input
                if env.word_filter_match_indicator then
                    cand.comment = env.word_filter_match_indicator
                end
                output(cand)
                preedit = cand.preedit
            end
            if #preedit <= 2 then break end
        end
    end

    -- smart 在 fixed 之後輸出。
    -- 當需要詞輔時，保留 comment，以「提前」（用戶輸入詞輔前）提示輔助碼。
    if not suppress_smart then
        local transform = env.enable_word_filter and env.enable_aux_hint and transform_aux_comment or nil
        local smart_iter = moran.query_translation(env.smart, input, seg, transform)
        local ijrq_enabled = env.ijrq_enable
            and (env.engine.context.input == input)
            and ((input_len == 4) or (input_len == 5 and input:sub(5,5) == env.ijrq_suffix))

        local cand = smart_iter()
        if cand and cand.type == "sentence" then
            output_model(env, input, seg, output)
            local sentences = {}
            repeat
                sentences[#sentences + 1] = cand
                cand = smart_iter()
            until not cand or cand.type ~= "sentence"
            while cand and cand.type == "completion" do
                output(cand)
                cand = smart_iter()
            end
            for _, sentence in ipairs(sentences) do
                output(sentence)
            end
        end

        if ijrq_enabled then
            -- 在第一個多字詞結束讓全。先輸出 defer 個不讓全的候選，
            -- 再輸出讓全候選，最後補上等待期間暫存的其餘候選。
            local immediate_set = {}
            local deferred_set = {}
            local head_count = 0
            local input_prefix = input:sub(1,4)
            while cand and (ijrq_enabled or head_count < env.ijrq_defer) do
                local cand_len = ijrq_enabled and utf8.len(cand.text)
                local defer = false
                -- 如果輸出有詞，說明在拼詞，用戶很可能要使用高頻字，故此時停止出簡讓全。
                if (ijrq_enabled and cand_len > 1) then
                    ijrq_enabled = false
                end
                if (ijrq_enabled and cand_len == 1) then
                    for _, code in ipairs(short_codes_for(env, cand.text)) do
                        if input:sub(1, #code) == code then
                            defer = true
                            if env.ijrq_hint and not env.enable_quick_code_hint and cand.preedit:sub(1,4) == input_prefix then
                                cand.comment = code
                            end
                            break
                        end
                    end
                end
                if defer then
                    table.insert(deferred_set, cand)
                elseif head_count < env.ijrq_defer then
                    -- 前 defer 個不讓全的候選位置已確定，翻頁時再繼續查後面的字。
                    head_count = head_count + 1
                    output(cand)
                else
                    table.insert(immediate_set, cand)
                end
                cand = smart_iter()
            end
            for i = 1, #deferred_set do
                output(deferred_set[i])
            end
            for i = 1, #immediate_set do
                output(immediate_set[i])
            end
        end
        while cand and output_count < env.max_candidates do
            output(cand)
            if output_count >= env.max_candidates then break end
            cand = smart_iter()
        end
    end

    -- 沒有首選時按碼表順序兜底，保留注入候選的原始注釋處理。
    if output_count == 0 and (fixed_translation or fixed_cands or not fixed_scanned) then
        if fixed_translation then
            fixed_cands = collect_fixed(fixed_translation)
            fixed_translation = nil
        else
            fixed_cands = fixed_cands or moran.drain_translation(env.fixed, input, seg)
        end
        if inject_pending then prepare_injections(env, fixed_cands, is_sentence_making) end
        for _, cand in ipairs(fixed_cands) do
            if not is_sentence_making or utf8.len(cand.text) == 1 then
                cand.comment = indicator
                yield(cand)
                collect_pending(env)
            end
        end
    end
    collect_pending(env)
end


return top

-- Local Variables:
-- lua-indent-level: 4
-- End:
