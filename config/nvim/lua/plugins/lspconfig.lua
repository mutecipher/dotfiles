-- lspconfig.lua
-- https://github.com/neovim/nvim-lspconfig

local servers = {
    "bashls",
    "clangd",
    "diagnosticls",
    "gopls",
    "jsonls",
    "sumneko_lua",
    "pyright",
    "rust_analyzer",
    "sorbet"
}

require('mason').setup()
require('mason-lspconfig').setup({
  ensure_installed = servers,
  automatic_install = true
})

local lspconfig = require('lspconfig')
local cmp_nvim_lsp = require('cmp_nvim_lsp')
local function on_attach(_, bufnr)
  local opts = {
    buffer = bufnr,
    noremap = true,
    silent = true
  }

  vim.keymap.set('n', '<c-K>', '<cmd>lua vim.lsp.buf.signature_help()<CR>', opts)
  vim.keymap.set('n', '<leader>D', '<cmd>lua vim.lsp.buf.type_definition()<CR>', opts)
  vim.keymap.set('n', '<leader>ca', '<cmd>lua vim.lsp.buf.code_action<CR>', opts)
  vim.keymap.set('n', '<leader>e', '<cmd>lua vim.diagnostic.open_float()<CR>', opts)
  vim.keymap.set('n', '<leader>q', '<cmd>lua vim.diagnostic.setqflist()<CR>', opts)
  vim.keymap.set('n', '<leader>rn', '<cmd>lua vim.lsp.buf.rename()<CR>', opts)
  vim.keymap.set('n', '<leader>so', [[<cmd>lua require('telescope.builtin').lsp_document_symbols()<CR>]], opts)
  vim.keymap.set('n', 'K', '<Cmd>lua vim.lsp.buf.hover()<CR>', opts)
  vim.keymap.set('n', '[d', '<cmd>lua vim.diagnostic.goto_prev()<CR>', opts)
  vim.keymap.set('n', ']d', '<cmd>lua vim.diagnostic.goto_next()<CR>', opts)
  vim.keymap.set('n', 'gd', '<Cmd>lua vim.lsp.buf.definition()<CR>', opts)
  vim.keymap.set('n', 'gi', '<cmd>lua vim.lsp.buf.implementation()<CR>', opts)
  vim.keymap.set('n', 'gr', '<cmd>lua vim.lsp.buf.references()<CR>', opts)
  vim.keymap.set('v', '<leader>ca', '<cmd>lua vim.lsp.buf.range_code_action()<CR>', opts)
end

local opts = {
  on_attach = on_attach,
  capabilities = cmp_nvim_lsp.update_capabilities(vim.lsp.protocol.make_client_capabilities())
}

for _, server in ipairs(servers) do
  lspconfig[server].setup(opts)
end

if os.getenv('SHOPIFY_OWNED_DEVICE') then
  local configs = require('lspconfig.configs')

  if not configs.ruby_lsp then
    configs.ruby_lsp = {
      default_config = {
        cmd = { '/Users/mutecipher/.local/share/nvim/mason/packages/ruby-lsp/bin/ruby-lsp' },
        filetypes = {'ruby'},
        root_dir = lspconfig.util.root_pattern('.git', 'Gemfile'),
        settings = {}
      }
    }
  end

  lspconfig.sorbet.setup(opts)
  lspconfig.ruby_lsp.setup(opts)
end
