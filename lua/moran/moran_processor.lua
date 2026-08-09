-- moran_processor.lua
-- Synopsis: 適用於魔然方案默認模式的按鍵處理器
-- Author: ksqsf
-- License: MIT license
-- Version: 0.5.8 (Enhanced Integration, perf-tuned / scalar-state)

local moran = require("moran")

local kReject = 0
local kAccepted = 1
local kNoop = 2

local function has_tag(segment, tag)
   local tags = segment.tags
   for i = 1, #tags do
      if tags[i] == tag then return true end
   end
   return false
end

local function add_tag(segment, tag)
   if not has_tag(segment, tag) then
      table.insert(segment.tags, tag)
   end
end

local function remove_tag(segment, tag)
   local tags = segment.tags
   for i = #tags, 1, -1 do
      if tags[i] == tag then
         table.remove(tags, i)
      end
   end
end

-- 重置连续字母轮询状态（标量，恒定内存）
local function reset_cl_state(env)
   env.cl_raw = nil
   env.cl_count = 1
   env.cl_first_pos = 3
   env.cl_second_pos = 5
end

local function semicolon_processor(key_event, env)
   if key_event.keycode ~= 0x3B then return kNoop end
   local context = env.engine.context
   local composition = context.composition
   if composition:empty() then return kNoop end

   local input = context.input
   if input:find('^ovy') or input:find('^;') then return kNoop end

   local segment = composition:back()
   local menu = segment.menu
   local page_size = env.page_size
   if not page_size then
      page_size = env.engine.schema.page_size
      env.page_size = page_size
   end

   local candidate_count = menu:prepare(page_size)
   if candidate_count == 1 then
      context:select(0)
      return kAccepted
   end

   local selected_index = segment.selected_index
   if selected_index >= page_size then
      local page_num = math.floor(selected_index / page_size)
      context:select(page_num * page_size + 1)
      return kAccepted
   end

   for i = 1, page_size - 1 do
      local cand = menu:get_candidate_at(i)
      if cand == nil then
         context:select(1)
         return kNoop
      end
      local codepoint = utf8.codepoint(cand.text, 1)
      if moran.unicode_code_point_is_chinese(codepoint)
         or (codepoint >= 97 and codepoint <= 122)
         or (codepoint >= 65 and codepoint <= 90)
         or (codepoint >= 48 and codepoint <= 57 and cand.type ~= "simplified")
      then
         context:select(i)
         return kAccepted
      end
   end

   context:select(1)
   return kAccepted
end

local function steal_auxcode_processor(key_event, env)
   if not (key_event:ctrl()
      and (key_event.keycode == 0x7a or key_event.keycode == 0x6c or key_event.keycode == 0x6f)) then
      return kNoop
   end

   local ctx = env.engine.context
   local segs = ctx.composition:toSegmentation():get_segments()
   local n = #segs
   if n < 2 then return kNoop end

   local stealer = segs[n]
   local stealee = segs[n - 1]

   if not (stealee.status == 'kSelected' or stealee.status == 'kConfirmed') then
      return kNoop
   end

   if has_tag(stealee, "_moran_stealee") then
      ctx.input = ctx.input:sub(1, stealer._start) .. ctx.input:sub(stealer._start + 2)
      remove_tag(stealee, "_moran_stealee")
      return kAccepted
   end

   local preedit = stealee:get_selected_candidate().preedit
   local plen = #preedit
   local auxcode

   if plen >= 11 then
      auxcode = preedit:match("[a-z][a-z][ '][a-z][a-z][ '][a-z][a-z][ '][a-z][a-z]([a-z])")
   end
   if not auxcode and plen >= 8 then
      auxcode = preedit:match("[a-z][a-z][ '][a-z][a-z][ '][a-z][a-z]([a-z])")
   end
   if not auxcode and plen >= 5 then
      auxcode = preedit:match("[a-z][a-z][ '][a-z][a-z]([a-z])")
              or preedit:match("[a-z][a-z][a-z][ '][a-z][a-z]([a-z])")
   end
   if not auxcode then
      if plen == 3 and preedit:match("^[a-z][a-z][a-z]$") then
         auxcode = preedit:match("[a-z][a-z]([a-z])$")
      end
   end

   if not auxcode then return kNoop end

   ctx.input = ctx.input:sub(1, stealer._start) .. auxcode .. ctx.input:sub(stealer._start + 1)
   add_tag(stealee, "_moran_stealee")
   return kAccepted
end

local function force_segmentation_processor(key_event, env)
   if not (key_event:ctrl() and (key_event.keycode == 0x7a or key_event.keycode == 0x6c)) then
      return kNoop
   end

   local ctx = env.engine.context
   local composition = ctx.composition
   if composition:empty() then return kNoop end

   local seg = composition:back()
   local input = ctx.input:sub(seg._start + 1, seg._end)
   local raw = input:gsub("'", "")
   local head = ctx.input:sub(1, seg._start)
   local tail = ctx.input:sub(seg._end + 1, -1)

   -- 三码轮询 / 双三码轮询的退出
   if (env.continuous_letter_mode == 3 or env.continuous_letter_mode == 4)
      and raw:match("^[a-z]+$") then
      ctx.input = head .. raw .. tail
      env.continuous_letter_mode = 0
      reset_cl_state(env)
      return kAccepted
   end

   local cand = seg:get_selected_candidate()
   if cand == nil then return kNoop end
   local preedit = cand.preedit

   if input:match("^[a-z][a-z][a-z][a-z]o$") then
      ctx.input = head .. raw:sub(1, 2) .. "'" .. raw:sub(3, 5) .. tail
      return kAccepted
   end

   if preedit:match("^[a-z][a-z][a-z][a-z]$") then
      ctx.input = head .. raw:sub(1, 2) .. "'" .. raw:sub(3, 4) .. tail
      return kAccepted
   elseif input:match("^[a-z][a-z]'[a-z][a-z]$") then
      ctx.input = head .. raw .. tail
      return kAccepted
   end

   if preedit:match("^[a-z][a-z][ '][a-z][a-z][a-z]$") or input:match("^[a-z][a-z]'[a-z][a-z][a-z]$") then
      ctx.input = head .. raw:sub(1, 3) .. "'" .. raw:sub(4, 5) .. tail
   elseif preedit:match("^[a-z][a-z][a-z][ '][a-z][a-z]$") or input:match("^[a-z][a-z][a-z]'[a-z][a-z]$") then
      ctx.input = head .. raw:sub(1, 2) .. "'" .. raw:sub(3, 5) .. tail
   elseif preedit:match("^[a-z][a-z][a-z][ '][a-z][a-z][a-z]$") or input:match("^[a-z][a-z][a-z]'[a-z][a-z][a-z]$") then
      ctx.input = head .. raw:sub(1, 2) .. "'" .. raw:sub(3, 4) .. "'" .. raw:sub(5, 6) .. tail
   elseif preedit:match("^[a-z][a-z][ '][a-z][a-z][ '][a-z][a-z]$") or input:match("^[a-z][a-z]'[a-z][a-z]'[a-z][a-z]$") then
      ctx.input = head .. raw:sub(1, 3) .. "'" .. raw:sub(4, 6) .. tail
   elseif preedit:match("^[a-z][a-z][ '][a-z][a-z][ '][a-z][a-z][a-z]$") or input:match("^[a-z][a-z]'[a-z][a-z]'[a-z][a-z][a-z]$") then
      ctx.input = head .. raw:sub(1, 2) .. "'" .. raw:sub(3, 5) .. "'" .. raw:sub(6, 7) .. tail
   elseif preedit:match("^[a-z][a-z][ '][a-z][a-z][a-z][ '][a-z][a-z]$") or input:match("^[a-z][a-z]'[a-z][a-z][a-z]'[a-z][a-z]$") then
      ctx.input = head .. raw:sub(1, 3) .. "'" .. raw:sub(4, 5) .. "'" .. raw:sub(6, 7) .. tail
   elseif preedit:match("^[a-z][a-z][a-z][ '][a-z][a-z][ '][a-z][a-z]$") or input:match("^[a-z][a-z][a-z]'[a-z][a-z]'[a-z][a-z]$") then
      ctx.input = head .. raw:sub(1, 2) .. "'" .. raw:sub(3, 4) .. "'" .. raw:sub(5, 6) .. tail
   else
      return kNoop
   end

   return kAccepted
end

local function continuous_letter_processor(key_event, env)
   if not (key_event:ctrl() and key_event.keycode == 0x6e) then return kNoop end
   local ctx = env.engine.context
   local composition = ctx.composition
   if composition:empty() then return kNoop end

   local seg = composition:back()
   local input = ctx.input:sub(seg._start + 1, seg._end)
   local raw = input:gsub("'", "")
   if not raw:match("^[a-z]+$") then return kNoop end

   if not env.continuous_letter_mode then env.continuous_letter_mode = 0 end

   -- raw 变化即重置轮询状态（标量，恒定内存，杜绝 [raw] 缓存增长）
   if env.cl_raw ~= raw then
      env.cl_raw = raw
      env.cl_count = 1
      env.cl_first_pos = 3
      env.cl_second_pos = 5
   end

   local current_mode = env.continuous_letter_mode
   local rawlen = #raw
   local processed = raw
   local head = ctx.input:sub(1, seg._start)
   local tail = ctx.input:sub(seg._end + 1, -1)

   if current_mode == 3 then
      if rawlen <= 3 then
         processed = raw
      else
         env.cl_count = env.cl_count + 1
         if env.cl_count > rawlen - 1 then
            -- 进入双三码轮询 mode 4
            env.continuous_letter_mode = 4
            env.cl_first_pos = 3
            env.cl_second_pos = 6
            if rawlen <= 5 then
               processed = raw
            else
               processed = raw:sub(1, 3) .. "'" .. raw:sub(4, 6) .. "'" .. raw:sub(7)
            end
         else
            local first_split_pos = env.cl_count
            local parts = { raw:sub(1, first_split_pos), raw:sub(first_split_pos + 1, first_split_pos + 3) }
            local remaining = raw:sub(first_split_pos + 4)
            if #remaining > 0 then parts[#parts + 1] = remaining end
            processed = table.concat(parts, "'")
         end
      end

   elseif current_mode == 4 then
      if rawlen <= 5 then
         processed = raw
      else
         local first_pos = env.cl_first_pos
         local second_pos = env.cl_second_pos
         local max_second_pos = rawlen - 2
         local found = false
         local exited = false

         while true do
            second_pos = second_pos + 1
            if second_pos > max_second_pos then
               first_pos = first_pos + 3
               second_pos = first_pos + 2
               if first_pos >= rawlen - 3 or second_pos > max_second_pos then
                  env.continuous_letter_mode = 0
                  reset_cl_state(env)
                  exited = true
                  break
               end
            end
            local part1_len = first_pos
            local part2_len = second_pos - first_pos
            local part3_len = rawlen - second_pos
            if part1_len >= 2 and part2_len >= 2 and part3_len >= 2 then
               found = true
               break
            end
         end

         if not found or exited then
            processed = raw
         else
            env.cl_first_pos = first_pos
            env.cl_second_pos = second_pos
            processed = raw:sub(1, first_pos) .. "'"
                     .. raw:sub(first_pos + 1, second_pos) .. "'"
                     .. raw:sub(second_pos + 1)
         end
      end

   else
      env.continuous_letter_mode = (current_mode + 1) % 5
      current_mode = env.continuous_letter_mode
      if current_mode == 1 then
         local parts = {}
         for i = 1, rawlen, 2 do parts[#parts + 1] = raw:sub(i, i + 1) end
         processed = table.concat(parts, "'")
      elseif current_mode == 2 then
         local parts = {}
         for i = 1, rawlen, 3 do parts[#parts + 1] = raw:sub(i, i + 2) end
         processed = table.concat(parts, "'")
      elseif current_mode == 3 then
         env.cl_count = 2
         if rawlen <= 3 then
            processed = raw
         else
            local parts = { raw:sub(1, 2), raw:sub(3, 5) }
            local remaining = raw:sub(6)
            if #remaining > 0 then parts[#parts + 1] = remaining end
            processed = table.concat(parts, "'")
         end
      elseif current_mode == 4 then
         env.cl_first_pos = 3
         env.cl_second_pos = 5
         if rawlen <= 5 then
            processed = raw
         else
            processed = raw:sub(1, 3) .. "'" .. raw:sub(4, 6) .. "'" .. raw:sub(7)
         end
      end
   end

   ctx.input = head .. processed .. tail
   return kAccepted
end

local shorthands = {
   [string.byte("B")] = function(env, s) return s .. "不" .. s end,
   [string.byte("L")] = function(env, s) return s .. "了" .. s end,
   [string.byte("Y")] = function(env, s) return s .. "一" .. s end,
   [string.byte("V")] = function(env, s)
      if not env.engine.context:get_option("std_tw") then
         return s .. "着" .. s .. "着"
      else
         return s .. "著" .. s .. "著"
      end
   end,
   [string.byte("Q")] = function(env, s)
      if env.engine.context:get_option("simplification") == true then
         return s .. "来" .. s .. "去"
      else
         return s .. "來" .. s .. "去"
      end
   end,
}

local function shorthand_processor(key_event, env)
   local shf = shorthands[key_event.keycode]
   if not key_event:shift() or shf == nil then return kNoop end
   local composition = env.engine.context.composition
   if composition:empty() then return kNoop end
   local segment = composition:back()
   local cand = segment:get_selected_candidate()
   env.engine:commit_text(shf(env, cand.text))
   env.engine.context:clear()
   return kAccepted
end

return {
   init = function(env)
      env.processors = {
         semicolon_processor,
         steal_auxcode_processor,
         force_segmentation_processor,
         continuous_letter_processor,
      }
      env.continuous_letter_mode = 0
      env.page_size = env.engine.schema.page_size
      reset_cl_state(env)
      if env.engine.schema.config:get_bool("moran/shorthands") then
         table.insert(env.processors, shorthand_processor)
      end
   end,

   fini = function(env)
   end,

   func = function(key_event, env)
      if key_event:release() then return kNoop end
      local processors = env.processors
      for i = 1, #processors do
         local res = processors[i](key_event, env)
         if res == kAccepted or res == kReject then
            return res
         end
      end
      return kNoop
   end,
}