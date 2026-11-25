local Filter = require("trouble.filter")
local Format = require("trouble.format")
local Main = require("trouble.view.main")
local Preview = require("trouble.view.preview")
local Promise = require("trouble.promise")
local Render = require("trouble.view.render")
local Section = require("trouble.view.section")
local Spec = require("trouble.spec")
local Text = require("trouble.view.text")
local Util = require("trouble.util")
local Window = require("trouble.view.window")

---@class trouble.View
---@field win trouble.Window
---@field preview_win? trouble.Window
---@field opts trouble.Mode
---@field sections trouble.Section[]
---@field renderer trouble.Render
---@field first_render trouble.Promise
---@field first_update trouble.Promise
---@field moving uv.uv_timer_t
---@field clicked uv.uv_timer_t
---@field state table<string,any>
---@field _filters table<string, trouble.ViewFilter>
---@field private _main? trouble.Main
---@field _frozen boolean
local M = {}
M.__index = M
local _idx = 0
---@type table<trouble.View, number>
M._views = setmetatable({}, { __mode = "k" })

---@type trouble.View[]
M._auto = {}

---@type table<string, trouble.Render.Location>
M._last = {}

---@class trouble.View.Snapshot
---@field opts trouble.Mode
---@field cursor number[]
---@field loc? trouble.Render.Location
---@field filters table<string, trouble.ViewFilter>
---@field sections_data {items: trouble.Item[], node?: trouble.Node}[]

--- Last closed view per mode, per main window id, and `""` for any mode.
---@type table<string|number, trouble.View.Snapshot>
M._history = {}

M.MOVING_DELAY = 4000

local uv = vim.uv or vim.loop

---@param t table<string, any>
---@return string[]
local function sorted_ids(t)
  local ids = vim.tbl_keys(t)
  table.sort(ids)
  return ids
end

---@param filters table<string, trouble.ViewFilter>
---@return trouble.Filter[]?
local function active_filters(filters)
  local ids = sorted_ids(filters)
  if #ids == 0 then
    return
  end
  return vim.tbl_map(function(id)
    return filters[id].filter
  end, ids)
end

---@param opts trouble.Mode
function M.new(opts)
  local self = setmetatable({}, M)
  _idx = _idx + 1
  M._views[self] = _idx
  self.state = {}
  self.opts = opts or {}
  self._filters = {}
  self.moving = assert(uv.new_timer())
  self.clicked = assert(uv.new_timer())
  self.first_render = Promise.new(function() end)
  self.first_update = Promise.new(function() end)
  self.opts.win = vim.tbl_deep_extend("force", self.opts.win or {}, Window.FOLDS)
  self.opts.win.on_mount = function()
    self:on_mount()
  end
  self.opts.win.on_close = function()
    Preview.close()
    if not self.opts.auto_open then
      for _, section in ipairs(self.sections) do
        section:stop()
      end
    end
  end

  self.sections = {}
  for _, s in ipairs(Spec.sections(self.opts)) do
    local section = Section.new(s, self.opts)
    section.on_update = function()
      self:update()
    end
    table.insert(self.sections, section)
  end

  self.win = Window.new(self.opts.win)
  self.opts.win = self.win.opts

  self.preview_win = Window.new(self.opts.preview)

  self.renderer = Render.new(self.opts, {
    padding = vim.tbl_get(self.opts.win, "padding", "left") or 0,
    multiline = self.opts.multiline,
  })
  self.update = Util.throttle(M.update, Util.throttle_opts(self.opts.throttle.update, { ms = 10 }))
  self.render = Util.throttle(M.render, Util.throttle_opts(self.opts.throttle.render, { ms = 10 }))
  self.follow = Util.throttle(M.follow, Util.throttle_opts(self.opts.throttle.follow, { ms = 100 }))

  if self.opts.auto_open then
    -- keep a reference so the view isn't gc'ed
    table.insert(M._auto, self)
    self:listen()
    self:refresh()
  end
  return self
end

---@alias trouble.View.filter {debug?: boolean, open?:boolean, mode?: string}

---@param filter? trouble.View.filter
function M.get(filter)
  filter = filter or {}
  ---@type {idx:number, mode?: string, view: trouble.View, is_open: boolean}[]
  local ret = {}
  for view, idx in pairs(M._views) do
    local is_open = view.win:valid()
    local opening = view.first_update:is_pending()
    local ok = is_open or view.opts.auto_open or opening
    ok = ok and (not filter.mode or filter.mode == view.opts.mode)
    ok = ok and (not filter.open or is_open or opening)
    if ok then
      ret[#ret + 1] = {
        idx = idx,
        mode = view.opts.mode,
        view = not filter.debug and view or {},
        is_open = is_open,
      }
    end
  end
  table.sort(ret, function(a, b)
    return a.idx < b.idx
  end)
  return ret
end

function M:on_mount()
  vim.w[self.win.win].trouble = {
    mode = self.opts.mode,
    type = self.opts.win.type,
    relative = self.opts.win.relative,
    position = self.opts.win.position,
  }

  self:listen()

  local _self = Util.weak(self)

  local preview = Util.throttle(
    M._auto_preview,
    Util.throttle_opts(self.opts.throttle.preview, {
      ms = 100,
      debounce = true,
    })
  )

  self.win:on("WinLeave", function()
    if not _self() then
      return true
    end
    vim.schedule(function()
      local this = _self()
      -- already closed, `on_close` handled the preview
      if not this or not this.win:valid() then
        return
      end
      if this.opts.preview.type == "main" and this.clicked:is_active() and Preview.is_open() then
        local main = this.preview_win.opts.win
        local pwin = this.preview_win.win
        if main and pwin and vim.api.nvim_win_is_valid(main) and vim.api.nvim_win_is_valid(pwin) then
          local view = vim.api.nvim_win_call(pwin, vim.fn.winsaveview)
          vim.api.nvim_win_call(main, function()
            vim.fn.winrestview(view)
          end)
          vim.api.nvim_set_current_win(main)
        end
      end
      Preview.close()
    end)
  end)

  self.win:on("CursorMoved", function()
    local this = _self()
    if not this then
      return true
    end
    local loc = this:at()
    if loc.node then
      M._last[this.opts.mode or ""] = loc
    end
    if this.opts.auto_preview and loc.item then
      preview(this)
    end
  end)

  if self.opts.follow then
    self.win:on("CursorMoved", function()
      local this = _self()
      if not this then
        return true
      end
      this:follow()
    end, { buffer = false })
  end

  self.win:on("OptionSet", function()
    local this = _self()
    if not this then
      return true
    end
    if this.win:valid() then
      local foldlevel = vim.wo[this.win.win].foldlevel
      if foldlevel ~= this.renderer.foldlevel then
        this:fold_level({ level = foldlevel })
      end
    end
  end, { pattern = "foldlevel", buffer = false })

  -- A float preview is positioned relative to the trouble window,
  -- so reopen it when the trouble window is resized.
  self.win:on("WinResized", function()
    local this = _self()
    if not this then
      return true
    end
    if this.opts.preview.type == "main" or this.preview_win.opts.type ~= "float" then
      return
    end
    if not (this.win:valid() and Preview.is_open()) then
      return
    end
    if not vim.tbl_contains(vim.v.event.windows or {}, this.win.win) then
      return
    end
    if this:at().item then
      Preview.close()
      preview(this)
    end
  end, { buffer = false })

  for k, v in pairs(self.opts.keys) do
    if v ~= false then
      self:map(k, v)
    end
  end

  self.win:map("<leftmouse>", function()
    self.clicked:start(100, 0, function() end)
    return "<leftmouse>"
  end, { remap = false, expr = true })
end

---@param node? trouble.Node
function M:delete(node)
  local selection = node and { node } or self:selection()
  if #selection == 0 then
    return
  end
  for _, n in ipairs(selection) do
    n:delete()
  end
  self.opts.auto_refresh = false
  self:render()
end

---@param node? trouble.Node
---@param opts? trouble.Render.fold_opts
function M:fold(node, opts)
  node = node or self:at().node
  if node then
    self.renderer:fold(node, opts)
    self:render()
  end
end

---@param opts {level?:number, add?:number}
function M:fold_level(opts)
  self.renderer:fold_level(opts)
  self:render()
end

---@param item? trouble.Item
---@param opts? {split?: boolean, vsplit?:boolean, aboveleft?:boolean}
function M:jump(item, opts)
  opts = opts or {}
  item = item or self:at().item

  Preview.close()

  if not item then
    return Util.warn("No item to jump to")
  end

  if not (item.buf or item.filename) then
    return Util.warn("No buffer or filename for item")
  end

  item.buf = item.buf or vim.fn.bufadd(item.filename)

  if not vim.bo[item.buf].buflisted then
    vim.bo[item.buf].buflisted = true
  end

  local main = self:main()
  local win = main and main.win or vim.api.nvim_get_current_win()

  -- save position in jump list
  vim.api.nvim_win_call(win, function()
    vim.cmd("normal! m'")
  end)

  local split_cmd
  if opts.split then
    split_cmd = (opts.aboveleft and "aboveleft " or "") .. "split"
  elseif opts.vsplit then
    split_cmd = "vsplit"
  end

  if split_cmd then
    vim.api.nvim_win_call(win, function()
      vim.cmd(split_cmd)
      win = vim.api.nvim_get_current_win()
    end)
  end

  vim.api.nvim_win_set_buf(win, item.buf)
  vim.api.nvim_set_current_win(win)
  -- the buffer may have changed since the item was created
  pcall(vim.api.nvim_win_set_cursor, win, item.pos)

  vim.schedule(function()
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_call(win, function()
        vim.cmd("norm! zzzv")
      end)
    end
  end)
  return item
end

function M:wait(fn)
  self.first_render:next(fn)
end

---@param item? trouble.Item
function M:preview(item)
  item = item or self:at().item
  if not item then
    return Util.warn("No item to preview")
  end

  return Preview.open(self, item, { scratch = self.opts.preview.scratch })
end

-- Runs from a debounced timer, so the view may be closed by now.
-- The item is read again for the same reason.
function M:_auto_preview()
  if not self.win:valid() then
    return
  end
  local item = self:at().item
  if item then
    Preview.open(self, item, { scratch = self.opts.preview.scratch })
  end
end

function M:main()
  self._main = Main.get(self.opts.pinned and self._main or nil)
  return self._main
end

function M:goto_main()
  local main = self:main()
  if main then
    vim.api.nvim_set_current_win(main.win)
  end
end

function M:listen()
  self:main()

  for _, section in ipairs(self.sections) do
    section:listen()
  end
end

---@param cursor? number[]
function M:at(cursor)
  if not self.win:valid() then
    return {}
  end
  cursor = cursor or vim.api.nvim_win_get_cursor(self.win.win)
  return self.renderer:at(cursor[1])
end

function M:selection()
  -- "v", "V" or CTRL-V
  if not vim.fn.mode():lower():find("[v\22]") then
    local node = self:at().node
    return node and { node } or {}
  end
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<esc>", true, false, true), "x", false)

  local from = vim.api.nvim_buf_get_mark(self.win.buf, "<")[1]
  local to = vim.api.nvim_buf_get_mark(self.win.buf, ">")[1]
  ---@type trouble.Node[]
  local ret = {}
  local seen = {}
  for row = from, to do
    local node = self.renderer:at(row).node
    if node and not seen[node] then
      seen[node] = true
      ret[#ret + 1] = node
    end
  end
  return ret
end

---@param key string
---@param action trouble.Action.spec
function M:map(key, action)
  action = Spec.action(action)
  local _self = Util.weak(self)
  self.win:map(key, function()
    local this = _self()
    if this then
      this:action(action)
    end
  end, { desc = action.desc, mode = action.mode })
end

---@param opts? {idx?: number, up?:number, down?:number, jump?:boolean}
function M:move(opts)
  -- restarting the timer acts as a debounce, `follow` is skipped meanwhile
  self.moving:start(M.MOVING_DELAY, 0, function() end)

  opts = opts or {}
  local cursor = vim.api.nvim_win_get_cursor(self.win.win)
  local last = vim.api.nvim_buf_line_count(self.win.buf)
  local from, to, step = 1, last, 1
  local todo = opts.idx or opts.up or opts.down or 0

  if todo == 0 then
    return
  end

  if opts.idx and opts.idx < 0 then
    from, to, step = last, 1, -1
    todo = -todo
  elseif opts.down then
    from = cursor[1] + 1
  elseif opts.up then
    from, to, step = cursor[1] - 1, 1, -1
  end

  for row = from, to, step do
    local info = self.renderer:at(row)
    if info.item and info.first_line then
      todo = todo - 1
      if todo == 0 then
        vim.api.nvim_win_set_cursor(self.win.win, { row, cursor[2] })
        if opts.jump then
          self:jump(info.item)
        end
        break
      end
    end
  end
end

---@param action trouble.Action.spec
---@param opts? table
function M:action(action, opts)
  action = Spec.action(action)
  self:wait(function()
    local at = self:at()
    action.action(self, {
      item = at.item,
      node = at.node,
      opts = type(opts) == "table" and opts or {},
    })
  end)
end

---@param opts? {update?: boolean, opening?: boolean}
function M:refresh(opts)
  opts = opts or {}
  if not (opts.opening or self.win:valid() or self.opts.auto_open) then
    return
  end
  return Promise.all(vim.tbl_map(function(section)
    if self._frozen then
      -- resumed view, reuse the stored items
      return Promise.new(function(resolve)
        if opts.update ~= false then
          section:update()
        end
        resolve(section)
      end)
    end
    return section:refresh(opts)
  end, self.sections))
end

function M:help()
  local text = Text.new({ padding = 1 })

  text:nl():append("# Help ", "Title"):nl()
  text:append("Press ", "Comment"):append("<q>", "Special"):append(" to close", "Comment"):nl():nl()
  text:append("# Keymaps ", "Title"):nl():nl()
  ---@type string[]
  local keys = vim.tbl_keys(self.win.keys)
  table.sort(keys, function(a, b)
    local lowa, lowb = a:lower(), b:lower()
    if lowa == lowb then
      return a > b
    end
    return lowa < lowb
  end)
  for _, key in ipairs(keys) do
    text:append("  - ", "@punctuation.special.markdown")
    text:append(key, "Special"):append(" "):append(self.win.keys[key]):nl()
  end
  text:trim()

  local win = Window.new({
    type = "float",
    size = { width = text:width(), height = text:height() },
    border = "rounded",
    wo = { cursorline = false },
  })
  win:open():focus()
  text:render(win.buf)

  win:map("<esc>", win.close)
  win:map("q", win.close)
end

function M:is_open()
  return self.win:valid()
end

function M:open()
  self:close()

  self
    :refresh({ update = false, opening = true })
    :next(function()
      local count = self:count()
      if count == 0 then
        if not self.opts.open_no_results then
          if self.opts.warn_no_results then
            local main = self:main()
            local bufname = main and main.buf and vim.api.nvim_buf_get_name(main.buf) or ""
            Util.warn({
              "No results for **" .. tostring(self.opts.mode) .. "**",
              "Buffer: " .. bufname,
            })
          end
          return
        end
      elseif count == 1 and self.opts.auto_jump then
        if self.opts.open_mode and self.opts.open_mode ~= "default" then
          vim.cmd(self.opts.open_mode)
        end
        self:jump(self:flatten()[1])
        return self:close()
      end
      self.win:open()
      self:update()
    end)
    :next(self.first_update.resolve)
  return self
end

function M:_save_history()
  local sections_data = {}
  for i, section in ipairs(self.sections) do
    sections_data[i] = { items = section.items, node = section.node }
  end

  local snapshot = {
    opts = vim.deepcopy(self.opts),
    cursor = vim.api.nvim_win_get_cursor(self.win.win),
    loc = self:at(),
    filters = vim.deepcopy(self._filters),
    sections_data = sections_data,
  }

  -- drop entries of windows that no longer exist
  for key in pairs(M._history) do
    if type(key) == "number" and not vim.api.nvim_win_is_valid(key) then
      M._history[key] = nil
    end
  end

  M._history[self.opts.mode or ""] = snapshot
  M._history[""] = snapshot
  M._history[self:main().win] = snapshot
end

function M:close()
  -- nothing to resume when the window was never shown or is empty
  if self.win:valid() and self:count() > 0 then
    self:_save_history()
  end

  Preview.close()

  if vim.api.nvim_get_current_win() == self.win.win then
    self:goto_main()
  end

  self.win:close()
  return self
end

--- Reopen the last closed view, or the last one of `opts.mode`.
--- The stored items are reused, sources are not queried again.
--- `opts` are only the values to override on top of the stored ones.
---@param opts? {mode?: string}
function M.resume(opts)
  opts = opts or {}

  local snap
  if opts.mode then
    snap = M._history[opts.mode]
  else
    snap = M._history[vim.api.nvim_get_current_win()] or M._history[""]
  end

  if not snap then
    Util.warn("No previous Trouble session to resume" .. (opts.mode and (" for mode: " .. opts.mode) or ""))
    return
  end

  ---@type trouble.Mode
  local restored = vim.tbl_deep_extend("force", vim.deepcopy(snap.opts), opts)

  if restored.mode then
    local existing = M.get({ mode = restored.mode, open = true })[1]
    if existing and existing.view.win:valid() then
      existing.view.win:focus()
      return existing.view
    end
  end

  -- keep sources from overwriting the stored items until the first render
  local auto_refresh = restored.auto_refresh
  restored.auto_refresh = false
  restored.auto_jump = false
  restored.auto_open = false

  local view = M.new(restored)

  view._filters = vim.deepcopy(snap.filters)
  local filters = active_filters(view._filters)

  for i, section in ipairs(view.sections) do
    local data = snap.sections_data and snap.sections_data[i]
    if data then
      section.items = data.items or {}
      section.node = data.node
    end
    section.filter = filters
  end

  -- `render` restores the cursor from `M._last`
  local by_loc = restored.restore and snap.loc and snap.loc.node
  if by_loc then
    M._last[restored.mode or ""] = snap.loc
  end

  view._frozen = true
  view:open()
  view:wait(function()
    if view.win:valid() then
      if not by_loc then
        local row = math.min(snap.cursor[1], vim.api.nvim_buf_line_count(view.win.buf))
        pcall(vim.api.nvim_win_set_cursor, view.win.win, { row, snap.cursor[2] })
      end
      view.win:focus()
    end
    view.opts.auto_refresh = auto_refresh
    view._frozen = false
  end)

  return view
end

function M:count()
  local count = 0
  for _, section in ipairs(self.sections) do
    if section.node then
      count = count + section.node:count()
    end
  end
  return count
end

function M:flatten()
  local ret = {}
  for _, section in ipairs(self.sections) do
    if section.node then
      section.node:flatten(ret)
    end
  end
  return ret
end

-- called when results are updated
function M:update()
  local is_open = self.win:valid()
  local count = self:count()

  if count == 0 and is_open and self.opts.auto_close then
    return self:close()
  end

  if self.opts.auto_open and not is_open and count > 0 then
    self.win:open()
    is_open = true
  end

  if not is_open then
    return
  end

  self:render()
end

---@param filter trouble.Filter
---@param opts? trouble.ViewFilter.opts
function M:filter(filter, opts)
  opts = opts or {}

  ---@type trouble.ViewFilter
  local view_filter = vim.tbl_deep_extend("force", {
    id = vim.inspect(filter),
    filter = filter,
    data = opts.data,
    template = opts.template,
  }, opts)

  if opts.del or (opts.toggle and self._filters[view_filter.id]) then
    self._filters[view_filter.id] = nil
  else
    self._filters[view_filter.id] = view_filter
  end

  local filters = active_filters(self._filters)
  for _, section in ipairs(self.sections) do
    section.filter = filters
  end
  self:refresh()
end

function M:header()
  local ret = {} ---@type trouble.Format[][]
  for _, id in ipairs(sorted_ids(self._filters)) do
    local filter = self._filters[id]
    local data = vim.tbl_deep_extend("force", {
      filter = filter.filter,
    }, type(filter.filter) == "table" and filter.filter or {}, filter.data or {})
    local template = filter.template or "{hl:Title}Filter:{hl} {filter}"
    ret[#ret + 1] = self:format(template, data)
  end
  return ret
end

---@param id string
function M:get_filter(id)
  return self._filters[id]
end

---@param template string
---@param data table<string,any>
function M:format(template, data)
  data.source = "view"
  return Format.format(template, { item = data, opts = self.opts })
end

-- render the results
function M:render()
  if not self.win:valid() then
    return
  end

  local loc = self:at()
  local restore_loc = self.opts.restore and self.first_render:is_pending() and M._last[self.opts.mode or ""]
  if restore_loc then
    loc = restore_loc
  end

  self.renderer:clear()
  self.renderer:nl()
  for _ = 1, vim.tbl_get(self.opts.win, "padding", "top") or 0 do
    self.renderer:nl()
  end

  for _, h in ipairs(self:header()) do
    for _, ff in ipairs(h) do
      self.renderer:append(ff.text, ff)
    end
    self.renderer:nl()
  end

  self.renderer:sections(self.sections)
  self.renderer:trim()

  -- initial folds, render again to apply them
  if self.renderer.foldlevel == nil then
    local level = vim.wo[self.win.win].foldlevel
    if level < self.renderer.max_depth then
      self.renderer:fold_level({ level = level })
      return M.render(self)
    end
  end

  if self.first_render:is_pending() then
    vim.schedule(function()
      self.first_render.resolve()
    end)
  end

  -- render extmarks and restore window view
  local view = vim.api.nvim_win_call(self.win.win, vim.fn.winsaveview)
  self.renderer:render(self.win.buf)
  vim.api.nvim_win_call(self.win.win, function()
    vim.fn.winrestview(view)
  end)

  if self.opts.follow and self:follow() then
    return
  end

  -- when window is at top, dont move cursor
  if not restore_loc and view.topline == 1 then
    return
  end

  -- cursor is already on the right item
  local new_loc = self:at()
  if new_loc.node and loc.node and new_loc.node.id == loc.node.id then
    return
  end

  if not loc.node then
    return
  end

  -- move cursor to the previous item
  local cursor = vim.api.nvim_win_get_cursor(self.win.win)
  local locations = self.renderer._locations
  for row = 1, self.renderer:height() do
    local l = locations[row]
    if l and loc.node:is(l.node) then
      if row ~= cursor[1] then
        vim.api.nvim_win_set_cursor(self.win.win, { row, cursor[2] })
      end
      return
    end
  end
end

-- when not in the trouble window, try to show the range
function M:follow()
  if not self.win:valid() then
    return
  end
  if self.moving:is_active() then
    return
  end
  if vim.api.nvim_get_current_win() == self.win.win then
    return
  end

  local ctx = { opts = self.opts, main = self:main() }
  local fname = vim.api.nvim_buf_get_name(ctx.main.buf or 0)
  local loc = self:at()

  -- only fall back to the group when the cursor is not in it yet
  local in_group = loc.node and loc.node.item and loc.node.item.filename == fname

  ---@type number[]|nil
  local cursor_item, cursor_group
  local locations = self.renderer._locations

  for row = 1, self.renderer:height() do
    local l = locations[row]
    if l then
      if not in_group and l.node and l.node.group and l.node.item and l.node.item.filename == fname then
        cursor_group = { row, 1 }
      end
      -- prefer a full match
      if l.item and Filter.is(l.item, { range = true }, ctx) then
        cursor_item = { row, 1 }
      end
    end
  end

  local cursor = cursor_item or cursor_group
  if cursor then
    vim.wo[self.win.win].cursorline = true
    vim.api.nvim_win_set_cursor(self.win.win, cursor)
    return true
  end
end

return M
