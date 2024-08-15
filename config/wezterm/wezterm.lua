local wezterm = require("wezterm")
local appearance = require("appearance")
local github = require("github_theme")

local config = wezterm.config_builder()

config.color_schemes = github.color_schemes

if appearance.is_dark() then
	config.color_scheme = "GitHub Dark Default"
else
	config.color_scheme = "GitHub Light Default"
end

config.font = wezterm.font("MonoLisa Variable")
config.font_size = 14

config.hide_tab_bar_if_only_one_tab = true
config.use_fancy_tab_bar = false

return config
