local lsp_installer = require("nvim-lsp-installer")
local on_attach = require("completion").on_attach

lsp_installer.on_server_ready(function(server)
    local opts = {
      on_attach = on_attach,
    }

    -- (optional) Customize the options passed to the server
    -- if server.name == "tsserver" then
    --     opts.root_dir = function() ... end
    -- end

    -- This setup() function is exactly the same as lspconfig's setup function (:help lspconfig-quickstart)
    server:setup(opts)
end)

