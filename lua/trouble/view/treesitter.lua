---@alias trouble.LangRegions table<string, number[][][]>

local M = {}

M.cache = {} ---@type table<number, table<string,{parser: vim.treesitter.LanguageTree, highlighter:vim.treesitter.highlighter, enabled:boolean}>>
local ns = vim.api.nvim_create_namespace("trouble.treesitter")

local TSHighlighter = vim.treesitter.highlighter

local missing = {} ---@type table<string, true>

local function wrap(name)
  return function(ns_id, win, buf, ...)
    local langs = M.cache[buf]
    if not langs then
      return false
    end
    for _, hl in pairs(langs) do
      if hl.enabled then
        TSHighlighter.active[buf] = hl.highlighter
        TSHighlighter[name](ns_id, win, buf, ...)
      end
    end
    TSHighlighter.active[buf] = nil
  end
end

M.did_setup = false
function M.setup()
  if M.did_setup then
    return
  end
  M.did_setup = true

  -- newer nvim uses `on_range` instead of `on_line`
  if TSHighlighter._on_range then
    vim.api.nvim_set_decoration_provider(ns, {
      on_win = wrap("_on_win"),
      on_range = wrap("_on_range"),
    })
  else
    vim.api.nvim_set_decoration_provider(ns, {
      on_win = wrap("_on_win"),
      on_line = wrap("_on_line"),
    })
  end

  vim.api.nvim_create_autocmd("BufWipeout", {
    group = vim.api.nvim_create_augroup("trouble.treesitter.hl", { clear = true }),
    callback = function(ev)
      M.cache[ev.buf] = nil
    end,
  })
end

---@param buf number
---@param regions trouble.LangRegions
function M.attach(buf, regions)
  -- nothing to highlight and nothing to disable
  if not M.cache[buf] and next(regions) == nil then
    return
  end

  M.setup()
  M.cache[buf] = M.cache[buf] or {}

  for _, hl in pairs(M.cache[buf]) do
    hl.enabled = false
  end

  for lang, lang_regions in pairs(regions) do
    M._attach_lang(buf, lang, lang_regions)
  end
end

---@param buf number
---@param lang string
---@param regions number[][][]
function M._attach_lang(buf, lang, regions)
  lang = lang == "markdown" and "markdown_inline" or lang
  if missing[lang] then
    return
  end

  local entry = M.cache[buf][lang]
  if not entry then
    local ok, parser = pcall(vim.treesitter.languagetree.new, buf, lang)
    if not ok then
      missing[lang] = true
      vim.notify_once(
        "nvim-treesitter parser missing `" .. lang .. "`",
        vim.log.levels.WARN,
        { title = "trouble.nvim" }
      )
      return
    end
    entry = { parser = parser, highlighter = TSHighlighter.new(parser) }
    -- only trouble's decoration provider should highlight this buffer
    TSHighlighter.active[buf] = nil
    M.cache[buf][lang] = entry
  end

  entry.enabled = true
  entry.parser:set_included_regions(vim.deepcopy(regions))
  -- parse everything, not only the visible part
  pcall(entry.parser.parse, entry.parser, true)
end

return M
