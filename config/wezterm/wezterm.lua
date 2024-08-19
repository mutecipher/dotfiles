local wezterm = require("wezterm")
local appearance = require("appearance")

local config = wezterm.config_builder()

if appearance.is_dark() then
	config.color_scheme = "Github Dark Default"
else
	config.color_scheme = "Github Light Default"
end

config.font = wezterm.font({
	family = "MonoLisa Variable",
	harfbuzz_features = { "calt=1", "liga=1", "zero=1", "ss02=1", "ss06=1", "ss07=1", "ss08=1", "ss10=1", "ss11=1" },
})
config.font_size = 13

config.hide_tab_bar_if_only_one_tab = true
config.use_fancy_tab_bar = false

config.set_environment_variables = {
	PATH = "/opt/homebrew/bin:" .. os.getenv("PATH"),
}

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
}

return config
