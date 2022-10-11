-- lspconfig.lua
-- https://github.com/neovim/nvim-lspconfig

local function on_attach(_, bufnr)
  local opts = {
    buffer = bufnr,
    noremap = true,
    silent = true
  }

  vim.keymap.set("n", "<c-K>", "<cmd>lua vim.lsp.buf.signature_help()<CR>", opts)
  vim.keymap.set("n", "<leader>D", "<cmd>lua vim.lsp.buf.type_definition()<CR>", opts)
  vim.keymap.set("n", "<leader>ca", "<cmd>lua vim.lsp.buf.code_action()<CR>", opts)
  vim.keymap.set("n", "<leader>e", "<cmd>lua vim.diagnostic.open_float()<CR>", opts)
  vim.keymap.set("n", "<leader>q", "<cmd>lua vim.diagnostic.setqflist()<CR>", opts)
  vim.keymap.set("n", "<leader>rn", "<cmd>lua vim.lsp.buf.rename()<CR>", opts)
  vim.keymap.set("n", "<leader>so", [[<cmd>lua require("telescope.builtin").lsp_document_symbols()<CR>]], opts)
  vim.keymap.set("n", "K", "<Cmd>lua vim.lsp.buf.hover()<CR>", opts)
  vim.keymap.set("n", "[d", "<cmd>lua vim.diagnostic.goto_prev()<CR>", opts)
  vim.keymap.set("n", "]d", "<cmd>lua vim.diagnostic.goto_next()<CR>", opts)
  vim.keymap.set("n", "gd", "<Cmd>lua vim.lsp.buf.definition()<CR>", opts)
  vim.keymap.set("n", "gi", "<cmd>lua vim.lsp.buf.implementation()<CR>", opts)
  vim.keymap.set("n", "gr", "<cmd>lua vim.lsp.buf.references()<CR>", opts)
  vim.keymap.set("v", "<leader>ca", "<cmd>lua vim.lsp.buf.range_code_action()<CR>", opts)
end

local capabilities = vim.lsp.protocol.make_client_capabilities()

local default_servers = {
  "astro",
  "bashls",
  "clangd",
  "cssls",
  "diagnosticls",
  "eslint",
  "gopls",
  "html",
  "jsonls",
  "sumneko_lua",
  "pyright",
  "rust_analyzer",
  "tailwindcss",
  "tsserver",
  "vimls",
  "yamlls"
}

local shopify_servers = {
  "ruby_ls",
  "sorbet"
}

if os.getenv("SHOPIFY_OWNED_DEVICE") then
  for _, server in ipairs(shopify_servers) do
    table.insert(default_servers, server)
  end
end

local mason_lspconfig = require("mason-lspconfig")
require("mason").setup {}
mason_lspconfig.setup {
  ensure_installed = default_servers,
  automatic_install = true
}

local lspconfig = require("lspconfig")
local cmp_nvim_lsp = require("cmp_nvim_lsp")

for _, server in ipairs(mason_lspconfig.get_installed_servers()) do
  lspconfig[server].setup {
    on_attach = on_attach,
    capabilities = cmp_nvim_lsp.update_capabilities(capabilities)
  }
end
