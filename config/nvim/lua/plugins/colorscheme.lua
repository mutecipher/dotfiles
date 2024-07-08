return {
  -- add github
  {
    "projekt0n/github-nvim-theme",
    config = function()
      require("github-theme").setup({})
    end,
  },

  -- set the colorscheme
  {
    "LazyVim/LazyVim",
    opts = {
      colorscheme = "github_dark_default",
    },
  },
}
