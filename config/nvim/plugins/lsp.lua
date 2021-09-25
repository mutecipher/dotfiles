local nvim_lsp = require('lspconfig')
local on_attach = require('completion').on_attach

-- TODO: Figure out a better way to handle edge case LSP clients (i.e. clangd)
local servers = {
  'bashls', -- bash
  'diagnosticls', -- diagnostic
  'pyright', -- python
  'rls', -- rust
  'tsserver', -- typescript
  'vimls', -- vim
  'yamlls' -- yaml
}

for _, server in ipairs(servers) do
  nvim_lsp[server].setup {
    on_attach = on_attach,
  }
end
