local Main = require("trouble.view.main")
local Util = require("trouble.util")

---@class trouble.Window.split
---@field type "split"
---@field relative "editor" | "win" cursor is only valid for float
---@field size number | {width:number, height:number} when a table is provided, either the width or height is used based on the position
---@field position "top" | "bottom" | "left" | "right"

---@class trouble.Window.float
---@field type "float"
---@field relative "editor" | "win" | "cursor" cursor is only valid for float
---@field size {width: number, height: number}
---@field position {[1]: number, [2]: number}
---@field anchor? string
---@field focusable? boolean
---@field zindex? integer
---@field border? any
---@field title? string|{[1]: string, [2]: string}
---@field title_pos? string
---@field footer? string|{[1]: string, [2]: string}
---@field footer_pos? string
---@field fixed? boolean

---@class trouble.Window.main
---@field type "main"

---@class trouble.Window.base
---@field padding? {top?:number, left?:number}
---@field wo? vim.wo
---@field bo? vim.bo
---@field minimal? boolean (defaults to true)
---@field win? number
---@field scratch? boolean preview only: use a scratch buffer for unloaded files
---@field on_mount? fun(self: trouble.Window)
---@field on_close? fun(self: trouble.Window)

---@alias trouble.Window.opts trouble.Window.base|trouble.Window.split|trouble.Window.float|trouble.Window.main

---@class trouble.Window
---@field opts trouble.Window.opts
---@field win? number
---@field buf number
---@field id number
---@field keys table<string, string>
local M = {}
M.__index = M

local _id = 0
local function next_id()
  _id = _id + 1
  return _id
end

local split_commands = {
  editor = {
    top = "topleft",
    right = "vertical botright",
    bottom = "botright",
    left = "vertical topleft",
  },
  win = {
    top = "aboveleft",
    right = "vertical rightbelow",
    bottom = "belowright",
    left = "vertical leftabove",
  },
}

local float_options = {
  "anchor",
  "border",
  "bufpos",
  "col",
  "external",
  "fixed",
  "focusable",
  "footer",
  "footer_pos",
  "height",
  "hide",
  "noautocmd",
  "relative",
  "row",
  "style",
  "title",
  "title_pos",
  "width",
  "win",
  "zindex",
}

---@type trouble.Window.opts
local defaults = {
  padding = { top = 0, left = 1 },
  bo = {
    bufhidden = "wipe",
    filetype = "trouble",
    buftype = "nofile",
  },
  wo = {
    winbar = "",
    winblend = 0,
  },
}

M.FOLDS = {
  wo = {
    foldcolumn = "0",
    foldenable = false,
    foldlevel = 99,
    foldmethod = "manual",
  },
}

---@type trouble.Window.opts
local minimal = {
  wo = {
    cursorcolumn = false,
    cursorline = true,
    cursorlineopt = "both",
    fillchars = "eob: ",
    list = false,
    number = false,
    relativenumber = false,
    signcolumn = "no",
    spell = false,
    winbar = "",
    statuscolumn = "",
    winfixheight = true,
    winfixwidth = true,
    winhighlight = "Normal:TroubleNormal,NormalNC:TroubleNormalNC,EndOfBuffer:TroubleNormal",
    wrap = false,
  },
}

--- A size <= 1 is a fraction of the parent size.
---@param size number
---@param parent number
local function scale(size, parent)
  return size <= 1 and math.floor(parent * size) or size
end

--- Fractions are relative to the free space, negative values count from the end.
---@param pos number
---@param parent number
---@param size number
local function place(pos, parent, size)
  local ret = math.abs(pos) <= 1 and math.floor((parent - size) * pos) or pos
  return ret < 0 and (parent + ret) or ret
end

---@param opts? trouble.Window.opts
function M.new(opts)
  local self = setmetatable({}, M)
  self.id = next_id()
  opts = opts or {}

  local is_minimal = opts.minimal
  if is_minimal == nil then
    is_minimal = opts.type ~= "main"
  end

  -- merged as a plain table, the fields below depend on the window type
  ---@type table
  local merged = vim.tbl_deep_extend("force", {}, defaults, is_minimal and minimal or {}, opts)
  merged.minimal = is_minimal
  merged.type = merged.type or "split"
  if merged.type == "split" then
    merged.relative = merged.relative or "editor"
    merged.position = merged.position or "bottom"
    merged.size = merged.size or (merged.position == "bottom" or merged.position == "top") and 10 or 30
    merged.win = merged.win or vim.api.nvim_get_current_win()
  elseif merged.type == "float" then
    merged.relative = merged.relative or "editor"
    merged.size = merged.size or { width = 0.8, height = 0.8 }
    merged.position = type(merged.position) == "table" and merged.position or { 0.5, 0.5 }
  elseif merged.type == "main" then
    merged.type = "float"
    merged.relative = "win"
    merged.position = { 0, 0 }
    merged.size = { width = 1, height = 1 }
    merged.wo.winhighlight = "Normal:Normal"
  end
  ---@cast merged trouble.Window.opts
  self.opts = merged
  return self
end

---@param clear? boolean
function M:augroup(clear)
  return vim.api.nvim_create_augroup("trouble.window." .. self.id, { clear = clear == true })
end

function M:parent_size()
  if self.opts.relative == "editor" or self.opts.relative == "cursor" then
    return { width = vim.o.columns, height = vim.o.lines }
  end
  local win = self.opts.win or 0
  local ret = {
    width = vim.api.nvim_win_get_width(win),
    height = vim.api.nvim_win_get_height(win),
  }
  -- account for winbar
  if vim.wo[win].winbar ~= "" then
    ret.height = ret.height - 1
  end
  return ret
end

---@param type "win" | "buf"
function M:set_options(type)
  local opts = type == "win" and self.opts.wo or self.opts.bo
  local target = type == "win" and { scope = "local", win = self.win } or { buf = self.buf }
  ---@diagnostic disable-next-line: no-unknown
  for k, v in pairs(opts or {}) do
    ---@diagnostic disable-next-line: no-unknown
    local ok, err = pcall(vim.api.nvim_set_option_value, k, v, target)
    if not ok then
      Util.error("Error setting option `" .. k .. "=" .. tostring(v) .. "`\n\n" .. err)
    end
  end
end

function M:mount()
  self.keys = {}
  self.buf = vim.api.nvim_create_buf(false, true)
  self:set_options("buf")
  if self.opts.type == "split" then
    ---@diagnostic disable-next-line: param-type-mismatch
    self:mount_split(self.opts)
  else
    ---@diagnostic disable-next-line: param-type-mismatch
    self:mount_float(self.opts)
  end

  self:set_options("win")

  self:on({ "BufWinLeave" }, vim.schedule_wrap(self.check_alien))

  self:on("WinClosed", function()
    if self.opts.on_close then
      self.opts.on_close(self)
    end
    self:augroup(true)
  end, { win = true })

  if self.opts.on_mount then
    self.opts.on_mount(self)
  end
end

function M:set_buf(buf)
  self.buf = buf
  if self.win and vim.api.nvim_win_is_valid(self.win) then
    vim.api.nvim_win_set_buf(self.win, buf)
  end
end

function M:check_alien()
  if not (self.win and vim.api.nvim_win_is_valid(self.win)) then
    return
  end
  local buf = vim.api.nvim_win_get_buf(self.win)
  if buf ~= self.buf then
    -- move the alien buffer to the main window
    local main = Main.get()
    vim.api.nvim_win_set_buf(main.win, buf)
    -- restore the trouble window
    self:close()
    self:open()
  end
end

function M:close()
  pcall(vim.api.nvim_win_close, self.win, true)
  self:augroup(true)
  self.win = nil
end

function M:open()
  if self:valid() then
    return self
  end
  self:close()
  self:mount()
  return self
end

function M:valid()
  return self.win
    and vim.api.nvim_win_is_valid(self.win)
    and self.buf
    and vim.api.nvim_buf_is_valid(self.buf)
    and vim.api.nvim_win_get_buf(self.win) == self.buf
end

---@param opts trouble.Window.split|trouble.Window.base
function M:mount_split(opts)
  if self.opts.win and not vim.api.nvim_win_is_valid(self.opts.win) then
    self.opts.win = 0
  end
  local parent_size = self:parent_size()
  local vertical = opts.position == "left" or opts.position == "right"
  local size = opts.size
  if type(size) == "table" then
    size = vertical and size.width or size.height
  end
  size = scale(size, parent_size[vertical and "width" or "height"])

  local cmd = split_commands[opts.relative][opts.position]
  Util.noautocmd(function()
    vim.api.nvim_win_call(opts.win, function()
      vim.cmd("silent noswapfile " .. cmd .. " " .. size .. "split")
      vim.api.nvim_win_set_buf(0, self.buf)
      self.win = vim.api.nvim_get_current_win()
    end)
  end)
end

---@param opts trouble.Window.float|trouble.Window.base
function M:mount_float(opts)
  local parent_size = self:parent_size()
  ---@type vim.api.keyset.win_config
  local config = {}
  for _, v in ipairs(float_options) do
    ---@diagnostic disable-next-line: no-unknown
    config[v] = opts[v]
  end
  config.focusable = opts.focusable ~= false
  config.height = scale(opts.size.height, parent_size.height)
  config.width = scale(opts.size.width, parent_size.width)
  config.border = opts.border or "none"
  config.row = place(opts.position[1], parent_size.height, config.height)
  config.col = place(opts.position[2], parent_size.width, config.width)
  if config.relative ~= "win" then
    config.win = nil
  end

  self.win = vim.api.nvim_open_win(self.buf, false, config)
end

function M:focus()
  if self:valid() then
    vim.api.nvim_set_current_win(self.win)
  end
end

---@param events string|string[]
---@param fn fun(self:trouble.Window, event:{buf:number}):boolean?
---@param opts? vim.api.keyset.create_autocmd | {buffer: false, win?:boolean}
function M:on(events, fn, opts)
  opts = vim.tbl_extend("force", {}, opts or {})
  if opts.win then
    opts.pattern = tostring(self.win)
    opts.win = nil
  elseif opts.buffer == nil then
    opts.buffer = self.buf
  elseif opts.buffer == false then
    opts.buffer = nil
  end
  -- pattern and buffer are mutually exclusive
  if opts.pattern then
    opts.buffer = nil
  end
  local _self = Util.weak(self)
  opts.callback = function(e)
    local this = _self()
    if not this then
      -- returning true deletes the autocmd
      return true
    end
    return fn(this, e)
  end
  opts.group = self:augroup()
  vim.api.nvim_create_autocmd(events, opts)
end

---@param key string
---@param fn fun(self: trouble.Window):any
---@param opts? string|vim.keymap.set.Opts|{mode?:string}
function M:map(key, fn, opts)
  if not self:valid() then
    error("Cannot create a keymap for an invalid window")
  end

  opts = vim.tbl_deep_extend("force", {
    buffer = self.buf,
    nowait = true,
    mode = "n",
  }, type(opts) == "string" and { desc = opts } or opts or {})
  local mode = opts.mode
  opts.mode = nil
  ---@cast opts vim.keymap.set.Opts

  self.keys[key] = opts.desc or key
  local weak_self = Util.weak(self)
  vim.keymap.set(mode, key, function()
    local this = weak_self()
    if this then
      return fn(this)
    end
  end, opts)
end

return M
