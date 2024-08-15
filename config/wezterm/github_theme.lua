local wezterm = require("wezterm")
local module = {}

module.color_schemes = {
	["GitHub Light Default"] = {
		background = "#ffffff",
		foreground = "#1F2328",

		cursor_bg = "#1F2328",
		cursor_border = "#1F2328",
		cursor_fg = "#ffffff",

		selection_bg = "#bbdfff",
		selection_fg = "#1F2328",

		ansi = {
			"#24292f",
			"#cf222e",
			"#116329",
			"#4d2d00",
			"#0969da",
			"#8250df",
			"#1b7c83",
			"#6e7781",
		},
		brights = {
			"#57606a",
			"#a40e26",
			"#1a7f37",
			"#633c01",
			"#218bff",
			"#a475f9",
			"#3192aa",
			"#8c959f",
		},
	},
	["GitHub Dark Default"] = {
		background = "#0d1117",
		foreground = "#e6edf3",

		cursor_bg = "#e6edf3",
		cursor_border = "#e6edf3",
		cursor_fg = "#0d1117",

		selection_bg = "#1e4273",
		selection_fg = "#e6edf3",

		ansi = {
			"#484f58",
			"#ff7b72",
			"#3fb950",
			"#d29922",
			"#58a6ff",
			"#bc8cff",
			"#39c5cf",
			"#b1bac4",
		},
		brights = {
			"#6e7681",
			"#ffa198",
			"#56d364",
			"#e3b341",
			"#79c0ff",
			"#d2a8ff",
			"#56d4dd",
			"#ffffff",
		},
	},
}
return module
