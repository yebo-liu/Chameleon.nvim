local M = {}
local fn = vim.fn
local api = vim.api

M.original_colors = nil

--- Extract a hex color from a highlight group attribute.
--- Returns nil if the attribute is not set (e.g. transparent themes).
---@param group string
---@param attr "bg"|"fg"
---@return string|nil "#RRGGBB" or nil
local function hl_hex(group, attr)
	local hl = api.nvim_get_hl(0, { name = group, link = false })
	local val = hl[attr]
	if val then
		return string.format("#%06X", val)
	end
	return nil
end

--- Build a color map from the current Neovim colorscheme.
--- Maps Kitty color names to hex values, skipping any that are nil (transparent).
---@return table<string, string>
local function get_nvim_colors()
	local colors = {}

	-- Core UI colors
	colors.background = hl_hex("Normal", "bg")
	colors.foreground = hl_hex("Normal", "fg")
	colors.cursor = hl_hex("Cursor", "bg") or hl_hex("Normal", "fg")
	colors.cursor_text_color = hl_hex("Cursor", "fg") or hl_hex("Normal", "bg")
	colors.selection_background = hl_hex("Visual", "bg")
	colors.selection_foreground = hl_hex("Visual", "fg")

	-- ANSI color palette (color0-color15)
	-- Map terminal highlight groups to Kitty's color indices
	local term_map = {
		[0] = "Normal",       -- black (use bg)
		[1] = "DiagnosticError",
		[2] = "DiagnosticOk",
		[3] = "DiagnosticWarn",
		[4] = "DiagnosticInfo",
		[5] = "Statement",
		[6] = "Special",
		[7] = "Normal",       -- white (use fg)
	}

	for i = 0, 7 do
		-- Check terminal highlights first, fall back to semantic groups
		local term_hl = api.nvim_get_hl(0, { name = "Terminal" .. i, link = false })
		if term_hl.fg then
			colors["color" .. i] = string.format("#%06X", term_hl.fg)
		else
			local group = term_map[i]
			local attr = (i == 0) and "bg" or "fg"
			colors["color" .. i] = hl_hex(group, attr)
		end

		-- Bright variants (color8-15): try Terminal highlights, then reuse base
		local bright_hl = api.nvim_get_hl(0, { name = "Terminal" .. (i + 8), link = false })
		if bright_hl.fg then
			colors["color" .. (i + 8)] = string.format("#%06X", bright_hl.fg)
		else
			colors["color" .. (i + 8)] = colors["color" .. i]
		end
	end

	return colors
end

--- Save the current Kitty colors so we can restore them on exit.
local function save_kitty_colors()
	if M.original_colors ~= nil then
		return
	end
	M.original_colors = {}
	fn.jobstart({ "kitty", "@", "get-colors" }, {
		on_stdout = function(_, data, _)
			for _, line in ipairs(data) do
				local key, val = line:match("^(%S+)%s+(%S+)")
				if key and val then
					M.original_colors[key] = val
				end
			end
		end,
		on_stderr = function(_, d, _)
			if #d > 1 then
				vim.notify(
					"Chameleon.nvim: Error getting colors. Make sure kitty remote control is turned on.",
					vim.log.levels.ERROR
				)
			end
		end,
	})
end

--- Push colors to Kitty via remote control.
---@param colors table<string, string> color name → hex value
---@param sync boolean if true, block until done (for VimLeavePre)
local function set_kitty_colors(colors, sync)
	local args = {}
	for name, hex in pairs(colors) do
		table.insert(args, name .. "=" .. hex)
	end
	if #args == 0 then
		return
	end

	local cmd = { "kitty", "@", "set-colors", "--match=recent:0", unpack(args) }
	if sync then
		fn.system(cmd)
	else
		fn.jobstart(cmd, {
			on_stderr = function(_, d, _)
				if #d > 1 then
					vim.notify(
						"Chameleon.nvim: Error setting colors. Make sure kitty remote control is turned on.",
						vim.log.levels.ERROR
					)
				end
			end,
		})
	end
end

--- Apply current Neovim colorscheme to Kitty.
local function sync_to_kitty()
	local colors = get_nvim_colors()
	-- Remove nil entries (transparent backgrounds etc.)
	local filtered = {}
	for k, v in pairs(colors) do
		if v then
			filtered[k] = v
		end
	end
	set_kitty_colors(filtered)
end

local function setup_autocmds()
	local autocmd = api.nvim_create_autocmd
	local group = api.nvim_create_augroup("ChameleonSync", { clear = true })

	autocmd({ "ColorScheme", "VimResume", "VimEnter" }, {
		pattern = "*",
		callback = sync_to_kitty,
		group = group,
	})

	autocmd({ "VimLeavePre", "VimSuspend" }, {
		callback = function()
			if M.original_colors and next(M.original_colors) then
				set_kitty_colors(M.original_colors, true)
			end
		end,
		group = api.nvim_create_augroup("ChameleonRestore", { clear = true }),
	})
end

M.setup = function()
	-- Only run inside Kitty
	if not vim.env.KITTY_PID then
		return
	end
	save_kitty_colors()
	setup_autocmds()
end

return M
