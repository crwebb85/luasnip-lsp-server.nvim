local M = {}

---@class MarkCodeAction.MarkCodeActionConfig
---@field resolveSupport? boolean true if you (the user) have implemented autocommands to resolve lsp completion documentation

M.setup = function(opts)
    vim.api.nvim_create_autocmd('FileType', {
        pattern = '*',
        group = vim.api.nvim_create_augroup('luasnip-lsp-server-start', { clear = true }),
        callback = function(_)
            local client_capabilities = vim.lsp.protocol.make_client_capabilities()
            if opts.resolveSupport == true then
                local resolve_properties =
                    client_capabilities.textDocument.completion.completionItem.resolveSupport.properties
                table.insert(resolve_properties, 'documentation')
            end
            require('luasnip-lsp-server.server').start_snippet_lsp(client_capabilities)
        end,
    })
end

return M
