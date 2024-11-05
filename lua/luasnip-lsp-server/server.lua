local M = {}

---@type {[string]: lsp.CompletionItem[] }
local completion_cache_by_filetype = {}

---@type {[uinteger]: lsp.CompletionItem }
local completion_by_snip_id = {}

function M.clear_cache()
    completion_cache_by_filetype = {}
    completion_by_snip_id = {}
end

local DOC_TEMPLATE = [[
${name} _ `[${filetype}]`
---
${description}

```${filetype}
${codeblock}
```
]]

local function interpolate(s, items)
    return string.gsub(s, '${(%w+)}', function(n)
        return items[n]
    end)
end

local function build_snip_documentation(snip, filetype)
    ---@type string|string[]
    local codeblock = snip:get_docstring() or ''
    if type(codeblock) == 'table' then
        codeblock = vim.fn.join(codeblock, '\n')
    end

    ---@type string|string[]
    local description = snip.dscr or ''
    if type(description) == 'table' then
        description = vim.fn.join(description, '\n')
    end

    local documentation_str = interpolate(DOC_TEMPLATE, {
        name = snip.name or '',
        filetype = filetype or '',
        description = description,
        codeblock = codeblock,
    })
    local documentation_lines = vim.lsp.util.convert_input_to_markdown_lines({ documentation_str })
    local documentation = table.concat(documentation_lines, '\n')
    return documentation
end

---@alias LspServer.Handler fun(params: table?, callback: fun(err: lsp.ResponseError|nil, result: any), notify_reply_callback: fun(message_id: integer)|nil)

local is_client_resolve_support = false

---@type {string: LspServer.Handler}
local handlers = {

    ---@type LspServer.Handler
    [vim.lsp.protocol.Methods.initialize] = function(params, callback, _)
        local resolve_properties = vim.tbl_get(
            params,
            'capabilities',
            'textDocument',
            'completion',
            'completionItem',
            'resolveSupport',
            'properties'
        ) or {}
        for _, property in ipairs(resolve_properties) do
            if property == 'documentation' then
                is_client_resolve_support = true
                vim.lsp.log.debug('luasnip-server: Documentation resolve support detected for client')
            end
        end

        local initializeResult = {
            capabilities = {
                completionProvider = {
                    resolveProvider = true,
                },
            },
            serverInfo = {
                name = 'luasnip',
                version = '0.0.1',
            },
        }

        callback(nil, initializeResult)
    end,

    ---@type LspServer.Handler
    [vim.lsp.protocol.Methods.textDocument_completion] = function(_, callback, _)
        vim.lsp.log.debug('luasnip-server: Creating completion list for luasnip')
        ---@type lsp.CompletionItem[]
        local completion_items_result = {}

        ---@type string[]
        local filetypes = require('luasnip.util.util').get_snippet_filetypes()

        for _, filetype in ipairs(filetypes) do
            if not completion_cache_by_filetype[filetype] then
                ---@type lsp.CompletionItem[]
                local ft_completion_items = {}

                local snippets = require('luasnip').get_snippets(filetype, { type = 'snippets' })
                for _, snip in ipairs(snippets) do
                    if not snip.hidden then
                        local data = {
                            filetype = filetype,
                            snip_id = snip.id,
                        }
                        local completion_item = {
                            detail = 'luasnip',
                            label = snip.trigger,
                            kind = vim.lsp.protocol.CompletionItemKind.Snippet,
                            insertTextFormat = vim.lsp.protocol.InsertTextFormat.Snippet,
                            insertText = snip.trigger,
                            data = data,
                            cmd = 'luasnip.expand',
                            command = {
                                arguments = data,
                                command = 'luasnip.expand',
                                title = 'expandLuasnip',
                            },
                        }

                        if not is_client_resolve_support then
                            vim.lsp.log.debug('luasnip-server: Creating documentation for snippet ' .. snip.id)
                            completion_item.documentation = {
                                kind = vim.lsp.protocol.MarkupKind.Markdown,
                                value = build_snip_documentation(snip, filetype),
                            }
                        end
                        table.insert(ft_completion_items, completion_item)
                        completion_by_snip_id[snip.id] = completion_item
                    end
                end

                completion_cache_by_filetype[filetype] = ft_completion_items
            end
            vim.list_extend(completion_items_result, completion_cache_by_filetype[filetype])
        end

        callback(nil, completion_items_result)
    end,

    ---@type LspServer.Handler
    [vim.lsp.protocol.Methods.completionItem_resolve] = function(request, callback, _)
        local snip_id = request.data.snip_id
        local snip = require('luasnip').get_id_snippet(snip_id)
        local completion_item = completion_by_snip_id[snip_id]

        if completion_item == nil then
            ---@type lsp.ResponseError
            local err = {
                code = 0,
                message = 'Could not find snippet in cache.',
            }
            callback(err, nil)
            return
        end

        if completion_item.documentation == nil then
            local test = vim.lsp.log.debug('luasnip-server: Creating cached documentation for snippet ' .. snip_id)
            vim.print(test)
            local filetype = request.data and request.data.filetype
            --Side-effect: modifies cache to include the documentation
            completion_item.documentation = {
                kind = vim.lsp.protocol.MarkupKind.Markdown,
                value = build_snip_documentation(snip, filetype),
            }
        end

        callback(nil, completion_item)
    end,
}

vim.lsp.commands['luasnip.expand'] = function(params)
    local arguments = params.arguments
    if arguments == nil then
        return
    end

    local snip_id = arguments.snip_id
    if snip_id == nil then
        return
    end

    local snip = require('luasnip').get_id_snippet(snip_id)

    local line = require('luasnip.util.util').get_current_line_to_cursor()
    local expand_params = snip:matches(line)
    if expand_params ~= nil and expand_params.clear_region ~= nil then
        require('luasnip').snip_expand(snip, {
            clear_region = expand_params.clear_region,
            expand_params = expand_params,
        })
        return
    end

    local cursor = vim.api.nvim_win_get_cursor(0)
    local row = cursor[1] - 1 --convert to 0 based index
    local col = cursor[2]

    local col_offset = expand_params ~= nil and #expand_params.trigger or #snip.trigger

    local clear_region = {
        from = {
            row,
            col - col_offset,
        },
        to = { row, col },
    }

    require('luasnip').snip_expand(snip, {
        clear_region = clear_region,
        expand_params = expand_params,
    })
end

local message_id = -1
local function next_message_id()
    message_id = message_id + 1
    return message_id
end

--- @param capabilities? lsp.ClientCapabilities
M.start_snippet_lsp = function(capabilities)
    local client_id = vim.lsp.start({
        name = 'luasnip',
        filetypes = { '*' },
        root_dir = vim.fn.getcwd(),
        capabilities = capabilities or vim.lsp.protocol.make_client_capabilities(),
        ---@type fun(dispatchers: vim.lsp.rpc.Dispatchers): vim.lsp.rpc.PublicClient
        cmd = function(_)
            ---@type vim.lsp.rpc.PublicClient
            return {

                ---@type fun(method: string, params: table?, callback: fun(err: lsp.ResponseError|nil, result: any), notify_reply_callback: fun(message_id: integer)|nil):boolean,integer?
                request = function(method, params, callback, notify_reply_callback)
                    if handlers[method] then
                        handlers[method](params, callback, notify_reply_callback)
                        return true, next_message_id()
                    else
                        return false, nil
                    end
                end,
                notify = function(_, _)
                    return false
                end,
                is_closing = function()
                    return false
                end,
                terminate = function() end,
            }
        end,
        on_init = function(_)
            vim.lsp.log.debug('luasnip-server: Snippet LSP server initialized')
        end,
    }, {
        on_exit = function(code, signal)
            vim.lsp.log.debug('luasnip-server: Server exited with code ' .. code .. ' and signal ' .. signal)
        end,
    })
    if client_id == nil then
        error('Something went wrong')
    end

    return client_id
end

return M
