local wezterm = require("wezterm")
local appearance = require("appearance")

local config = wezterm.config_builder()

if appearance.is_dark() then
  config.color_scheme = "Github Dark Default"
else
  config.color_scheme = "Github Light Default"
end

-- Modify the PATH to include Homebrew binaries
config.set_environment_variables = {
  PATH = "/opt/homebrew/bin:" .. os.getenv("PATH"),
}

config.initial_cols = 120
config.initial_rows = 40

config.native_macos_fullscreen_mode = true

config.font = wezterm.font({
  family = "MonoLisa Variable",
  harfbuzz_features = {
    "calt=1", -- Whitespace ligatures
    "liga=1", -- Enable ligatures
    "zero=1", -- Zeros with lines instead of dot
    "ss02=1", -- Script variant of italics
    "ss06=1", -- Proper @ symbol
    "ss07=1", -- Curlier braces
    "ss08=1", -- Rounder parentheses
    "ss10=1", -- Alternative greater than or equal symbol (eg. >=)
    "ss11=1", -- Alternative hexadecimal symbol (eg. 0x23)
  },
})
config.font_size = 13

config.hide_tab_bar_if_only_one_tab = true
config.show_new_tab_button_in_tab_bar = false
config.tab_bar_at_bottom = true
config.tab_max_width = 32
config.use_fancy_tab_bar = false

config.keys = {
  -- Sends ESC + b and ESC + f sequence, which is used
  -- for telling your shell to jump back/forward.
  {
    key = "LeftArrow",
    mods = "OPT",
    action = wezterm.action.SendString("\x1bb"),
  },
  {
    key = "RightArrow",
    mods = "OPT",
    action = wezterm.action.SendString("\x1bf"),
  },
  {
    key = ",",
    mods = "SUPER",
    action = wezterm.action.SpawnCommandInNewTab({
      cwd = wezterm.home_dir,
      args = { "nvim", wezterm.config_file },
    }),
  },
  {
    key = "o",
    mods = "CTRL",
    action = wezterm.action({ PaneSelect = {} }),
  },
}

return config
