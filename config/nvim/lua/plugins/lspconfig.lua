-- lspconfig.lua
-- https://github.com/neovim/nvim-lspconfig

local function on_attach(_, bufnr)
  local opts = {
    buffer = bufnr,
    noremap = true,
    silent = true
  }

  vim.api.set('n', '<leader>a', function() vim.lsp.buf.code_action() end, opts)
  vim.api.set('v', '<leader>a', function() vim.lsp.buf.range_code_action() end, opts)
  vim.api.set('n', '<leader>k', function() vim.lsp.buf.hover() end, opts)
  vim.api.set('n', '<leader>K', function() vim.lsp.buf.signature_help() end, opts)
  vim.api.set('n', 'gd', function() vim.lsp.buf.definition() end, opts)
  vim.api.set('n', 'gi', function() vim.lsp.buf.implementation() end, opts)
  vim.api.set('n', 'gr', function() vim.lsp.buf.references() end, opts)
  vim.api.set('n', 'gt', function() vim.lsp.buf.type_definition() end, opts)
  vim.api.set('n', '<leader>r', function() vim.lsp.buf.rename() end, opts)
  vim.api.set('n', '<leader>fs', function() require('telescope.builtin').lsp_document_symbols() end, opts)
  vim.api.set('n', '<leader>fS', function() require('telescope.builtin').lsp_dynamic_workspace_symbols() end, opts)
  vim.api.set('n', '[d', function() vim.diagnostic.goto_prev() end, opts)
  vim.api.set('n', ']d', function() vim.diagnostic.goto_next() end, opts)
  vim.api.set('n', '<leader>e', function() vim.diagnostic.open_float() end, opts)
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
  'sumneko_lua',
  'pyright',
  'rust_analyzer',
  'tailwindcss',
  'tsserver',
  'vimls',
  'yamlls'
}

local shopify_servers = {
  'ruby_ls',
  'sorbet'
}

if os.getenv('SPIN') then
  for _, server in ipairs(shopify_servers) do
    table.insert(default_servers, server)
  end
end

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
    capabilities = cmp_nvim_lsp.update_capabilities(capabilities)
  }
end
