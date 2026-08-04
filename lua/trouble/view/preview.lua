local Render = require("trouble.view.render")
local Util = require("trouble.util")

---@alias trouble.Preview {item:trouble.Item, win:number, buf: number, close:fun()}

local M = {}
M.preview = nil ---@type trouble.Preview?
M._closing = false -- guard flag to prevent re-entrant/double close

function M.is_open()
  return M.preview ~= nil and M._closing == false
end

function M.is_win(win)
  return M.preview and M.preview.win == win
end

function M.item()
  return M.preview and M.preview.item
end

function M.close()
  if M._closing then
    return
  end

  local preview = M.preview
  if not preview then
    return
  end

  M._closing = true
  M.preview = nil

  -- Validate the preview window is still alive before resetting extmarks.
  -- The win number could have been recycled by Neovim after a previous close.
  local win_valid = preview.win and vim.api.nvim_win_is_valid(preview.win)
  if win_valid then
    -- Only reset marks on the buf that belongs to this preview window.
    local current_buf = vim.api.nvim_win_get_buf(preview.win)
    if current_buf == preview.buf then
      Render.reset(preview.buf)
    end
  end

  pcall(preview.close)

  M._closing = false
end

--- Create a preview buffer for an item.
--- If the item has a loaded buffer, use that,
--- otherwise create a new buffer.
---@param item trouble.Item
---@param opts? {scratch?:boolean}
function M.create(item, opts)
  opts = opts or {}

  local buf = item.buf or vim.fn.bufnr(item.filename)

  if item.filename and vim.fn.isdirectory(item.filename) == 1 then
    return
  end

  -- create a scratch preview buffer when needed
  if not (buf and vim.api.nvim_buf_is_loaded(buf)) then
    if opts.scratch then
      buf = vim.api.nvim_create_buf(false, true)
      vim.bo[buf].bufhidden = "wipe"
      vim.bo[buf].buftype = "nofile"
      local lines = Util.get_lines({ path = item.filename, buf = item.buf })
      if not lines then
        return
      end
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
      local ft = item:get_ft(buf)
      if ft then
        vim.bo[buf].filetype = ft
      end
    else
      item.buf = vim.fn.bufadd(item.filename)
      buf = item.buf

      if not vim.api.nvim_buf_is_loaded(item.buf) then
        vim.fn.bufload(item.buf)
      end
      if not vim.bo[item.buf].buflisted then
        vim.bo[item.buf].buflisted = true
      end
    end
  end

  return buf
end

---@param view trouble.View
---@param item trouble.Item
---@param opts? {scratch?:boolean}
function M.open(view, item, opts)
  if M.item() == item then
    return
  end

  -- Close existing preview only when the file actually changes.
  -- Previously this was done unconditionally, which caused flicker and
  -- left the preview_win in an inconsistent state when items in the same
  -- file were navigated quickly.
  if M.preview and M.preview.item.filename ~= item.filename then
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

    M.preview = pw
    M.preview.buf = buf
  end
  M.preview.item = item

  if not vim.api.nvim_win_is_valid(M.preview.win) then
    M.preview = nil
    return
  end

  Render.reset(M.preview.buf)

  -- make sure we highlight at least one character
  local end_pos = { item.end_pos[1], item.end_pos[2] }
  if end_pos[1] == item.pos[1] and end_pos[2] == item.pos[2] then
    end_pos[2] = end_pos[2] + 1
  end

  -- highlight the line
  Util.set_extmark(M.preview.buf, Render.ns, item.pos[1] - 1, 0, {
    end_row = end_pos[1],
    hl_group = "CursorLine",
    hl_eol = true,
    strict = false,
    priority = 150,
  })

  -- highlight the range
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

  -- no autocmds should be triggered. So LSP's etc won't try to attach in the preview
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
  if view.opts.preview.type == "main" then
    local main = view:main()
    if not main then
      Util.debug("No main window")
      return
    end
    view.preview_win.opts.win = main.win
  else
    view.preview_win.opts.win = view.win.win
  end

  view.preview_win:open()
  view.preview_win:set_buf(buf)

  Util.noautocmd(function()
    view.preview_win:set_options("win")
    vim.w[view.preview_win.win].trouble_preview = true
  end)

  -- Ensure treesitter / syntax is active on the buffer now that it has a
  -- real window.  For scratch buffers the parser was started before the
  -- window existed; for real buffers that were loaded without ever being
  -- displayed, FileType may not have fired yet.
  vim.schedule(function()
    if not vim.api.nvim_buf_is_valid(buf) then
      return
    end
    local win = view.preview_win.win
    if not (win and vim.api.nvim_win_is_valid(win)) then
      return
    end
    -- Only touch the buf that's actually in the preview window.
    if vim.api.nvim_win_get_buf(win) ~= buf then
      return
    end

    -- Try treesitter first; fall back to legacy syntax.
    local ft = vim.bo[buf].filetype
    if ft and ft ~= "" then
      local lang = vim.treesitter.language.get_lang(ft)
      -- pcall: parser may not be installed; that's fine.
      if not pcall(vim.treesitter.start, buf, lang) then
        if vim.bo[buf].syntax == "" then
          vim.bo[buf].syntax = ft
        end
      end
    end
  end)

  local captured_win = view.preview_win
  return {
    win = view.preview_win.win,
    close = function()
      if captured_win and captured_win.win and vim.api.nvim_win_is_valid(captured_win.win) then
        captured_win:close()
      end
    end,
  }
end

return M
