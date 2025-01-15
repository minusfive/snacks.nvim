local M = {}

local uv = vim.uv or vim.loop

---@class snacks.picker
---@field grep fun(opts?: snacks.picker.grep.Config): snacks.Picker
---@field grep_word fun(opts?: snacks.picker.grep.Config): snacks.Picker
---@field grep_buffers fun(opts?: snacks.picker.grep.Config): snacks.Picker

---@param opts snacks.picker.grep.Config
---@param filter snacks.picker.Filter
local function get_cmd(opts, filter)
  local cmd = "rg"
  local args = {
    "--color=never",
    "--no-heading",
    "--with-filename",
    "--line-number",
    "--column",
    "--smart-case",
    "--max-columns=500",
    "--max-columns-preview",
    "-g",
    "!.git",
  }

  args = vim.deepcopy(args)

  -- hidden
  if opts.hidden then
    table.insert(args, "--hidden")
  else
    table.insert(args, "--no-hidden")
  end

  -- ignored
  if opts.ignored then
    args[#args + 1] = "--no-ignore"
  end

  -- follow
  if opts.follow then
    args[#args + 1] = "-L"
  end

  local types = type(opts.ft) == "table" and opts.ft or { opts.ft }
  ---@cast types string[]
  for _, t in ipairs(types) do
    args[#args + 1] = "-t"
    args[#args + 1] = t
  end

  if opts.regex == false then
    args[#args + 1] = "--fixed-strings"
  end

  local glob = type(opts.glob) == "table" and opts.glob or { opts.glob }
  ---@cast glob string[]
  for _, g in ipairs(glob) do
    args[#args + 1] = "-g"
    args[#args + 1] = g
  end

  args[#args + 1] = "--"

  -- search pattern
  table.insert(args, filter.search)

  local paths = {} ---@type string[]

  if opts.buffers then
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
      local name = vim.api.nvim_buf_get_name(buf)
      if name ~= "" and vim.bo[buf].buflisted and uv.fs_stat(name) then
        paths[#paths + 1] = name
      end
    end
  elseif opts.dirs and #opts.dirs > 0 then
    paths = opts.dirs or {}
  end

  -- dirs
  if #paths > 0 then
    paths = vim.tbl_map(vim.fs.normalize, paths) ---@type string[]
    vim.list_extend(args, paths)
  end

  return cmd, args
end

---@param opts snacks.picker.grep.Config
---@type snacks.picker.finder
function M.grep(opts, filter)
  if opts.need_search ~= false and filter.search == "" then
    return function() end
  end
  local absolute = (opts.dirs and #opts.dirs > 0) or opts.buffers
  local cwd = not absolute and vim.fs.normalize(opts and opts.cwd or uv.cwd() or ".") or nil
  local cmd, args = get_cmd(opts, filter)
  return require("snacks.picker.source.proc").proc(vim.tbl_deep_extend("force", {
    notify = false,
    cmd = cmd,
    args = args,
    ---@param item snacks.picker.finder.Item
    transform = function(item)
      item.cwd = cwd
      local file, line, col, text = item.text:match("^(.+):(%d+):(%d+):(.*)$")
      if not file then
        if not item.text:match("WARNING") then
          error("invalid grep output: " .. item.text)
        end
        return false
      else
        item.line = text
        item.file = file
        item.pos = { tonumber(line), tonumber(col) }
      end
    end,
  }, opts or {}))
end

return M