return {
  {
    "CopilotC-Nvim/CopilotChat.nvim",
    config = function()
      require("CopilotChat").setup({
        prompts = {
          Commit = {
            prompt = "Write a commit message for the change in standard git format without any special formatting. Keep the title under 50 characters and wrap message at 72 characters and use title case. Format as a gitcommit code block.",
            context = "git:staged",
          },
        },
      })
    end,
  },
  {
    "stevearc/conform.nvim",
    opts = {
      formatters_by_ft = {
        tf = { "tfmt" },
        terraform = { "tfmt" },
        hcl = { "tfmt" },
      },
      formatters = {
        tfmt = {
          command = "tofu",
          args = { "fmt", "-" },
          stdin = true,
        },
      },
    },
  },
}
