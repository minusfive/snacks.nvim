local Async = require("snacks.picker.util.async")

---@class snacks.picker.Matcher
---@field opts snacks.picker.matcher.Config
---@field mods snacks.picker.matcher.Mods[][]
---@field one? snacks.picker.matcher.Mods
---@field pattern string
---@field tick number
---@field task snacks.picker.Async
---@field live? boolean
local M = {}
M.__index = M
M.DEFAULT_SCORE = 1000
M.INVERSE_SCORE = 1000

local YIELD_MATCH = 5 -- ms
local clear = require("table.clear")

---@class snacks.picker.matcher.Mods
---@field pattern string
---@field chars string[]
---@field entropy number higher entropy is less likely to match
---@field field? string
---@field ignorecase? boolean
---@field fuzzy? boolean
---@field word? boolean
---@field exact_suffix? boolean
---@field exact_prefix? boolean
---@field inverse? boolean

-- PERF: reuse tables to avoid allocations and GC
local fuzzy_positions = {} ---@type number[]
local fuzzy_best_positions = {} ---@type number[]
local fuzzy_last_positions = {} ---@type number[]
local fuzzy_fast_positions = {} ---@type number[]

---@param t number[]
function M.clear(t)
  clear(t) -- luajit table.clear is faster
  return t
end

---@param opts? snacks.picker.matcher.Config
function M.new(opts)
  local self = setmetatable({}, M)
  self.opts = vim.tbl_deep_extend("force", {
    fuzzy = true,
    smartcase = true,
    ignorecase = true,
  }, opts or {})
  self.pattern = ""
  self.task = Async.nop()
  self.mods = {}
  self.tick = 0
  return self
end

function M:empty()
  return not next(self.mods)
end

function M:running()
  return self.task:running()
end

function M:abort()
  self.task:abort()
end

---@param picker snacks.Picker
---@param opts? {prios?: snacks.picker.Item[]}
function M:run(picker, opts)
  opts = opts or {}
  self.task:abort()

  -- PERF: fast path for empty pattern
  if self:empty() and not picker.finder.task:running() then
    picker.list.items = picker.finder.items
    picker:update()
    return
  end

  ---@async
  self.task = Async.new(function()
    local yield = Async.yielder(YIELD_MATCH)
    local idx = 0

    ---@async
    ---@param item snacks.picker.Item
    local function check(item)
      if self:update(item) and item.score > 0 then
        picker.list:add(item)
      end
      yield()
    end

    -- process high priority items first
    for _, item in ipairs(opts.prios or {}) do
      check(item)
    end

    repeat
      -- then the rest
      while idx < #picker.finder.items do
        idx = idx + 1
        check(picker.finder.items[idx])
      end

      -- suspend till we have more items
      if picker.finder.task:running() then
        Async.suspend()
      end
    until idx >= #picker.finder.items and not picker.finder.task:running()

    picker:update()
  end)
end

---@param opts? {pattern?: string}
function M:init(opts)
  opts = opts or {}
  self.tick = self.tick + 1
  local pattern = vim.trim(opts.pattern or self.pattern)
  self.mods = {}
  self.pattern = pattern
  self:abort()
  self.one = nil
  if pattern == "" then
    return
  end
  local is_or = false
  for _, p in ipairs(vim.split(pattern, " +")) do
    if p == "|" then
      is_or = true
    else
      local mods = self:_prepare(p)
      if mods.pattern ~= "" then
        if is_or and #self.mods > 0 then
          table.insert(self.mods[#self.mods], mods)
        else
          table.insert(self.mods, { mods })
        end
      end
      is_or = false
    end
  end
  for _, ors in ipairs(self.mods) do
    -- sort by entropy, lower entropy is more likely to match
    table.sort(ors, function(a, b)
      return a.entropy < b.entropy
    end)
  end
  -- sort by entropy, higher entropy is less likely to match
  table.sort(self.mods, function(a, b)
    return a[1].entropy > b[1].entropy
  end)
  if #self.mods == 1 and #self.mods[1] == 1 then
    self.one = self.mods[1][1]
  end
end

---@param pattern string
---@return snacks.picker.matcher.Mods
function M:_prepare(pattern)
  ---@type snacks.picker.matcher.Mods
  local mods = { pattern = pattern, entropy = 0, chars = {} }
  local field, p = pattern:match("^([%w_]+):(.*)$")
  if field then
    mods.field = field
    mods.pattern = p
  end
  mods.ignorecase = self.opts.ignorecase
  local is_lower = mods.pattern:lower() == mods.pattern
  if self.opts.smartcase then
    mods.ignorecase = is_lower
  end
  mods.fuzzy = self.opts.fuzzy
  if not mods.fuzzy then
    mods.entropy = mods.entropy + 10
  end
  if mods.pattern:sub(1, 1) == "!" then
    mods.fuzzy, mods.inverse = false, true
    mods.pattern = mods.pattern:sub(2)
    mods.entropy = mods.entropy - 1
  end
  if mods.pattern:sub(1, 1) == "'" then
    mods.fuzzy = false
    mods.pattern = mods.pattern:sub(2)
    mods.entropy = mods.entropy + 10
    if mods.pattern:sub(-1, -1) == "'" then
      mods.word = true
      mods.pattern = mods.pattern:sub(1, -2)
      mods.entropy = mods.entropy + 10
    end
  elseif mods.pattern:sub(1, 1) == "^" then
    mods.fuzzy, mods.exact_prefix = false, true
    mods.pattern = mods.pattern:sub(2)
    mods.entropy = mods.entropy + 20
  end
  if mods.pattern:sub(-1, -1) == "$" then
    mods.fuzzy = false
    mods.exact_suffix = true
    mods.pattern = mods.pattern:sub(1, -2)
    mods.entropy = mods.entropy + 20
  end
  local rare_chars = #mods.pattern:gsub("[%w%s]", "")
  mods.entropy = mods.entropy + math.min(#mods.pattern, 20) + rare_chars * 2
  if not mods.ignorecase and not is_lower then
    mods.entropy = mods.entropy * 2
  end
  for c = 1, #mods.pattern do
    mods.chars[c] = mods.pattern:sub(c, c)
  end
  return mods
end

---@param item snacks.picker.Item
---@return boolean updated
function M:update(item)
  if item.match_tick == self.tick then
    return false
  end
  local score = self:match(item)
  item.match_tick, item.score = self.tick, score
  return true
end

--- Matches an item and returns the score.
--- Score is 0 if no match is found.
---@param item snacks.picker.Item
function M:match(item)
  if self:empty() then
    return M.DEFAULT_SCORE -- empty pattern matches everything
  end
  local score, s = 0, nil
  -- fast path for single pattern
  if self.one then
    return self:_match(item, self.one) or 0
  end
  for _, any in ipairs(self.mods) do
    -- fast path for single OR pattern
    if #any == 1 then
      s = self:_match(item, any[1])
    else
      for _, mods in ipairs(any) do
        s = self:_match(item, mods)
        if s then
          break
        end
      end
    end
    if not s then
      return 0
    end
    score = score + s
  end
  return score
end

--- Returns the positions of the matched pattern in the item.
--- All search patterns are combined with OR.
---@param item snacks.picker.Item
function M:positions(item)
  local all = {} ---@type snacks.picker.matcher.Mods[]
  local ret = {} ---@type number[]
  for _, any in ipairs(self.mods) do
    vim.list_extend(all, any)
  end
  for _, mods in ipairs(all) do
    local _, from, to, str = self:_match(item, mods)
    if from and to and str then
      if mods.fuzzy then
        vim.list_extend(ret, self:fuzzy_positions(str, mods.chars, from))
      else
        for c = from, to do
          ret[#ret + 1] = c
        end
      end
    end
  end
  return ret
end

---@param str string
---@param pattern string[]
---@param from number
function M:fuzzy_positions(str, pattern, from)
  local ret = { from } ---@type number[]
  for i = 2, #pattern do
    ret[#ret + 1] = string.find(str, pattern[i], ret[#ret] + 1, true)
  end
  return ret
end

---@param str string
---@param c number
function M.is_alpha(str, c)
  local b = str:byte(c, c)
  return (b >= 65 and b <= 90) or (b >= 97 and b <= 122)
end

---@param item snacks.picker.Item
---@param mods snacks.picker.matcher.Mods
---@return number? score, number? from, number? to, string? str
function M:_match(item, mods)
  local str = item.text
  if mods.field then
    if item[mods.field] == nil then
      if mods.inverse then
        return 0, 0
      end
      return
    end
    str = tostring(item[mods.field])
  end

  str = mods.ignorecase and str:lower() or str
  local from, to ---@type number?, number?
  if mods.fuzzy then
    from, to = self:fuzzy(str, mods.chars)
  else
    if mods.exact_prefix then
      if str:sub(1, #mods.pattern) == mods.pattern then
        from, to = 1, #mods.pattern
      end
    elseif mods.exact_suffix then
      if str:sub(-#mods.pattern) == mods.pattern then
        from, to = #str - #mods.pattern + 1, #str
      end
    else
      from, to = str:find(mods.pattern, 1, true)
      -- word match
      while mods.word and from and to do
        local bound_left = from == 1 or not M.is_alpha(str, from - 1)
        local bound_right = to == #str or not M.is_alpha(str, to + 1)
        if bound_left and bound_right then
          break
        end
        from, to = str:find(mods.pattern, to + 1, true)
      end
    end
    if mods.inverse then
      if not from then
        return 0, 0
      end
      return
    end
  end
  if from then
    ---@cast to number
    return M.score(from, to, #str), from, to, str
  end
end

---@param from number
---@param to number
---@param len number
function M.score(from, to, len)
  return 1000 / (to - from + 1) -- calculate compactness score (distance between first and last match)
    + (100 / from) -- add bonus for early match
    + (100 / (len + 1)) -- add bonus for string length
end

---@param str string
---@param pattern string[]
---@param init? number
---@return number? from, number? to
function M:fuzzy_find(str, pattern, init)
  local from = string.find(str, pattern[1], init or 1, true)
  if not from then
    return
  end
  ---@type number?, number
  local last, n = from, #pattern
  for i = 2, n do
    last = string.find(str, pattern[i], last + 1, true)
    if not last then
      return
    end
  end
  return from, last
end

--- Does a forward scan followed by a backward scan for each end position,
--- to find the best match.
---@param str string
---@param pattern string[]
---@return number? from, number? to
function M:fuzzy(str, pattern)
  local from, to = self:fuzzy_find(str, pattern)
  if not from then
    return
  elseif from == to then
    return from, to
  end

  local best_from, best_to, best_width = from, to, to - from
  repeat
    local width = to - from
    if width < best_width then
      best_from, best_to, best_width = from, to, width
    end
    from, to = self:fuzzy_find(str, pattern, from + 1)
  until not from
  return best_from, best_to
end

return M