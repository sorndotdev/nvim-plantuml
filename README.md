# nvim-plantuml

Live PlantUML preview for Neovim. In normal mode the window shows the diagram;
in insert mode it shows the code. Leave insert mode and the diagram comes back,
re-rendered with your changes. A side-by-side split is available too.

Rendering is driven by a persistent `plantuml -pipe` process and the PNG is
shown with [snacks.nvim](https://github.com/folke/snacks.nvim) image support.

The PlantUML jar is **not committed to this repo**. It is downloaded on demand
into `stdpath('data')/plantuml/` (see `:PlantUMLInstall`), verified by SHA-256,
and run through a Java runtime. You can also point the plugin at your own jar,
drop one in `vendor/`, or use an external `plantuml` executable.

## Requirements

- Neovim >= 0.10 (`vim.uv`, `vim.system`)
- A Java runtime (JRE/JDK)
- [snacks.nvim](https://github.com/folke/snacks.nvim) with `image` enabled
- Optional: ImageMagick (`magick`) for scale-to-fit
- Optional: GraphViz (`dot`) for some diagram types

Run `:checkhealth plantuml` to verify your setup.

## Installation

### lazy.nvim

```lua
{
    'sorndotdev/nvim-plantuml',
    dependencies = { 'folke/snacks.nvim' },
    ft = 'plantuml',
    opts = {},
}
```

### vim.pack / native packages

```lua
vim.pack.add({ 'https://github.com/sorndotdev/nvim-plantuml' })
```

### Vim packages

Drop the repo into a `start` package directory, e.g.
`~/.local/share/nvim/site/pack/plugins/start/nvim-plantuml`.

Configuration is optional; call `require('plantuml').setup({ ... })` to
override the defaults. Initialization is automatic.

## Usage

Open any `*.puml`, `*.plantuml`, or `*.iuml` file. Once the first render is
done, the window switches from the code to the diagram. If the buffer has no
`@start`/`@end` block yet, or the first render fails, you keep seeing the code.

On the diagram (normal mode):

| Key | Action |
| --- | --- |
| `i` `a` `I` `A` `o` `O` `s` `S` `C` | Show the code and run that key, so you are in insert mode at the cursor where you left off |
| `u` / `<C-r>` | Undo / redo in the code |
| `:w` | Write the source file |
| `<leader>up` | Show the code in normal mode (to move around, search, use `dd` etc.) |

Leaving insert mode (`<Esc>`) shows the diagram again. After `<leader>up`, the
code stays until you next leave insert mode or press `<leader>up` again.

Set `layout = 'split'` to get the old behaviour: the diagram in a split next to
the code, re-rendering as you type.

| Command | Description |
| --- | --- |
| `:PlantUMLPreview [right\|left\|top\|bottom]` | Show the diagram (with a position: open it in a split) |
| `:PlantUMLPreviewToggle` | Switch between code and diagram (split layout: open/close the split) |
| `:PlantUMLPreviewClose` | Show the code (split layout: close the split) |
| `:PlantUMLStop` | Stop the render processes |
| `:PlantUMLInstall` | Download `plantuml.jar` into `stdpath('data')` |
| `:PlantUMLDebug` | Show resolved dependency paths |

Default keymap: `<leader>up` runs `:PlantUMLPreviewToggle` in PlantUML buffers.

## Configuration

```lua
require('plantuml').setup({
    enabled = true,
    bin = nil,            -- external `plantuml` executable (nil = use a jar / $PATH)
    jar = nil,            -- plantuml.jar path (nil = vendor/ or downloaded copy)
    jar_url = 'https://github.com/plantuml/plantuml/releases/download/v1.2026.8/plantuml-1.2026.8.jar',
    jar_sha256 = '5e1ecfa8...', -- expected checksum; false to skip verification
    auto_install = true,  -- download the jar on first use when missing
    java = 'java',        -- Java runtime (name on $PATH or a full path)
    graphviz = nil,       -- GraphViz `dot` (name on $PATH or a full path)
    args = { '-pipe', '-tpng', '-nometadata' },
    layout = 'inline',    -- inline: diagram in normal mode, code in insert mode
                          -- split: diagram in a split next to the code
    position = 'right',   -- split layout: right | left | top | bottom
    size = 0.4,           -- split layout: split size (fraction)
    auto_open = true,     -- show the diagram when a PlantUML buffer is opened
    debounce = 300,       -- idle ms before re-render
    batch_size = 10,      -- coalesce this many edits into one render
    batch_ttl = 2000,     -- max ms to wait before flushing a batch
    keymaps = true,       -- set <leader>up in PlantUML buffers
    stop_when_closed = true,
    fill = true,          -- scale the image to fill the pane
    max_scale = 4,
})
```

## How the jar is resolved

In order:

1. `jar` if set and readable
2. `vendor/plantuml.jar` (drop one here for offline use; it is git-ignored)
3. `stdpath('data')/plantuml/plantuml.jar` (installed by `:PlantUMLInstall`)

If no jar is found, `auto_install` downloads it on first use. If no jar and no
local copy exist, an external `plantuml` on `$PATH` is used.

## License

MIT for the plugin code (see `LICENSE`). The PlantUML jar, when downloaded, is
distributed by the PlantUML project under GPL-3.0.
