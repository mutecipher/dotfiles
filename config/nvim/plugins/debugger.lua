local dap = require('dap')
require('dapui').setup()

dap.adapters.lldb = {
  type = 'executable';
  command = '/opt/homebrew/Cellar/llvm/13.0.0_1/bin/lldb-vscode';
  name = 'lldb';
}

dap.adapters.python = {
  type = 'executable';
  command = os.getenv('HOME') .. '/.pyenv/shims/python';
  args = { '-m', 'debugpy.adapter' };
}

dap.configurations.python = {
  {
    type = 'python';
    request = 'launch';
    name = "Launch file";
    program = "${file}";
    pythonPath = function()
      return os.getenv('HOME') .. '/.pyenv/shims/python'
    end;
  },
}
