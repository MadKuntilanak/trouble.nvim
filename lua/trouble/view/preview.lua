local Render = require("trouble.view.render")
local Util = require("trouble.util")

---@alias trouble.Preview {item:trouble.Item, win:number, buf: number, close:fun()}

local M = {}
M.preview = nil ---@type trouble.Preview?

function M.is_open()
  return M.preview ~= nil
end

---@param win number
function M.is_win(win)
  return M.preview ~= nil and M.preview.win == win
end

function M.item()
  return M.preview and M.preview.item
end

function M.close()
  local preview = M.preview
  if preview then
    -- cleared first, so re-entrant calls return early
    M.preview = nil
    if preview.buf then
      Render.reset(preview.buf)
    end
    pcall(preview.close)
  end
  M.sweep()
end

--- Closes preview windows that lost their state.
function M.sweep()
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if vim.w[win].trouble_preview then
      pcall(vim.api.nvim_win_close, win, true)
    end
  end
end

--- Returns the buffer to preview the item in.
---@param item trouble.Item
---@param opts? {scratch?:boolean}
function M.create(item, opts)
  opts = opts or {}

  local filename = item.filename
  if filename and vim.fn.isdirectory(filename) == 1 then
    return
  end

  local buf = item.buf or (filename and vim.fn.bufnr(filename)) or nil
  if buf and buf > 0 and vim.api.nvim_buf_is_loaded(buf) then
    return buf
  end

  if opts.scratch then
    local lines = Util.get_lines({ path = filename, buf = item.buf })
    if not lines then
      return
    end
    buf = vim.api.nvim_create_buf(false, true)
    vim.bo[buf].bufhidden = "wipe"
    vim.bo[buf].buftype = "nofile"
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    local ft = item:get_ft(buf)
    if ft then
      vim.bo[buf].filetype = ft
    end
    return buf
  end

  if not filename then
    return
  end

  buf = vim.fn.bufadd(filename)
  item.buf = buf
  if not vim.api.nvim_buf_is_loaded(buf) then
    vim.fn.bufload(buf)
  end
  if not vim.bo[buf].buflisted then
    vim.bo[buf].buflisted = true
  end
  return buf
end

---@param a trouble.Item
---@param b trouble.Item
local function same_file(a, b)
  if a.filename and b.filename then
    return a.filename == b.filename
  end
  return a.buf == b.buf
end

---@param view trouble.View
---@param item trouble.Item
---@param opts? {scratch?:boolean}
function M.open(view, item, opts)
  if M.item() == item or not view.win:valid() then
    return
  end

  -- keep the window when only the position in the same file changes
  if M.preview and not same_file(M.preview.item, item) then
    M.close()
  end

  if not M.preview then
    local buf = M.create(item, opts)
    if not buf then
      return
    end

    local pw = M.preview_win(buf, view)
    if not pw then
      return
    end

    pw.buf = buf
    M.preview = pw
  end
  M.preview.item = item

  if not vim.api.nvim_win_is_valid(M.preview.win) then
    return M.close()
  end

  Render.reset(M.preview.buf)

  -- highlight at least one character
  local end_pos = { item.end_pos[1], item.end_pos[2] }
  if end_pos[1] == item.pos[1] and end_pos[2] == item.pos[2] then
    end_pos[2] = end_pos[2] + 1
  end

  -- line
  Util.set_extmark(M.preview.buf, Render.ns, item.pos[1] - 1, 0, {
    end_row = end_pos[1],
    hl_group = "CursorLine",
    hl_eol = true,
    strict = false,
    priority = 150,
  })

  -- range
  Util.set_extmark(M.preview.buf, Render.ns, item.pos[1] - 1, item.pos[2], {
    end_row = end_pos[1] - 1,
    end_col = end_pos[2],
    hl_group = "TroublePreview",
    strict = false,
    priority = 160,
  })

  local _, source = require("trouble.sources").get(item.source)
  if source and source.preview then
    source.preview(item, M.preview)
  end

  -- no autocmds, so LSP etc. don't attach to the preview
  Util.noautocmd(function()
    if pcall(vim.api.nvim_win_set_cursor, M.preview.win, item.pos) then
      vim.api.nvim_win_call(M.preview.win, function()
        vim.cmd("norm! zzzv")
      end)
    end
  end)

  return item
end

---@param buf number
---@param view trouble.View
function M.preview_win(buf, view)
  local pwin = view.preview_win
  if not pwin then
    return
  end

  if view.opts.preview.type == "main" then
    local main = view:main()
    if not main then
      Util.debug("No main window")
      return
    end
    pwin.opts.win = main.win
  else
    pwin.opts.win = view.win.win
  end

  pwin:open()
  local win = assert(pwin.win)
  -- flagged right away, so `sweep` finds it if anything below fails
  vim.w[win].trouble_preview = true

  local ok, err = pcall(function()
    pwin:set_buf(buf)
    Util.noautocmd(function()
      pwin:set_options("win")
    end)
  end)
  if not ok then
    pwin:close()
    Util.error(tostring(err))
    return
  end

  -- FileType may not have fired for buffers that were never displayed
  vim.schedule(function()
    if not vim.api.nvim_buf_is_valid(buf) then
      return
    end
    if not (pwin.win and vim.api.nvim_win_is_valid(pwin.win) and vim.api.nvim_win_get_buf(pwin.win) == buf) then
      return
    end
    if vim.treesitter.highlighter.active[buf] then
      return
    end
    local ft = vim.bo[buf].filetype
    if ft == "" then
      return
    end
    -- no parser: fall back to regex syntax
    if not pcall(vim.treesitter.start, buf, vim.treesitter.language.get_lang(ft)) and vim.bo[buf].syntax == "" then
      vim.bo[buf].syntax = ft
    end
  end)

  return {
    win = win,
    close = function()
      pwin:close()
    end,
  }
end

return M
