# cargo-registry-search.nvim

A small Neovim plugin for Rust projects. When a buffer belongs to a Cargo project, it lets you search only the crates that the project actually resolves in `cargo metadata`, instead of searching the whole local Cargo registry.

## Requirements

- Neovim with Lua support
- `cargo`
- `rg` / ripgrep
- Downloaded dependency sources in the local Cargo registry (`cargo fetch` if needed)

## Install

With lazy.nvim from this repository:

```lua
{
  'denisbog/cargo-registry-search',
  ft = { "rust", "toml" },
  config = function()
    require("cargo_registry_search").setup()
  end,
}
```

Or copy `nvim/cargo-registry-search` into any Neovim package/start path.

## Commands

Commands are buffer-local and are created only after opening `*.rs`, `Cargo.toml`, or `Cargo.lock` inside a Rust project.

- `:CargoRegistrySearch [filename-pattern]` — open a Snacks-style live file picker over dependency sources.
  - Filtering starts after 3 typed characters by default.
  - Example: `:CargoRegistrySearch world`
- `:CargoRegistryGrep [query] [--file <filename-pattern>]` — open a Snacks-style live grep picker over dependency sources, optionally constrained by filename.
  - Grep starts after 3 typed characters by default.
  - Example: `:CargoRegistryGrep WorldQuery --file *.rs`
  - You can also type `query --file *.rs` directly in the picker box.
  - Example: `:CargoRegistryGrep --file *.rs`, then type the query in the picker.
- `:CargoRegistryDeps` — open a Snacks-style live dependency picker for the resolved package directories being searched.
  - Filtering starts after 3 typed characters by default.
  - Pressing enter opens the selected crate directory.

Picker results use Snacks when available. If Snacks is disabled or unavailable, commands fall back to the quickfix list.

## Keymaps

Default buffer-local keymaps:

- `<leader>crf` — prompt for filename search
- `<leader>crg` — prompt for grep + optional filename filter
- `<leader>crd` — list searched dependencies

## Configuration

```lua
require("cargo_registry_search").setup({
  -- Defaults to $CARGO_HOME/registry/src or ~/.cargo/registry/src.
  registry_src = nil,

  -- true: direct + transitive resolved registry dependencies.
  -- false: only direct workspace registry dependencies.
  include_transitive = true,

  keymaps = true,
  keymap_prefix = "<leader>cr",
  quickfix_open_command = "copen",

  -- Use Snacks pickers when available, similar to `<leader>/`.
  use_snacks_picker = true,

  -- Start live file/grep searching only after this many typed chars.
  min_chars = 3,

  -- Extra args appended to `rg --files` for the quickfix fallback.
  rg_args = {},

  -- Extra args appended to `cargo metadata --format-version=1`.
  metadata_args = {},
})
```
