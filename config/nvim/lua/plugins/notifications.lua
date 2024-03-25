return {
  "folke/noice.nvim",
  opts = function(_, opts)
    table.insert(opts.routes, {
      background_colour = "#000000",
      filter = {
        event = "notify",
        find = "No information available",
      },
      opts = { skip = true },
    })
  end,
}
