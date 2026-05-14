# hanzi-overlay.nvim

A Neovim plugin that overlays Mandarin hanzi as inline virtual text on top of
English/Danish words while you write. Companion to
[hanzi-gate.nvim](https://github.com/LauritsLL/hanzi-gate.nvim) — they share a vocabulary directory at
`~/.config/nvim/hanzi-immersion/`.

```
The temperature 温度 of the gas rises with kinetic energy 能量.
```

## Why

Passive immersion: while you write physics notes or Markdown, the words you
already know in Chinese show up beside their English/Danish forms. No flashcards,
no popup — just ambient exposure that compounds. The hanzi is rendered in a dim
foreground so it doesn't fight the prose; toggle to diacritic pinyin (`wēndù`)
when you want the reading instead.

## Installation

```lua
-- Lazy.nvim
{
  "LauritsLL/hanzi-overlay.nvim",
  ft = { "tex", "markdown" },
  opts = {
    filetypes = { "tex", "markdown" },
    density = "paragraph",
    default_mode = "hanzi",
  },
}
```

Treesitter parsers for `latex` and `markdown` are recommended (they give the
plugin a precise way to skip math, comments, code blocks, and link URLs).
Without them the plugin falls back to a regex sieve that handles the common
cases.

## Shared data directory

This plugin reads its vocabulary from `~/.config/nvim/hanzi-immersion/`, the
same directory used by `hanzi-gate.nvim`:

```
~/.config/nvim/hanzi-immersion/
├── words.txt        # hanzi | pinyin | english | danish  (used by hanzi-gate)
└── glosses.tsv      # hanzi <TAB> pinyin <TAB> english <TAB> danish
```

Only `glosses.tsv` is needed by hanzi-overlay. If it's missing on setup,
the plugin prints a warning and stays inert (no errors).

If you also use `hanzi-gate.nvim`, you don't need to maintain `glosses.tsv`
by hand: the gate auto-appends rows for words you successfully pass with, so
the overlay only starts annotating a word once you've demonstrated active
mastery. See the hanzi-gate README under "Integration with hanzi-overlay".

## glosses.tsv format

Tab-separated, four columns. Multiple glosses in one column separated by `;`.
Lines starting with `#` are comments; blank lines are skipped.

```
# hanzi    pinyin       english               danish
汉字       han4zi4      chinese character     kinesisk tegn
温度       wen1du4      temperature           temperatur
速度       su4du4       velocity;speed        hastighed
宇宙       yu3zhou4     universe;cosmos       univers
能量       neng2liang4  energy                energi
磁场       ci2chang3    magnetic field        magnetfelt
```

- Pinyin is stored numbered (`wen1du4`) and shown as diacritic form
  (`wēndù`) in pinyin mode. Standard apostrophe disambiguation is applied
  (e.g. `xi1an1` → `xī'ān`).
- Phrases (multi-word glosses like `magnetic field`) match as a single unit.
- Matching is case-insensitive (Danish letters æ/ø/å included).
- Longest gloss wins on overlap (`magnetic field` beats `field`).
- Infinitive aliasing: Danish glosses starting with `at <verb>` ("at synes")
  and English glosses starting with `to <verb>` ("to feel") also match the
  bare verb in your prose — so "Jeg synes" annotates without you having to
  also list "synes" separately in your TSV. The literal `at synes` still
  wins where it appears, thanks to longest-first matching.

## Configuration

| key                 | default                              | meaning                                                                          |
| ------------------- | ------------------------------------ | -------------------------------------------------------------------------------- |
| `filetypes`         | `{ "tex", "markdown" }`              | Filetypes the overlay activates on                                               |
| `density`           | `"paragraph"`                        | `"every"` / `"paragraph"` (first per gloss per paragraph) / `"buffer"` (once)    |
| `shared_data_dir`   | `"~/.config/nvim/hanzi-immersion"`   | Directory containing `glosses.tsv`                                               |
| `default_mode`      | `"hanzi"`                            | `"hanzi"` / `"pinyin"` / `"off"`                                                 |
| `highlight.fg`      | `"#e0af68"`                          | Fallback overlay fg, used when hanzi-gate isn't installed (no SRS data)          |
| `highlight.italic`  | `false`                              | Italicise the overlay text                                                       |
| `highlight.bold`    | `false`                              | Bold the overlay text                                                            |
| `highlight.srs.fresh`     | `"#fb923c"`                    | SRS "fresh" colour — `correct < srs_thresholds.improving` (see below)            |
| `highlight.srs.improving` | `"#e0af68"`                    | SRS "improving" colour — `improving ≤ correct < mastered`                        |
| `highlight.srs.mastered`  | `"#a8896b"`                    | SRS "mastered" colour — `correct ≥ srs_thresholds.mastered`                      |
| `srs_thresholds.improving` | `5`                            | `correct` count (in hanzi-gate's `state.json`) at which a word leaves "fresh"    |
| `srs_thresholds.mastered`  | `15`                           | `correct` count at which a word reaches "mastered"                               |
| `case_insensitive`  | `true`                               | Lower-case both sides before matching                                            |
| `max_overlays`      | `500`                                | Per-buffer hard cap                                                              |
| `debounce_ms`       | `300`                                | Refresh delay after the last edit                                                |
| `large_buffer_lines`| `10000`                              | Above this size, auto-refresh disables; use `:HanziOverlay refresh`              |
| `keymaps.toggle_mode`| `"<leader>zh"`                      | Cycle hanzi → pinyin → off                                                       |
| `keymaps.force_refresh`| `"<leader>zH"`                    | Force refresh current buffer                                                     |
| `keymaps.disable`   | `"<leader>z<leader>"`                | Disable for this buffer (session only)                                           |

## SRS-graded colouring

When `hanzi-gate.nvim` is installed, the overlay reads its `state.json` and
colour-grades each annotation by how often you've successfully used the word
in the gate:

| Bucket | Group | Default colour | Condition |
| --- | --- | --- | --- |
| Fresh | `HanziOverlaySrs1` | `#fb923c` vivid orange | `correct < srs_thresholds.improving` (default `5`) |
| Improving | `HanziOverlaySrs2` | `#e0af68` warm amber | between the two thresholds |
| Mastered | `HanziOverlaySrs3` | `#a8896b` muted amber | `correct ≥ srs_thresholds.mastered` (default `15`) |

Bright shades pull the eye to words you still need to learn; muted shades
fade words you've earned. Override the colours or thresholds via
`highlight.srs.*` and `srs_thresholds.*` in `setup()`.

If hanzi-gate isn't loadable (or you don't use it), every annotation falls
back to `highlight.fg` — a single colour, no gradient. The read is automatic
and doesn't require flipping `gate_integration.enabled`; that flag now only
controls the write-side bridge (overlay → `exposures.json`).

## Commands

| command                | effect                                              |
| ---------------------- | --------------------------------------------------- |
| `:HanziOverlay`        | Cycle mode (hanzi → pinyin → off)                   |
| `:HanziOverlay refresh`| Force refresh the current buffer                    |
| `:HanziOverlay disable`| Disable for the current buffer (this session)       |
| `:HanziOverlay enable` | Re-enable after disable                             |
| `:HanziOverlay stats`  | Show overlay count and word list for current buffer |

## Keybindings (defaults)

| key                   | action                  |
| --------------------- | ----------------------- |
| `<leader>zh`          | Cycle hanzi/pinyin/off  |
| `<leader>zH`          | Force refresh           |
| `<leader>z<leader>`   | Disable for the session |

## Lua API

```lua
require("hanzi-overlay").setup({ ... })
require("hanzi-overlay").toggle()    -- cycle mode for current buffer
require("hanzi-overlay").refresh()   -- force refresh current buffer
require("hanzi-overlay").disable()   -- per-buffer, session-only
require("hanzi-overlay").enable()
require("hanzi-overlay").stats()
```

## Performance notes

- A buffer-wide rescan runs at most once per `debounce_ms` (default 300 ms).
- Buffers larger than `large_buffer_lines` (default 10,000) skip the
  auto-refresh entirely — call `:HanziOverlay refresh` when you want to update.
- `max_overlays` (default 500) is a hard cap on extmarks per buffer. If you
  hit it, increase the cap or switch density to `"buffer"`.
- Match scanning is `O(lines × glosses)`. With a few hundred glosses this is
  unnoticeable on real documents; if you have thousands of glosses the
  paragraph/buffer density modes are the right knob.

## Treesitter

When the `latex` and `markdown` parsers are installed
(`:TSInstall latex markdown markdown_inline`), the overlay precisely skips:

- LaTeX: math environments, inline `$...$`, `\[...\]`, comments, command args.
- Markdown: fenced and inline code, link URLs (text is kept), inline math.

Without parsers, a regex fallback handles the obvious cases (`$...$`,
`\[...\]`, leading `%` comments, fenced ` ```...``` `, `[text](url)`).
