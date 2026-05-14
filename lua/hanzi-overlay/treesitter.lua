-- "Should we annotate this position?" lives here.
--
-- We don't want to overlay hanzi inside LaTeX math, command arguments, comments,
-- markdown code blocks, or URL destinations -- the result is either visually
-- broken (math) or semantically wrong (a \section title is a label, not prose).
--
-- Treesitter gives us a fast, accurate yes/no when its parsers are installed.
-- When they aren't, we fall back to a coarser regex sieve that handles the most
-- common cases (math delimiters, leading-`%` LaTeX comments, fenced markdown
-- code blocks). The fallback is intentionally simple -- if the user cares about
-- precision, they install the parsers.

local M = {}

----------------------------------------------------------------------
-- Per-filetype tables of node *types* whose interior we never annotate.
-- (Exact identifiers come from nvim-treesitter's latex and markdown grammars.)
----------------------------------------------------------------------

local SKIP_NODES = {
  tex = {
    -- math
    math_environment = true,
    inline_formula = true,
    displayed_equation = true,
    display_math = true,
    -- comments
    line_comment = true,
    -- verbatim
    verbatim_environment = true,
    -- labels / refs / citations / includes -- specific grammar nodes only.
    -- We deliberately do NOT skip generic curly_group / curly_group_text:
    -- that would suppress prose in \section{}, \textbf{}, \caption{}, etc.
    label_definition = true,
    label_reference = true,
    citation = true,
    include = true,
    package_include = true,
    class_include = true,
    latex_include = true,
    tex_include = true,
    graphics_include = true,
    import_include = true,
    verbatim_include = true,
    bib_include = true,
    biblatex_include = true,
  },
  -- LaTeX is also commonly identified as "latex" (nvim-treesitter)
  latex = nil, -- filled below
  markdown = {
    fenced_code_block = true,
    indented_code_block = true,
    code_span = true,
    code_fence_content = true,
    link_destination = true,
    image_description = false, -- text inside ![alt](url) -- keep annotating
    link_label = false,
    html_block = true,
    html_tag = true,
  },
  markdown_inline = {
    code_span = true,
    link_destination = true,
    inline_link = false,
    full_reference_link = false,
  },
}
SKIP_NODES.latex = SKIP_NODES.tex

-- Returns the filetype key we should use when looking up node sets. Treesitter
-- sometimes parses markdown's inline runs as a separate "markdown_inline"
-- subtree; we want the inline node table for those.
local function ft_for_tree(tree_lang, buffer_ft)
  if tree_lang == "markdown_inline" then return "markdown_inline" end
  if tree_lang == "latex" then return "tex" end
  return buffer_ft
end

----------------------------------------------------------------------
-- Public: should_skip_position
----------------------------------------------------------------------

-- Walk a node up to the root, returning true if any ancestor is in the
-- skip set for its language.
local function ancestor_in_set(node, set)
  while node do
    local t = node:type()
    if set[t] then return true end
    node = node:parent()
  end
  return false
end

-- (row, col) is 0-indexed, byte-based -- match what extmark APIs expect.
function M.should_skip_position(buf, ft, row, col)
  local set = SKIP_NODES[ft]
  if not set then return false end

  -- vim.treesitter.get_node returns the deepest node under the cursor across
  -- all language trees attached to the buffer. If there's no parser, this
  -- raises -- guard with pcall.
  local ok, node = pcall(vim.treesitter.get_node, {
    bufnr = buf, pos = { row, col }, ignore_injections = false,
  })
  if not ok or not node then return false end

  -- Inline-tree nodes (markdown_inline inside markdown) have their own set.
  local lang_ok, lang = pcall(function()
    local parser = vim.treesitter.get_parser(buf, ft)
    if not parser then return ft end
    -- Walk the tree we're actually in.
    local tree_root = node
    while tree_root:parent() do tree_root = tree_root:parent() end
    -- Find the language whose tree owns this root.
    local chosen = ft
    parser:for_each_tree(function(tstree, lt)
      if tstree:root() == tree_root then chosen = lt:lang() end
    end)
    return chosen
  end)
  local resolved = ft_for_tree(lang_ok and lang or ft, ft)
  local resolved_set = SKIP_NODES[resolved] or set

  return ancestor_in_set(node, resolved_set)
end

----------------------------------------------------------------------
-- Has-parser probe -- the autocmd uses this to decide whether to install a
-- treesitter highlighter dependency or just live with the regex fallback.
----------------------------------------------------------------------

function M.has_parser(ft)
  local lang = (ft == "tex") and "latex" or ft
  local ok, has = pcall(vim.treesitter.language.add, lang)
  -- Some versions return (true, nil) on success; treat any non-error as yes.
  return ok and has ~= false
end

----------------------------------------------------------------------
-- Regex fallback. Given a single line, return a sorted list of byte ranges
-- [start, end] (0-indexed, half-open like extmark cols) that we should NOT
-- annotate inside. The scanner consults this when treesitter is unavailable.
----------------------------------------------------------------------

-- Append a range, merging if it overlaps the previous one (keeps the list short).
local function push_range(ranges, s, e)
  if e <= s then return end
  local last = ranges[#ranges]
  if last and s <= last[2] then
    if e > last[2] then last[2] = e end
  else
    ranges[#ranges + 1] = { s, e }
  end
end

-- Build a set from config.latex_skip_commands on first use (and rebuild when
-- the user changes it). Cheap to recompute, but skipping the work matters when
-- this runs per line on a big buffer.
local skip_cmd_set, skip_cmd_src = nil, nil
local function get_skip_cmd_set()
  local ok, cfg = pcall(function() return require("hanzi-overlay.config").get() end)
  local list = ok and cfg and cfg.latex_skip_commands or {}
  if list == skip_cmd_src then return skip_cmd_set end
  local s = {}
  for _, c in ipairs(list) do s[c] = true end
  skip_cmd_set, skip_cmd_src = s, list
  return s
end

-- LaTeX: $...$, \(...\), \[...\], lines starting with `%`, and the args of a
-- *small list* of commands (labels, refs, cites, includes). Other commands'
-- arguments are real prose -- \section, \textbf, \emph, \caption, \footnote --
-- and stay annotatable.
local function tex_skip_ranges(line)
  local ranges = {}

  -- Whole-line comment.
  local pct = line:find("%%")
  if pct then
    -- TeX escape: \% is literal. Find first un-escaped %.
    local i = 1
    while i <= #line do
      local p = line:find("%%", i)
      if not p then break end
      if p == 1 or line:sub(p - 1, p - 1) ~= "\\" then
        push_range(ranges, p - 1, #line)
        break
      end
      i = p + 1
    end
  end

  -- $...$ inline math (single $; we don't try to handle $$...$$ on one line).
  do
    local i = 1
    while i <= #line do
      local s = line:find("%$", i)
      if not s then break end
      if s > 1 and line:sub(s - 1, s - 1) == "\\" then
        i = s + 1
      else
        local e = line:find("%$", s + 1)
        if not e then break end
        push_range(ranges, s - 1, e)
        i = e + 1
      end
    end
  end

  -- \[...\] and \(...\) on the same line.
  for pat in pairs({ ["\\%[.-\\%]"] = true, ["\\%(.-\\%)"] = true }) do
    local i = 1
    while i <= #line do
      local s, e = line:find(pat, i)
      if not s then break end
      push_range(ranges, s - 1, e)
      i = e + 1
    end
  end

  -- \cmd{...}: only skip the argument when cmd is in the configured set.
  -- The `*?` matches starred forms like \section*{...} (cmd capture is still
  -- the bare name). Nested braces are tracked by depth.
  do
    local skip_set = get_skip_cmd_set()
    local i = 1
    while i <= #line do
      local cs, ce, cmd = line:find("\\([%a@]+)%*?%s*{", i)
      if not cs then break end
      if skip_set[cmd] then
        local depth = 1
        local j = ce + 1
        while j <= #line and depth > 0 do
          local ch = line:sub(j, j)
          if ch == "{" then depth = depth + 1
          elseif ch == "}" then depth = depth - 1 end
          j = j + 1
        end
        push_range(ranges, ce, j - 2)
        i = j
      else
        i = ce + 1
      end
    end
  end

  table.sort(ranges, function(a, b) return a[1] < b[1] end)
  -- Re-merge after sort.
  local merged = {}
  for _, r in ipairs(ranges) do push_range(merged, r[1], r[2]) end
  return merged
end

-- Markdown: inline code `...`, $...$ if present, link URLs (url part of [text](url)).
local function markdown_skip_ranges(line)
  local ranges = {}

  -- Inline code spans -- handle 1+ backtick fences. We look for runs of `n`
  -- backticks, then the matching closing run.
  do
    local i = 1
    while i <= #line do
      local s, e = line:find("`+", i)
      if not s then break end
      local fence = line:sub(s, e)
      local close_s, close_e = line:find(fence, e + 1, true)
      if not close_s then break end
      push_range(ranges, s - 1, close_e)
      i = close_e + 1
    end
  end

  -- $...$ math (Pandoc / Obsidian style; if user doesn't use math this is a no-op).
  do
    local i = 1
    while i <= #line do
      local s = line:find("%$", i)
      if not s then break end
      local e = line:find("%$", s + 1)
      if not e then break end
      push_range(ranges, s - 1, e)
      i = e + 1
    end
  end

  -- [text](url): skip the (url) part, keep text.
  do
    local i = 1
    while i <= #line do
      local s, e = line:find("%]%b()", i)
      if not s then break end
      -- The `(` of the url match is at s+1, the `)` at e.
      push_range(ranges, s, e)
      i = e + 1
    end
  end

  table.sort(ranges, function(a, b) return a[1] < b[1] end)
  local merged = {}
  for _, r in ipairs(ranges) do push_range(merged, r[1], r[2]) end
  return merged
end

-- Return a list of skip ranges for a given line, given the filetype, when no
-- treesitter parser is available. Returns {} if filetype isn't recognised.
function M.regex_skip_ranges(ft, line)
  if ft == "tex" or ft == "latex" then return tex_skip_ranges(line) end
  if ft == "markdown" then return markdown_skip_ranges(line) end
  return {}
end

----------------------------------------------------------------------
-- Cross-line state tracker for the regex fallback. Some constructs span lines
-- (markdown fenced blocks, LaTeX math environments) so a per-line range list
-- isn't enough -- the caller maintains a ctx table and asks "is this whole
-- line currently inside a block I should skip?"
----------------------------------------------------------------------

-- Returns a fresh context. Callers iterate lines top-to-bottom and call
-- M.advance_block_ctx(ctx, ft, line) before consulting ctx.in_block.
function M.new_block_ctx()
  return { in_block = false, kind = nil, fence = nil }
end

local TEX_MATH_ENV_OPEN = {
  ["equation"] = true, ["equation*"] = true,
  ["align"] = true, ["align*"] = true,
  ["gather"] = true, ["gather*"] = true,
  ["multline"] = true, ["multline*"] = true,
  ["eqnarray"] = true, ["eqnarray*"] = true,
  ["displaymath"] = true,
}

-- Update ctx based on `line`. After this call, ctx.in_block tells you whether
-- the *content* of this line should be treated as inside a skip block.
-- (The opening/closing line itself is considered inside, which is fine -- you
-- weren't going to find prose on a fence line anyway.)
function M.advance_block_ctx(ctx, ft, line)
  if ft == "markdown" then
    if ctx.in_block and ctx.kind == "fence" then
      -- Look for a matching closing fence (same char run, possibly longer).
      local close = line:match("^%s*([`~]+)%s*$")
      if close and #close >= #ctx.fence and close:sub(1, 1) == ctx.fence:sub(1, 1) then
        -- Closing this line: this line is still "in", next line is out.
        ctx._close_after = true
      end
      return
    end
    local open = line:match("^%s*([`~][`~][`~]+)")
    if open then
      ctx.in_block = true; ctx.kind = "fence"; ctx.fence = open
    end
    return
  end

  if ft == "tex" or ft == "latex" then
    if ctx.in_block and ctx.kind == "math_env" then
      if line:find("\\end{" .. ctx.fence .. "}", 1, true) then
        ctx._close_after = true
      end
      return
    end
    if ctx.in_block and ctx.kind == "display_math" then
      if line:find("\\]", 1, true) then ctx._close_after = true end
      return
    end
    -- New openings (only honoured if not already inside another block).
    local env = line:match("\\begin{([^}]+)}")
    if env and TEX_MATH_ENV_OPEN[env] then
      ctx.in_block = true; ctx.kind = "math_env"; ctx.fence = env
      return
    end
    if line:find("\\%[") and not line:find("\\%]") then
      ctx.in_block = true; ctx.kind = "display_math"
      return
    end
  end
end

-- Call after processing the line content to flush "this line was the closing
-- one" -> "next line is no longer in the block".
function M.finish_block_line(ctx)
  if ctx._close_after then
    ctx.in_block = false; ctx.kind = nil; ctx.fence = nil; ctx._close_after = nil
  end
end

-- Convenience: does `col` fall inside any of the ranges?
function M.in_ranges(ranges, col)
  for _, r in ipairs(ranges) do
    if col >= r[1] and col < r[2] then return true end
    if r[1] > col then return false end
  end
  return false
end

return M
