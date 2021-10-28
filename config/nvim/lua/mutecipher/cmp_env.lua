local Job = require('plenary.job')
local source = {}

source.new = function()
  local self = setmetatable({ cache = {} }, { __index = source })
  return self
end

function source:is_available()
  -- local ft = vim.bo.filetype
  -- return ft == 'sh' or ft == 'bash'
  return true
end

function source:get_debug_name()
  return 'cmp_env'
end

-- function source:get_keyword_pattern(_)
--   return 'lua'
-- end

function source:get_trigger_characters(params)
  return { '$' }
end

local function split(s, delimiter)
  local result = {}
  for match in (s..delimiter):gmatch("(.-)"..delimiter) do
    table.insert(result, match)
  end
  return result
end

function source:complete(_, callback)
  local bufnr = vim.api.nvim_get_current_buf()

  if not self.cache[bufnr] then
    Job:new({
      "env",
      on_exit = function(job)
        local result = job:result()
        local items = {}
        for _, item in ipairs(result) do
          local kv = split(item, '=')
          table.insert(items, {
            label = kv[1],
            documentation = {
              kind = "markdown",
              value = string.format("# Value\n\n`%s=%s`", kv[1], kv[2])
            }
          })
        end
        callback(items)
        self.cache[bufnr] = items
      end
    }):start()
  else
    callback(self.cache[bufnr])
  end
end

function source:resolve(completion_item, callback)
  callback(completion_item)
end

function source:execute(completion_item, callback)
  callback(completion_item)
end

return source
