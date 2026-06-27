if vim.g.loaded_cargo_registry_search == 1 then
  return
end
vim.g.loaded_cargo_registry_search = 1

require("cargo_registry_search").setup(vim.g.cargo_registry_search_options or {})
