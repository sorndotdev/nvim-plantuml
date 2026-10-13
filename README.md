# nvim-plantuml

Live PlantUML preview for Neovim. Edit a `.puml` file and watch the diagram
update in a split as you type.

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

Open any `*.puml`, `*.plantuml`, or `*.iuml` file. A preview split opens
automatically and re-renders as you edit.

| Command | Description |
| --- | --- |
| `:PlantUMLPreview [right\|left\|top\|bottom]` | Open the preview split |
| `:PlantUMLPreviewToggle` | Toggle the preview split |
| `:PlantUMLPreviewClose` | Close the preview split |
| `:PlantUMLStop` | Stop the render processes |
| `:PlantUMLInstall` | Download `plantuml.jar` into `stdpath('data')` |
| `:PlantUMLDebug` | Show resolved dependency paths |

Default keymap: `<leader>up` toggles the preview in PlantUML buffers.

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
    position = 'right',   -- right | left | top | bottom
    size = 0.4,           -- split size (fraction)
    auto_open = true,     -- open the preview when a PlantUML buffer is shown
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
