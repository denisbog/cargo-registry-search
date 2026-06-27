local M = {}

local config = {
  registry_src = nil,
  include_transitive = true,
  keymaps = true,
  keymap_prefix = "<leader>cr",
  quickfix_open_command = "copen",
  use_snacks_picker = true,
  min_chars = 3,
  rg_args = {},
  metadata_args = {},
}

local cache = {}
local uv = vim.uv or vim.loop

local function notify(message, level)
  vim.notify("cargo-registry-search: " .. message, level or vim.log.levels.INFO)
end

local function trim(value)
  return (value or ""):gsub("^%s+", ""):gsub("%s+$", "")
end

local function path_join(...)
  local joined = table.concat({ ... }, "/")
  return (joined:gsub("/+", "/"))
end

local function executable(name)
  return vim.fn.executable(name) == 1
end

local function run(cmd, cwd)
  if vim.system then
    local result = vim.system(cmd, { cwd = cwd, text = true }):wait()
    return result.code or 0, result.stdout or "", result.stderr or ""
  end

  local previous_cwd = vim.fn.getcwd()
  if cwd then
    vim.cmd.lcd(vim.fn.fnameescape(cwd))
  end
  local output = vim.fn.system(cmd)
  local code = vim.v.shell_error
  if cwd then
    vim.cmd.lcd(vim.fn.fnameescape(previous_cwd))
  end
  return code, output, ""
end

local function find_cargo_root(start)
  start = start or vim.api.nvim_buf_get_name(0)
  if start == "" then
    start = vim.fn.getcwd()
  end

  local dir = start
  if vim.fn.filereadable(start) == 1 then
    dir = vim.fs.dirname(start)
  end

  local cargo_toml = vim.fs.find("Cargo.toml", { path = dir, upward = true })[1]
  if cargo_toml then
    return vim.fs.dirname(cargo_toml)
  end
end

local function default_registry_src()
  local cargo_home = vim.env.CARGO_HOME or path_join(vim.env.HOME or "", ".cargo")
  return path_join(cargo_home, "registry", "src")
end

local function is_registry_package(package)
  return type(package.source) == "string" and package.source:match("^registry%+") ~= nil
end

local function package_sort(a, b)
  if a.name == b.name then
    return a.version < b.version
  end
  return a.name < b.name
end

local function metadata_for(root)
  local lock_stat = uv.fs_stat(path_join(root, "Cargo.lock"))
  local toml_stat = uv.fs_stat(path_join(root, "Cargo.toml"))
  local cache_key = root
    .. ":lock="
    .. tostring(lock_stat and lock_stat.mtime.sec or 0)
    .. ":toml="
    .. tostring(toml_stat and toml_stat.mtime.sec or 0)
  if cache[cache_key] then
    return cache[cache_key]
  end

  local cmd = { "cargo", "metadata", "--format-version=1" }
  vim.list_extend(cmd, config.metadata_args or {})

  local code, stdout, stderr = run(cmd, root)
  if code ~= 0 then
    return nil, trim(stderr ~= "" and stderr or stdout)
  end

  local ok, metadata = pcall(vim.json.decode, stdout)
  if not ok then
    return nil, "failed to decode cargo metadata JSON"
  end

  local workspace_members = {}
  for _, id in ipairs(metadata.workspace_members or {}) do
    workspace_members[id] = true
  end

  local packages_by_id = {}
  for _, package in ipairs(metadata.packages or {}) do
    packages_by_id[package.id] = package
  end

  local selected = {}
  if config.include_transitive then
    for _, package in ipairs(metadata.packages or {}) do
      if is_registry_package(package) and not workspace_members[package.id] then
        selected[package.id] = package
      end
    end
  else
    for _, node in ipairs((metadata.resolve and metadata.resolve.nodes) or {}) do
      if workspace_members[node.id] then
        for _, dep in ipairs(node.deps or {}) do
          local package = packages_by_id[dep.pkg]
          if package and is_registry_package(package) then
            selected[package.id] = package
          end
        end
      end
    end
  end

  local packages = {}
  for _, package in pairs(selected) do
    table.insert(packages, {
      id = package.id,
      name = package.name,
      version = package.version,
      source = package.source,
    })
  end
  table.sort(packages, package_sort)

  local result = { metadata = metadata, packages = packages }
  cache = { [cache_key] = result }
  return result
end

local function registry_package_paths(packages)
  local registry_src = config.registry_src or default_registry_src()
  local registries = {}

  if vim.fn.isdirectory(registry_src) ~= 1 then
    return {}, "registry source directory not found: " .. registry_src
  end

  for name, type_ in vim.fs.dir(registry_src) do
    if type_ == "directory" then
      table.insert(registries, path_join(registry_src, name))
    end
  end

  local paths = {}
  local missing = {}
  for _, package in ipairs(packages) do
    local dir_name = package.name .. "-" .. package.version
    local found = false
    for _, registry in ipairs(registries) do
      local candidate = path_join(registry, dir_name)
      if vim.fn.isdirectory(candidate) == 1 then
        table.insert(paths, {
          path = candidate,
          package = package,
        })
        found = true
        break
      end
    end
    if not found then
      table.insert(missing, dir_name)
    end
  end

  return paths, nil, missing
end

local function rust_context(opts)
  opts = opts or {}
  local bufnr = opts.bufnr or vim.api.nvim_get_current_buf()
  local root = vim.b[bufnr].cargo_registry_search_root or find_cargo_root(vim.api.nvim_buf_get_name(bufnr))
  if not root then
    return nil, "not inside a Rust project with Cargo.toml"
  end

  local metadata, err = metadata_for(root)
  if not metadata then
    return nil, err
  end

  local paths, path_err, missing = registry_package_paths(metadata.packages)
  if path_err then
    return nil, path_err
  end

  return {
    root = root,
    packages = metadata.packages,
    package_paths = paths,
    missing = missing or {},
  }
end

local function basename_matches(path, pattern)
  pattern = trim(pattern)
  if pattern == "" then
    return true
  end

  local base = vim.fs.basename(path)
  if pattern:find("[%*%?%[]") then
    return vim.fn.match(base, vim.fn.glob2regpat(pattern)) >= 0
  end

  return base:lower():find(pattern:lower(), 1, true) ~= nil
end

local function rg_files(paths)
  if not executable("rg") then
    return nil, "ripgrep (`rg`) is required for registry file search"
  end

  local files = {}
  local chunk_size = 80
  for index = 1, #paths, chunk_size do
    local cmd = { "rg", "--files", "--color", "never" }
    for _, extra in ipairs(config.rg_args or {}) do
      table.insert(cmd, extra)
    end
    for current = index, math.min(index + chunk_size - 1, #paths) do
      table.insert(cmd, paths[current].path)
    end

    local code, stdout, stderr = run(cmd)
    if code > 1 then
      return nil, trim(stderr ~= "" and stderr or stdout)
    end

    for line in stdout:gmatch("[^\n]+") do
      table.insert(files, line)
    end
  end

  return files
end

local function package_for_path(package_paths, file)
  for _, entry in ipairs(package_paths) do
    if vim.startswith(file, entry.path .. "/") then
      return entry.package.name .. " " .. entry.package.version
    end
  end
  return ""
end

local function set_quickfix(entries, title)
  vim.fn.setqflist({}, "r", { title = title, items = entries })
  if #entries > 0 then
    vim.cmd(config.quickfix_open_command)
  else
    notify("no matches")
  end
end

local function open_file_results(files, ctx, title)
  local entries = {}
  for _, file in ipairs(files) do
    table.insert(entries, {
      filename = file,
      lnum = 1,
      col = 1,
      text = package_for_path(ctx.package_paths, file),
    })
  end
  set_quickfix(entries, title)
end

local function package_dirs(ctx)
  return vim.tbl_map(function(entry)
    return entry.path
  end, ctx.package_paths)
end

local function snacks_picker()
  if not config.use_snacks_picker then
    return nil
  end

  local ok, picker = pcall(require, "snacks.picker")
  if ok then
    return picker
  end

  if _G.Snacks and _G.Snacks.picker then
    return _G.Snacks.picker
  end
end

local function has_min_chars(search)
  return #trim(search or "") >= (config.min_chars or 3)
end

local function filename_filter_to_glob(pattern)
  pattern = trim(pattern)
  if pattern == "" then
    return nil
  end
  if pattern:find("/") then
    return pattern
  end
  if pattern:find("[%*%?%[]") then
    return "**/" .. pattern
  end
  return "**/*" .. pattern .. "*"
end

local function files_min_chars_finder(opts, picker_ctx)
  local search = trim(picker_ctx.filter.search)
  if not has_min_chars(search) then
    return {}
  end

  if search:find("[%*%?%[]") then
    opts = vim.tbl_deep_extend("force", opts, {
      args = vim.list_extend(vim.deepcopy(opts.args or {}), { "--glob" }),
    })
  end

  return require("snacks.picker.source.files").files(opts, picker_ctx)
end

local parse_grep_args

local function grep_min_chars_finder(opts, picker_ctx)
  local query, file_pattern = parse_grep_args(picker_ctx.filter.search)
  if not has_min_chars(query) then
    return {}
  end

  local source = require("snacks.picker.source.grep")
  local original_search = picker_ctx.filter.search
  local live_opts = opts

  if file_pattern and file_pattern ~= "" then
    live_opts = vim.tbl_deep_extend("force", vim.deepcopy(opts), {
      glob = filename_filter_to_glob(file_pattern),
    })
  end

  picker_ctx.filter.search = query
  local ok, result = pcall(source.grep, live_opts, picker_ctx)
  picker_ctx.filter.search = original_search

  if not ok then
    error(result)
  end

  return result
end

local function dependency_matches(entry, search)
  search = trim(search):lower()
  if search == "" then
    return true
  end

  local package = entry.package
  local haystack = table.concat({
    package.name,
    package.version,
    package.name .. " " .. package.version,
    entry.path,
  }, "\n"):lower()

  return haystack:find(search, 1, true) ~= nil
end

local function deps_min_chars_finder(opts, picker_ctx)
  local search = picker_ctx.filter.search
  if not has_min_chars(search) then
    return {}
  end

  local items = {}
  for _, entry in ipairs(opts.dependencies or {}) do
    if dependency_matches(entry, search) then
      local package = entry.package
      table.insert(items, {
        text = package.name .. " " .. package.version .. "  " .. entry.path,
        file = entry.path,
        dir = true,
        package = package,
        preview = {
          ft = "markdown",
          text = table.concat({
            "# " .. package.name .. " " .. package.version,
            "",
            "```text",
            entry.path,
            "```",
            "",
            "Source: " .. (package.source or "registry"),
          }, "\n"),
        },
      })
    end
  end
  return items
end

local function open_files_picker(pattern, ctx)
  local picker = snacks_picker()
  if not picker then
    return false
  end

  picker({
    source = "cargo_registry_files",
    title = "Cargo registry files (type 3+ chars)",
    finder = files_min_chars_finder,
    format = "file",
    preview = "file",
    live = true,
    supports_live = true,
    show_empty = true,
    search = pattern ~= "" and pattern or nil,
    dirs = package_dirs(ctx),
    cmd = "fd",
    hidden = true,
    ignored = true,
  })

  return true
end

local function open_grep_picker(query, file_pattern, ctx)
  local picker = snacks_picker()
  if not picker then
    return false
  end

  picker({
    source = "cargo_registry_grep",
    title = file_pattern and ("Cargo registry grep: " .. file_pattern) or "Cargo registry grep (type 3+ chars)",
    finder = grep_min_chars_finder,
    format = "file",
    preview = "file",
    live = true,
    supports_live = true,
    show_empty = true,
    search = query ~= "" and query or nil,
    dirs = package_dirs(ctx),
    glob = filename_filter_to_glob(file_pattern or ""),
    regex = true,
  })

  return true
end

local function open_deps_picker(ctx)
  local picker = snacks_picker()
  if not picker then
    return false
  end

  picker({
    source = "cargo_registry_deps",
    title = "Cargo registry dependencies (type 3+ chars)",
    finder = deps_min_chars_finder,
    format = "text",
    preview = "preview",
    live = true,
    supports_live = true,
    show_empty = true,
    dependencies = ctx.package_paths,
  })

  return true
end

function M.deps(opts)
  opts = opts or {}
  local ctx, err = rust_context(opts)
  if not ctx then
    notify(err, vim.log.levels.ERROR)
    return {}
  end

  if open_deps_picker(ctx) then
    return ctx.packages
  end

  local entries = {}
  for _, entry in ipairs(ctx.package_paths) do
    table.insert(entries, {
      filename = entry.path,
      lnum = 1,
      col = 1,
      text = entry.package.name .. " " .. entry.package.version,
    })
  end

  set_quickfix(entries, "Cargo registry dependencies")
  return ctx.packages
end

function M.files(pattern, opts)
  opts = opts or {}
  pattern = trim(pattern)

  local ctx, err = rust_context(opts)
  if not ctx then
    notify(err, vim.log.levels.ERROR)
    return {}
  end

  if open_files_picker(pattern, ctx) then
    return {}
  end

  local all_files, rg_err = rg_files(ctx.package_paths)
  if not all_files then
    notify(rg_err, vim.log.levels.ERROR)
    return {}
  end

  local matches = {}
  for _, file in ipairs(all_files) do
    if basename_matches(file, pattern) then
      table.insert(matches, file)
    end
  end

  table.sort(matches)
  open_file_results(matches, ctx, "Cargo registry files: " .. (pattern ~= "" and pattern or "*"))
  return matches
end

parse_grep_args = function(args)
  args = trim(args)
  local query, file_pattern = args:match("^(.-)%s*%-%-file%s+(.+)$")
  if query then
    return trim(query), trim(file_pattern)
  end
  return args, nil
end

local function rg_grep(targets, query)
  if not executable("rg") then
    return nil, "ripgrep (`rg`) is required for registry grep"
  end

  local matches = {}
  local chunk_size = 80
  for index = 1, #targets, chunk_size do
    local cmd = { "rg", "--vimgrep", "--color", "never", "--no-heading", "--", query }
    for current = index, math.min(index + chunk_size - 1, #targets) do
      table.insert(cmd, targets[current])
    end

    local code, stdout, stderr = run(cmd)
    if code > 1 then
      return nil, trim(stderr ~= "" and stderr or stdout)
    end

    for line in stdout:gmatch("[^\n]+") do
      local file, lnum, col, text = line:match("^(.+):(%d+):(%d+):(.*)$")
      if file then
        table.insert(matches, {
          filename = file,
          lnum = tonumber(lnum),
          col = tonumber(col),
          text = text,
        })
      end
    end
  end

  return matches
end

function M.grep(args, opts)
  opts = opts or {}
  local query, file_pattern = parse_grep_args(args or "")

  local ctx, err = rust_context(opts)
  if not ctx then
    notify(err, vim.log.levels.ERROR)
    return {}
  end

  if open_grep_picker(query, file_pattern, ctx) then
    return {}
  end

  if query == "" then
    notify("usage: :CargoRegistryGrep <query> [--file <filename-pattern>]", vim.log.levels.ERROR)
    return {}
  end

  local targets = {}
  if file_pattern and file_pattern ~= "" then
    local all_files, rg_err = rg_files(ctx.package_paths)
    if not all_files then
      notify(rg_err, vim.log.levels.ERROR)
      return {}
    end
    for _, file in ipairs(all_files) do
      if basename_matches(file, file_pattern) then
        table.insert(targets, file)
      end
    end
  else
    for _, entry in ipairs(ctx.package_paths) do
      table.insert(targets, entry.path)
    end
  end

  if #targets == 0 then
    notify("no files matched filename filter")
    return {}
  end

  local entries, rg_err = rg_grep(targets, query)
  if not entries then
    notify(rg_err, vim.log.levels.ERROR)
    return {}
  end

  set_quickfix(entries, "Cargo registry grep: " .. query)
  return entries
end

local function prompt_files(bufnr)
  M.files("", { bufnr = bufnr })
end

local function prompt_grep(bufnr)
  M.grep("", { bufnr = bufnr })
end

function M.attach(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  if vim.b[bufnr].cargo_registry_search_attached then
    return
  end

  local root = find_cargo_root(vim.api.nvim_buf_get_name(bufnr))
  if not root then
    return
  end

  vim.b[bufnr].cargo_registry_search_root = root
  vim.b[bufnr].cargo_registry_search_attached = true

  vim.api.nvim_buf_create_user_command(bufnr, "CargoRegistrySearch", function(command)
    M.files(command.args, { bufnr = bufnr })
  end, {
    nargs = "?",
    desc = "Search dependency source files in the local Cargo registry by filename",
  })

  vim.api.nvim_buf_create_user_command(bufnr, "CargoRegistryGrep", function(command)
    M.grep(command.args, { bufnr = bufnr })
  end, {
    nargs = "*",
    desc = "Live grep dependency source in the local Cargo registry; add --file <pattern> to filter filenames",
  })

  vim.api.nvim_buf_create_user_command(bufnr, "CargoRegistryDeps", function()
    M.deps({ bufnr = bufnr })
  end, {
    nargs = 0,
    desc = "List resolved Cargo registry dependency directories",
  })

  if config.keymaps then
    local prefix = config.keymap_prefix
    vim.keymap.set("n", prefix .. "f", function()
      prompt_files(bufnr)
    end, { buffer = bufnr, desc = "Cargo registry files" })
    vim.keymap.set("n", prefix .. "g", function()
      prompt_grep(bufnr)
    end, { buffer = bufnr, desc = "Cargo registry grep" })
    vim.keymap.set("n", prefix .. "d", function()
      M.deps({ bufnr = bufnr })
    end, { buffer = bufnr, desc = "Cargo registry deps" })
  end
end

function M.setup(opts)
  config = vim.tbl_deep_extend("force", config, opts or {})

  local group = vim.api.nvim_create_augroup("CargoRegistrySearch", { clear = true })
  vim.api.nvim_create_autocmd({ "BufReadPost", "BufNewFile" }, {
    group = group,
    pattern = { "*.rs", "Cargo.toml", "Cargo.lock" },
    callback = function(event)
      M.attach(event.buf)
    end,
  })

  M.attach(0)
end

return M
