local Filter = require("trouble.filter")
local Main = require("trouble.view.main")
local Preview = require("trouble.view.preview")
local Promise = require("trouble.promise")
local Sort = require("trouble.sort")
local Sources = require("trouble.sources")
local Tree = require("trouble.tree")
local Util = require("trouble.util")

---@class trouble.Section
---@field section trouble.Section.opts
---@field finder trouble.Source.get
---@field private _main? trouble.Main
---@field opts trouble.Config
---@field items trouble.Item[]
---@field node? trouble.Node
---@field fetching boolean
---@field filter? trouble.Filter
---@field id number
---@field on_update? fun(self: trouble.Section)
---@field _refresh fun()
local M = {}
M.__index = M
M._id = 0

---@param section trouble.Section.opts
---@param opts trouble.Config
function M.new(section, opts)
  local self = setmetatable({}, M)
  self.section = section
  self.opts = opts
  M._id = M._id + 1
  self.id = M._id
  self.finder = Sources.get(section.source)
  self.items = {}
  self:main()

  local _self = Util.weak(self)

  self._refresh = Util.throttle(
    M.refresh,
    Util.throttle_opts(opts.throttle.refresh, {
      ms = 20,
      is_running = function()
        local this = _self()
        return this and this.fetching
      end,
    })
  )

  return self
end

---@param opts? {update?: boolean}
function M:refresh(opts)
  self.fetching = true
  return Promise.new(function(resolve)
    local called = self:main_call(function(main)
      local ctx = { opts = self.opts, main = main }
      self.finder(function(items)
        items = Filter.filter(items, self.section.filter, ctx)
        if self.filter then
          items = Filter.filter(items, self.filter, ctx)
        end
        items = Sort.sort(items, self.section.sort, ctx)
        self.items = items
        self.node = Tree.build(items, self.section)
        if not (opts and opts.update == false) then
          self:update()
        end
        resolve(self)
      end, ctx)
    end)
    -- no usable main window: resolve now instead of waiting for the timeout
    if not called then
      resolve(self)
    end
  end)
    :catch(Util.error)
    :timeout(2000)
    :catch(function() end)
    :finally(function()
      self.fetching = false
    end)
end

--- Runs `fn` in the main window.
---@param fn fun(main: trouble.Main)
---@return boolean called
function M:main_call(fn)
  local main = self:main()

  if not main or Preview.is_win(main.win) or not vim.api.nvim_win_is_valid(main.win) then
    return false
  end

  if vim.api.nvim_win_get_buf(main.win) ~= main.buf then
    Util.debug({
      "Main window switched buffers",
      "Main: " .. vim.fn.bufname(main.buf),
      "Current: " .. vim.fn.bufname(vim.api.nvim_win_get_buf(main.win)),
    })
    return false
  end

  if vim.api.nvim_get_current_win() == main.win then
    fn(main)
  else
    vim.api.nvim_win_call(main.win, function()
      fn(main)
    end)
  end
  return true
end

function M:update()
  if self.on_update then
    self:on_update()
  end
end

function M:main()
  self._main = Main.get(self.opts.pinned and self._main or nil)
  return self._main
end

function M:augroup()
  return "trouble.section." .. self.section.source .. "." .. self.id
end

function M:stop()
  pcall(vim.api.nvim_del_augroup_by_name, self:augroup())
end

function M:listen()
  local _self = Util.weak(self)

  local group = vim.api.nvim_create_augroup(self:augroup(), { clear = true })
  for _, event in ipairs(self.section.events or {}) do
    vim.api.nvim_create_autocmd(event.event, {
      group = group,
      pattern = event.pattern,
      callback = function(e)
        local this = _self()
        if not this then
          return true
        end
        if not this.opts.auto_refresh then
          return
        end
        if not vim.api.nvim_buf_is_valid(e.buf) then
          return
        end
        if e.event == "BufEnter" and vim.bo[e.buf].buftype ~= "" then
          return
        end
        if event.main then
          local main = this:main()
          if main and main.buf ~= e.buf then
            return
          end
        end
        this:_refresh()
      end,
    })
  end
end

return M
