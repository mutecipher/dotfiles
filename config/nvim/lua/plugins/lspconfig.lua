-- lspconfig.lua
-- https://github.com/neovim/nvim-lspconfig

local function on_attach(_, bufnr)
  local opts = {
    buffer = bufnr,
    noremap = true,
    silent = true
  }

  vim.keymap.set('n', '<leader>a', function() vim.lsp.buf.code_action() end, opts)
  vim.keymap.set('v', '<leader>a', function() vim.lsp.buf.range_code_action() end, opts)
  vim.keymap.set('n', '<leader>k', function() vim.lsp.buf.hover() end, opts)
  vim.keymap.set('n', '<leader>K', function() vim.lsp.buf.signature_help() end, opts)
  vim.keymap.set('n', 'gd', function() vim.lsp.buf.definition() end, opts)
  vim.keymap.set('n', 'gi', function() vim.lsp.buf.implementation() end, opts)
  vim.keymap.set('n', 'gr', function() vim.lsp.buf.references() end, opts)
  vim.keymap.set('n', 'gt', function() vim.lsp.buf.type_definition() end, opts)
  vim.keymap.set('n', '<leader>r', function() vim.lsp.buf.rename() end, opts)
  vim.keymap.set('n', '<leader>fs', function() require('telescope.builtin').lsp_document_symbols() end, opts)
  vim.keymap.set('n', '<leader>fS', function() require('telescope.builtin').lsp_dynamic_workspace_symbols() end, opts)
  vim.keymap.set('n', '[d', function() vim.diagnostic.goto_prev() end, opts)
  vim.keymap.set('n', ']d', function() vim.diagnostic.goto_next() end, opts)
  vim.keymap.set('n', '<leader>e', function() vim.diagnostic.open_float() end, opts)
end

local capabilities = vim.lsp.protocol.make_client_capabilities()

local default_servers = {
  'astro',
  'bashls',
  'clangd',
  'cssls',
  'diagnosticls',
  'eslint',
  'gopls',
  'html',
  'jsonls',
  'lua_ls',
  'pyright',
  'rust_analyzer',
  'tailwindcss',
  'tsserver',
  'vimls',
  'yamlls'
}

local mason_lspconfig = require('mason-lspconfig')
require('mason').setup {}
mason_lspconfig.setup {
  ensure_installed = default_servers,
  automatic_install = true
}

local lspconfig = require('lspconfig')
local cmp_nvim_lsp = require('cmp_nvim_lsp')

for _, server in ipairs(mason_lspconfig.get_installed_servers()) do
  lspconfig[server].setup {
    on_attach = on_attach,
    capabilities = cmp_nvim_lsp.default_capabilities(capabilities)
  }
end

local is_mac = vim.fn.has('mac') == 1
if is_mac then
  lspconfig.sourcekit.setup {
    on_attach = on_attach,
    capabilities = cmp_nvim_lsp.default_capabilities(capabilities)
  }
end

lspconfig.standardrb.setup {
  on_attach = on_attach,
  capabilities = cmp_nvim_lsp.default_capabilities(capabilities)
}
