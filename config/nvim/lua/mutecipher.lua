local cmp_env = require('mutecipher.cmp_env')

local M = {}

require('cmp').register_source('env', cmp_env.new())

return M
