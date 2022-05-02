-- lspconfig.lua
-- https://github.com/neovim/nvim-lspconfig

require('nvim-lsp-installer').setup({
  ensure_installed = {
    'bashls',
    'dockerls',
    'eslint',
    'gopls',
    'pyright',
    'rust_analyzer',
    'arduino_language_server',
    'clangd',
    'cmake',
    'cssls',
    'diagnosticls',
    'dotls',
    'emmet_ls',
    'graphql',
    'html',
    'jsonls',
    'stylelint_lsp',
    'sumneko_lua',
    'tsserver'
  },
  automatic_install = true
})

local lspconfig = require('lspconfig')
local cmp_nvim_lsp = require('cmp_nvim_lsp')
local capabilities = cmp_nvim_lsp.update_capabilities(vim.lsp.protocol.make_client_capabilities())
local function on_attach(_, bufnr)
  local opts = {
    buffer = bufnr,
    noremap = true,
    silent = true
  }

  vim.keymap.set('n', '<c-K>', '<cmd>lua vim.lsp.buf.signature_help()<CR>', opts)
  vim.keymap.set('n', '<leader>D', '<cmd>lua vim.lsp.buf.type_definition()<CR>', opts)
  vim.keymap.set('n', '<leader>ca', '<cmd>CodeActionMenu<CR>', opts)
  vim.keymap.set('n', '<leader>e', '<cmd>lua vim.diagnostic.open_float()<CR>', opts)
  vim.keymap.set('n', '<leader>q', '<cmd>lua vim.diagnostic.setqflist()<CR>', opts)
  vim.keymap.set('n', '<leader>rn', '<cmd>lua vim.lsp.buf.rename()<CR>', opts)
  vim.keymap.set('n', '<leader>so', [[<cmd>lua require('telescope.builtin').lsp_document_symbols()<CR>]], opts)
  vim.keymap.set('n', '<leader>wa', '<cmd>lua vim.lsp.buf.add_workspace_folder()<CR>', opts)
  vim.keymap.set('n', '<leader>wl', '<cmd>lua print(vim.inspect(vim.lsp.buf.list_workspace_folders()))<CR>', opts)
  vim.keymap.set('n', '<leader>wr', '<cmd>lua vim.lsp.buf.remove_workspace_folder()<CR>', opts)
  vim.keymap.set('n', 'K', '<Cmd>lua vim.lsp.buf.hover()<CR>', opts)
  vim.keymap.set('n', '[d', '<cmd>lua vim.diagnostic.goto_prev()<CR>', opts)
  vim.keymap.set('n', ']d', '<cmd>lua vim.diagnostic.goto_next()<CR>', opts)
  vim.keymap.set('n', 'gD', '<Cmd>lua vim.lsp.buf.declaration()<CR>', opts)
  vim.keymap.set('n', 'gd', '<Cmd>lua vim.lsp.buf.definition()<CR>', opts)
  vim.keymap.set('n', 'gi', '<cmd>lua vim.lsp.buf.implementation()<CR>', opts)
  vim.keymap.set('n', 'gr', '<cmd>lua vim.lsp.buf.references()<CR>', opts)
  vim.keymap.set('v', '<leader>ca', '<cmd>lua vim.lsp.buf.range_code_action()<CR>', opts)
  vim.cmd [[ command! Format execute 'lua vim.lsp.buf.format({ async = true })' ]]
end

local opts = {
  on_attach = on_attach,
  capabilities = capabilities
}

lspconfig.bashls.setup(opts)
lspconfig.dockerls.setup(opts)
lspconfig.eslint.setup(opts)
lspconfig.gopls.setup(opts)
lspconfig.pyright.setup(opts)
lspconfig.rust_analyzer.setup(opts)
lspconfig.arduino_language_server.setup(opts)
lspconfig.clangd.setup(opts)
lspconfig.cmake.setup(opts)
lspconfig.cssls.setup(opts)
lspconfig.diagnosticls.setup(opts)
lspconfig.dotls.setup(opts)
lspconfig.emmet_ls.setup(opts)
lspconfig.graphql.setup(opts)
lspconfig.html.setup(opts)
lspconfig.jsonls.setup(opts)
lspconfig.stylelint_lsp.setup(opts)
lspconfig.sumneko_lua.setup({
  on_attach = on_attach,
  capabilities = capabilities,
  settings = {
    Lua = {
      workspace = {
        library = {
          vim.api.nvim_get_runtime_file('', true),
        }
      },
      diagnostics = {
        globals = { 'vim' },
        disable = { 'lowercase-global' }
      }
    }
  }
})
lspconfig.tsserver.setup(opts)
