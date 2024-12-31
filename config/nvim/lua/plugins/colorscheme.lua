return {
  {
    "projekt0n/github-nvim-theme",
    config = function()
      require("github-theme").setup({
        options = {
          styles = {
            comments = "italic",
          },
        },
      })
    end,
  },
  { "nomis51/nvim-xcode-theme" },
}
