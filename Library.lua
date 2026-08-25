--[[
	Tallin UI Library
	Instance-based UI library for Roblox script executors.

	Design reference: Figma "Untitled" frame 1018:2
	API shape follows the conventions used across i77lhm/Libraries (MIT).

	Usage:
		local Library, Notifications, Themes = loadstring(game:HttpGet("<raw url>"))()
		local Window = Library:Window({ Name = "tallin" })
		local Tab = Window:Tab({ Name = "Combat" })
		local Section = Tab:Section({ Name = "Aimbot", Side = "Left" })
		Section:Toggle({ Name = "Enabled", Flag = "aim_enabled", Callback = print })
]]

--// Services /////////////////////////////////////////////////////////////////

local cloneref = cloneref or function(object)
	return object
end

local function GetService(name)
	return cloneref(game:GetService(name))
end

local Players = GetService("Players")
local RunService = GetService("RunService")
local UserInputService = GetService("UserInputService")
local TweenService = GetService("TweenService")
local HttpService = GetService("HttpService")
local Stats = GetService("Stats")

local LocalPlayer = Players.LocalPlayer
local Camera = workspace.CurrentCamera

--// Executor compatibility ////////////////////////////////////////////////////

local Compat = {}

Compat.getgenv = getgenv or function()
	return _G
end

Compat.gethui = gethui
Compat.protectgui = (syn and syn.protect_gui) or protect_gui or (secure_call and function() end) or nil
Compat.getcustomasset = getcustomasset or getsynasset or (syn and syn.getcustomasset)
Compat.setclipboard = setclipboard or toclipboard or (Clipboard and Clipboard.set)
Compat.getclipboard = getclipboard or (Clipboard and Clipboard.get)
Compat.request = request or http_request or (http and http.request)
Compat.identifyexecutor = identifyexecutor or getexecutorname

Compat.writefile = writefile
Compat.readfile = readfile
Compat.isfile = isfile
Compat.delfile = delfile
Compat.listfiles = listfiles
Compat.makefolder = makefolder
Compat.isfolder = isfolder

Compat.HasFilesystem = (Compat.writefile and Compat.readfile and Compat.isfile and Compat.listfiles) ~= nil

-- Wrapped filesystem calls: never throw, always report success as first value.
local FS = {}

function FS.WriteFile(path, contents)
	if not Compat.writefile then
		return false, "no filesystem access"
	end
	return pcall(Compat.writefile, path, contents)
end

function FS.ReadFile(path)
	if not Compat.readfile then
		return false, "no filesystem access"
	end
	return pcall(Compat.readfile, path)
end

function FS.IsFile(path)
	if not Compat.isfile then
		return false
	end
	local ok, result = pcall(Compat.isfile, path)
	return ok and result == true
end

function FS.DeleteFile(path)
	if not Compat.delfile then
		return false
	end
	return pcall(Compat.delfile, path)
end

function FS.ListFiles(path)
	if not Compat.listfiles then
		return {}
	end
	local ok, result = pcall(Compat.listfiles, path)
	if ok and type(result) == "table" then
		return result
	end
	return {}
end

function FS.EnsureFolder(path)
	if not (Compat.makefolder and Compat.isfolder) then
		return false
	end
	local ok, exists = pcall(Compat.isfolder, path)
	if ok and exists then
		return true
	end
	return pcall(Compat.makefolder, path)
end

--// Library root //////////////////////////////////////////////////////////////

local Library = {}
Library.__index = Library

Library.Name = "Tallin"
Library.Version = "1.0.0"
Library.Compat = Compat
Library.FS = FS

-- Flag store: every element with a Flag writes its value here.
Library.Flags = {}
-- Element registry keyed by flag, used by the config system.
Library.Elements = {}
-- Everything that must be torn down on unload.
Library.Connections = {}
Library.Instances = {}
Library.Windows = {}
-- Elements that asked to appear in the keybind list.
Library.KeybindList = {}
-- Registry of instance properties bound to theme keys.
Library.ThemeBindings = {}
-- Repaint callbacks for elements whose colours depend on their state.
Library.Refreshers = {}

Library.Open = true
Library.Unloaded = false

--[[
	Singletons and hooks that are filled in later, declared up front so the
	fields exist from the start. `false` rather than nil, since a nil field is
	simply absent from a Lua table.
]]
Library.Taskbar = false
Library.UnloadCallback = false
-- Windows that can be bound to a key, filled in as windows are created.
Library.BindableWindows = {}

--[[
	Everything that is not a colour: keybinds, notification behaviour and the
	accent animation. Declared here, ahead of the code that reads it, and
	persisted to disk alongside the theme.
]]
Library.Settings = {
	MenuKeybind = "RightShift",
	NotificationCorner = "BottomLeft",
	NotificationDuration = 5,
	NotificationSmoothness = 0.22,
	AccentAnimation = "Off",
	AccentAnimationSpeed = 1,
	WindowBinds = {},

	-- Transitions. Duration 0 turns every animation off.
	TweenDuration = 0.18,
	TweenStyle = "Quad",
	-- Fade dissolves the menu in place, Instant just toggles visibility.
	MenuTransition = "Fade",
	-- The watermark and player panel live outside the menu, so they stay on
	-- screen while the menu is closed.
	PersistWatermark = true,
	-- Bar is the full width strip, Compact is the small draggable dock.
	TaskbarMode = "Bar",
	-- The dock hides on its own, without taking the windows with it.
	ShowTaskbar = true,
	-- The windows hide on their own, without taking the dock with them.
	ShowWindows = true,

	--[[
		Lua editor behaviour. Colours for the editor live in the theme with
		everything else; these are the settings that are not colours.
	]]
	LuaAutoScroll = true,
	LuaLineNumbers = true,
	LuaHighlightLine = true,
	LuaCaretBlink = true,
	LuaFontSize = 11,
	LuaIndentSize = 4,
	LuaAutoIndent = true,

	-- UI font, by name from the font library.
	Font = "Tahoma 8px",

	-- What lights a button up, and how fast.
	ButtonHighlight = "Hover",
	ButtonTweenDuration = 0.12,

	-- Colour picker swatches: shaded gradient or a flat block.
	PickerGradient = true,
	PickerGradientShade = 0.45,

	--[[
		Manual font tuning. 0 for the size and -1 for the row mean "use whatever
		the chosen font declares"; 1 does the same for the ink offset, since a
		real ink value is always zero or negative.
	]]
	FontSizeOverride = 0,
	FontRowOverride = -1,
	FontInkOverride = 1,

	-- Picking a palette takes only its accent, leaving the rest of the theme.
	ThemeAccentOnly = false,
}

--[[
	Every swatch registers a refresher here, so toggling the gradient setting
	updates the pickers that already exist rather than only the next ones.
]]
Library.SwatchGradients = {}

function Library:RefreshSwatchGradients()
	for index = #Library.SwatchGradients, 1, -1 do
		local ok = pcall(Library.SwatchGradients[index])
		if not ok then
			table.remove(Library.SwatchGradients, index)
		end
	end
end

local BUTTON_HIGHLIGHTS = { "Hover", "Press", "Both" }
Library.ButtonHighlights = BUTTON_HIGHLIGHTS

local TWEEN_STYLES = { "Quad", "Quart", "Sine", "Back", "Cubic", "Exponential", "Linear" }
local MENU_TRANSITIONS = { "Fade", "Instant" }
local TASKBAR_MODES = { "Bar", "Compact" }

Library.TweenStyles = TWEEN_STYLES
Library.MenuTransitions = MENU_TRANSITIONS
Library.TaskbarModes = TASKBAR_MODES

--[[
	Every animated transition goes through here, so one duration and one easing
	style in the settings drive all of them.
]]
function Library:Tween(instance, properties, duration, style)
	local seconds = tonumber(duration) or tonumber(Library.Settings.TweenDuration) or 0.18

	if seconds <= 0 then
		for property, value in properties do
			pcall(function()
				instance[property] = value
			end)
		end
		return nil
	end

	local styleName = tostring(style or Library.Settings.TweenStyle or "Quad")
	local easing = Enum.EasingStyle[styleName] or Enum.EasingStyle.Quad

	local tween = TweenService:Create(
		instance,
		TweenInfo.new(seconds, easing, Enum.EasingDirection.Out),
		properties
	)
	tween:Play()

	return tween
end

Library.SettingsFile = "tallin/settings.json"

local NOTIFICATION_CORNERS = { "TopLeft", "TopRight", "BottomLeft", "BottomRight" }
local ACCENT_ANIMATIONS = { "Off", "Rainbow", "Fade", "Breathe" }

Library.NotificationCorners = NOTIFICATION_CORNERS
Library.AccentAnimations = ACCENT_ANIMATIONS

--[[
	List rebuilders. Each is replaced by the window that owns it once that
	window is built; until then they are no-ops, so callers never have to check.
]]
function Library:RefreshKeybindList() end
function Library:RefreshBindList() end
function Library:RefreshConfigList() end
function Library:RefreshThemeList() end
Library.ThemeWindowRef = false
Library.KeybindWindowRef = false
Library.WatermarkRef = false
Library.PlayerPanelRef = false
Library.LuaWindowRef = false
Library.ConfigWindowRef = false
-- The two switches in the settings window that mirror the dock/window state.
Library.DockToggleRef = false
Library.WindowsToggleRef = false

--[[
	Keeps those switches agreeing with reality, since a keybind or a dock button
	can change the state without going through them.
]]
function Library:SyncVisibilityToggles()
	if Library.DockToggleRef then
		Library.DockToggleRef:Set(Library.Settings.ShowTaskbar ~= false, true)
	end
	if Library.WindowsToggleRef then
		Library.WindowsToggleRef:Set(Library.Settings.ShowWindows ~= false, true)
	end
	return Library
end
-- The running menu open/close transition, if any.
Library.MenuTween = false
Library.MenuFade = false
-- The font entry currently in use, so its metrics can be recomputed.
Library.CurrentFontEntry = false

Library.MenuKeybind = Enum.KeyCode.RightShift
Library.ConfigFolder = "tallin"
Library.ThemeFile = "tallin/theme.json"

--// Theme /////////////////////////////////////////////////////////////////////

local Themes = {}

--[[
	Theme defaults.

	The twelve keys the design exposes in its Theme window were read straight
	off that window's own swatches, so they are the designer's values rather
	than colours inferred from the mockup:

		TextColor #FFFFFF    TextOutline #000000    TextColorUnsafe #FF0004
		TextColorMid #FFEA00 Accent #BFBEEE         AccentToggleShade #6D6D88
		ToggleInactive #202020  ToggleInactiveShade #0C0C0C  InactiveTab #4B4B4B
		SectionNameText         InactiveButtonText #595959   Shade #0F0F0F

	The remaining keys are internal: the design paints them but does not offer
	them for editing.
]]
Themes.Default = {
	-- text
	TextColor = Color3.fromRGB(255, 255, 255),
	TextOutline = Color3.fromRGB(0, 0, 0),
	-- risk tints: red for unsafe, yellow for the middle tier
	TextColorUnsafe = Color3.fromRGB(255, 0, 4),
	TextColorMid = Color3.fromRGB(255, 234, 0),
	-- the swatch reads #5C5C5C but every section title in the mockup is
	-- painted #999999, so the mockup wins here
	SectionNameText = Color3.fromRGB(153, 153, 153),
	InactiveButtonText = Color3.fromRGB(89, 89, 89),
	-- captions above dropdowns and textboxes
	CaptionText = Color3.fromRGB(125, 125, 125),
	DisabledText = Color3.fromRGB(76, 76, 76),

	--[[
		Accent is both the highlight colour for text, tabs and dividers and the
		top of every accent gradient. AccentToggleShade is that gradient's
		bottom, which is what fills toggle cores, slider bars and pressed
		buttons.
	]]
	Accent = Color3.fromRGB(191, 190, 238),
	AccentToggleShade = Color3.fromRGB(109, 109, 136),

	-- chrome
	Outline = Color3.fromRGB(0, 0, 0),
	Border = Color3.fromRGB(49, 49, 49),
	Background = Color3.fromRGB(22, 22, 22),
	InactiveTab = Color3.fromRGB(75, 75, 75),
	-- bottom of the taskbar and tab button gradient
	Shade = Color3.fromRGB(15, 15, 15),
	TabTop = Color3.fromRGB(36, 36, 36),

	-- section panel
	SectionTop = Color3.fromRGB(19, 19, 19),
	SectionBottom = Color3.fromRGB(23, 23, 23),
	SectionHeaderTop = Color3.fromRGB(30, 30, 30),
	SectionHeaderBottom = Color3.fromRGB(19, 19, 19),

	-- raised controls (buttons, dropdowns, textboxes)
	ToggleInactive = Color3.fromRGB(32, 32, 32),
	ToggleInactiveShade = Color3.fromRGB(12, 12, 12),

	-- player list priorities
	PriorityFriendly = Color3.fromRGB(120, 220, 120),
	PriorityEnemy = Color3.fromRGB(255, 234, 0),

	-- Lua editor syntax colours
	SyntaxText = Color3.fromRGB(220, 220, 220),
	SyntaxComment = Color3.fromRGB(106, 106, 106),
	SyntaxKeyword = Color3.fromRGB(191, 190, 238),
	SyntaxString = Color3.fromRGB(166, 168, 106),
	SyntaxNumber = Color3.fromRGB(255, 234, 0),
	SyntaxGlobal = Color3.fromRGB(143, 179, 255),
	SyntaxExecutor = Color3.fromRGB(255, 122, 122),
	SyntaxOperator = Color3.fromRGB(153, 153, 153),
}

Themes.Current = table.clone(Themes.Default)
-- Keys the user set by hand, which Accent must not overwrite.
Themes.Pinned = {}

-- Rows of the theme window, in the order the design lists them.
Themes.Order = {
	"TextColor",
	"TextOutline",
	"TextColorUnsafe",
	"TextColorMid",
	"Accent",
	"AccentToggleShade",
	"ToggleInactive",
	"ToggleInactiveShade",
	"InactiveTab",
	"SectionNameText",
	"InactiveButtonText",
	"Shade",
}

--[[
	Built-in palettes.

	These are written in the nine key shorthand the cheat scene uses, which is a
	smaller vocabulary than this library paints with:

		Outline / TextBorder  - hairline and text outline
		Accent                - highlight colour
		LightText / DarkText  - primary and secondary text
		LightContrast         - raised controls
		DarkContrast          - window background
		Inline                - inner border
		CursorOutline         - darkest shade

	Expand() fills in the rest by derivation, so a nine colour palette produces a
	complete theme without anyone having to hand pick thirty values.
]]
Themes.Palettes = {
	Purple = "000000 5d3e98 ffffff afafaf 1e1e1e 0a0a0a 141414 000000 323232",
	Abyss = "0a0a0a 8c87b4 ffffff afafaf 1e1e1e 141414 141414 0a0a0a 2d2d2d",
	Fatality = "0f0f28 f00f50 c8c8ff afafaf 231946 0f0f28 191432 0a0a0a 322850",
	Neverlose = "000005 00b4f0 ffffff afafaf 000f1e 0f0f28 050514 0a0a0a 0a1e28",
	Aimware = "000005 c82828 e8e8e8 afafaf 2b2b2b 191919 191919 0a0a0a 373737",
	Youtube = "000000 ff0000 f1f1f1 aaaaaa 232323 121212 0f0f0f 121212 393939",
	Gamesense = "000000 a7d94d ffffff afafaf 171717 141414 0c0c0c 141414 282828",
	Onetap = "000000 dda85d d6d9e0 afafaf 2c3037 000000 1f2125 000000 4e5158",
	Entropy = "0a0a0a 81bbe9 dcdcdc afafaf 3d3a43 000000 302f37 000000 4c4a52",
	Interwebz = "1a1a1a c9654b fcfcfc a8a8a8 291f38 1a1a1a 1f162b 000000 40364f",
	Dracula = "202126 9a81b3 b4b4b8 88888b 2a2c38 202126 252730 2a2c38 3c384d",
	Spotify = "0a0a0a 1ed760 d0d0d0 949494 181818 000000 121212 000000 292929",
	Sublime = "000000 ff9800 e8ffff d3d3c2 32332d 000000 282923 000000 484944",
	Vape = "0a0a0a 26866a dcdcdc afafaf 1f1f1f 000000 1a1a1a 000000 363636",
	Neko = "000000 d21f6a ffffff afafaf 171717 0a0a0a 131313 000000 2d2d2d",
	Corn = "000000 ff9000 dcdcdc afafaf 252525 000000 191919 000000 333333",
	Minecraft = "000000 27ce40 ffffff d7d7d7 333333 000000 262626 000000 333333",
}

-- Order they appear in the theme window.
Themes.PaletteOrder = {
	"Purple",
	"Abyss",
	"Fatality",
	"Neverlose",
	"Aimware",
	"Youtube",
	"Gamesense",
	"Onetap",
	"Entropy",
	"Interwebz",
	"Dracula",
	"Spotify",
	"Sublime",
	"Vape",
	"Neko",
	"Corn",
	"Minecraft",
}

Library.Theme = Themes.Current
Library.Themes = Themes

--// Utility ///////////////////////////////////////////////////////////////////

local Utils = {}
Library.Utils = Utils

function Utils.Clamp(value, min, max)
	if value < min then
		return min
	elseif value > max then
		return max
	end
	return value
end

function Utils.Lerp(a, b, alpha)
	return a + (b - a) * alpha
end

-- Rounds to the given step, e.g. Round(3.27, 0.05) -> 3.25
function Utils.Round(value, step)
	if not step or step <= 0 then
		return math.floor(value + 0.5)
	end
	local rounded = math.floor(value / step + 0.5) * step
	-- kill floating point noise like 0.30000000000000004
	local decimals = math.max(0, -math.floor(math.log10(step) + 0.5))
	local multiplier = 10 ^ decimals
	return math.floor(rounded * multiplier + 0.5) / multiplier
end

function Utils.Multiply(color, factor)
	return Color3.new(
		Utils.Clamp(color.R * factor, 0, 1),
		Utils.Clamp(color.G * factor, 0, 1),
		Utils.Clamp(color.B * factor, 0, 1)
	)
end

function Utils.ToHex(color)
	return string.format("%02X%02X%02X", color.R * 255, color.G * 255, color.B * 255)
end

function Utils.FromHex(hex)
	hex = tostring(hex):gsub("#", "")
	if #hex ~= 6 then
		return nil
	end
	local r = tonumber(hex:sub(1, 2), 16)
	local g = tonumber(hex:sub(3, 4), 16)
	local b = tonumber(hex:sub(5, 6), 16)
	if not (r and g and b) then
		return nil
	end
	return Color3.fromRGB(r, g, b)
end

function Utils.KeyName(keyCode)
	if typeof(keyCode) ~= "EnumItem" then
		return "none"
	end

	local aliases = {
		[Enum.KeyCode.LeftShift] = "LShift",
		[Enum.KeyCode.RightShift] = "RShift",
		[Enum.KeyCode.LeftControl] = "LCtrl",
		[Enum.KeyCode.RightControl] = "RCtrl",
		[Enum.KeyCode.LeftAlt] = "LAlt",
		[Enum.KeyCode.RightAlt] = "RAlt",
		[Enum.KeyCode.Insert] = "Ins",
		[Enum.KeyCode.Delete] = "Del",
		[Enum.KeyCode.PageUp] = "PgUp",
		[Enum.KeyCode.PageDown] = "PgDn",
		[Enum.KeyCode.Backspace] = "Bksp",
		[Enum.KeyCode.CapsLock] = "Caps",
		[Enum.UserInputType.MouseButton1] = "MB1",
		[Enum.UserInputType.MouseButton2] = "MB2",
		[Enum.UserInputType.MouseButton3] = "MB3",
	}

	if aliases[keyCode] then
		return aliases[keyCode]
	end
	return keyCode.Name
end

--// Instance creation /////////////////////////////////////////////////////////

-- Forward declaration: the fade system (defined later) caches its target list
-- and Track invalidates it when a new instance is created.
local FadeTargetCache = nil

-- Tracks every instance the library makes so Unload can wipe them.
local function Track(instance)
	Library.Instances[#Library.Instances + 1] = instance
	-- A new instance means the fade target list needs rebuilding.
	if FadeTargetCache then
		FadeTargetCache = nil
	end
	return instance
end

function Utils.New(className, properties, children)
	local instance = Instance.new(className)

	if properties then
		for key, value in properties do
			if key ~= "Parent" then
				instance[key] = value
			end
		end
	end

	if children then
		for _, child in children do
			child.Parent = instance
		end
	end

	if properties and properties.Parent then
		instance.Parent = properties.Parent
	end

	return Track(instance)
end

local New = Utils.New

-- Vertical two-stop gradient. `topColor` sits at the top edge.
function Utils.Gradient(parent, topColor, bottomColor, rotation)
	return New("UIGradient", {
		Color = ColorSequence.new(topColor, bottomColor),
		Rotation = rotation or 90,
		Parent = parent,
	})
end

--// Theme binding /////////////////////////////////////////////////////////////

--[[
	Every themed property is owned by exactly one painter: a function that
	resolves the property's current value from the theme and the element's own
	state. Painters are keyed by instance and property, so registering a second
	painter for the same property replaces the first instead of leaving two
	writers fighting over it.

	That single-owner rule is what keeps state dependent colours (active tab,
	hovered button, selected dropdown row) from drifting out of sync with the
	theme after a repaint.
]]
Library.Painters = {}
-- Weak keys: painters for destroyed instances fall out on their own.
Library.PainterIndex = setmetatable({}, { __mode = "k" })

--[[
	Painters also declare which theme keys they read. Changing one colour then
	only repaints the properties that actually depend on it, instead of walking
	every painter in the UI. That is what keeps an animated accent smooth: a
	frame of the animation touches a few dozen properties rather than a few
	thousand.
]]
Library.PaintersByKey = {}

local function IndexPainter(painter)
	for _, key in painter.Keys do
		local list = Library.PaintersByKey[key]
		if not list then
			list = {}
			Library.PaintersByKey[key] = list
		end
		table.insert(list, painter)
	end
end

local function UnindexPainter(painter)
	for _, key in painter.Keys do
		local list = Library.PaintersByKey[key]
		if list then
			local at = table.find(list, painter)
			if at then
				table.remove(list, at)
			end
		end
	end
end

function Library:Paint(instance, property, resolve, keys)
	local perInstance = Library.PainterIndex[instance]
	if not perInstance then
		perInstance = {}
		Library.PainterIndex[instance] = perInstance
	end

	-- Retire whatever used to own this property.
	local previous = perInstance[property]
	if previous then
		local at = table.find(Library.Painters, previous)
		if at then
			table.remove(Library.Painters, at)
		end
		UnindexPainter(previous)
	end

	local painter = {
		Instance = instance,
		Property = property,
		Resolve = resolve,
		Keys = keys or {},
	}

	function painter.Apply()
		-- Single pcall wraps both the resolve and the assignment. Two separate
		-- pcalls per painter added measurable overhead on large repaints.
		local ok = pcall(function()
			local value = resolve()
			if value ~= nil then
				instance[property] = value
			end
		end)
		return ok
	end

	perInstance[property] = painter
	table.insert(Library.Painters, painter)
	IndexPainter(painter)
	painter.Apply()

	return painter
end

-- Repaints only the properties that declared a dependency on these keys.
function Library:RepaintKeys(keys)
	-- Single-key case (most theme changes): skip the dedup table entirely.
	if #keys == 1 then
		local list = Library.PaintersByKey[keys[1]]
		if list then
			for index = #list, 1, -1 do
				local painter = list[index]
				if typeof(painter.Instance) ~= "Instance" then
					table.remove(list, index)
				else
					painter.Apply()
				end
			end
		end
		return
	end

	-- Multi-key case: deduplicate painters that appear under more than one key.
	local done = {}
	for _, key in keys do
		local list = Library.PaintersByKey[key]
		if list then
			for index = #list, 1, -1 do
				local painter = list[index]
				if done[painter] then
					continue
				end
				done[painter] = true

				if typeof(painter.Instance) ~= "Instance" then
					table.remove(list, index)
					continue
				end

				painter.Apply()
			end
		end
	end
end

--[[
	Binds a property straight to a theme key. `transform` maps the colour to the
	final value, which is how gradients stay in sync with a single key.
]]
function Library:Bind(instance, property, themeKey, transform)
	return Library:Paint(instance, property, function()
		local color = Themes.Current[themeKey] or Themes.Default[themeKey]
		if color == nil then
			return nil
		end
		return transform and transform(color) or color
	end, { themeKey })
end

-- Re-resolves every painter. Runs on any theme change, which is a user action,
-- so walking the whole list is cheap enough and keeps the result deterministic.
function Library:Repaint()
	local painters = Library.Painters
	local count = #painters
	local writeIndex = 0

	for readIndex = 1, count do
		local painter = painters[readIndex]

		if typeof(painter.Instance) ~= "Instance" then
			UnindexPainter(painter)
			continue
		end

		painter.Apply()
		writeIndex += 1
		painters[writeIndex] = painter
	end

	-- Trim the dead tail.
	for i = writeIndex + 1, count do
		painters[i] = nil
	end
end

function Library:GetTheme(key)
	return Themes.Current[key] or Themes.Default[key]
end

function Library:RefreshTheme(key, value)
	if type(key) == "table" then
		for themeKey, themeValue in key do
			Library:RefreshTheme(themeKey, themeValue)
		end
		return
	end

	if typeof(value) == "string" then
		value = Utils.FromHex(value)
	end
	if typeof(value) ~= "Color3" then
		return false
	end

	Themes.Current[key] = value

	--[[
		Changing Accent drags its gradient shade along, so one colour retints
		the whole UI. Setting AccentToggleShade by hand pins it and stops that.
		The 0.571 factor is the ratio between the two swatches in the design.
	]]
	if key == "AccentToggleShade" then
		Themes.Pinned.AccentToggleShade = true
	elseif key == "Accent" and not Themes.Pinned.AccentToggleShade then
		Themes.Current.AccentToggleShade = Utils.Multiply(value, 0.571)
	end

	--[[
		Only what depends on this key is repainted. Accent drags its derived
		shade along, so both are refreshed together.
	]]
	if key == "Accent" then
		Library:RepaintKeys({ "Accent", "AccentToggleShade" })
	else
		Library:RepaintKeys({ key })
	end

	-- Anything that cannot be expressed as a single property painter.
	for index = #Library.Refreshers, 1, -1 do
		local ok = pcall(Library.Refreshers[index])
		if not ok then
			table.remove(Library.Refreshers, index)
		end
	end

	return true
end

-- Registers a repaint callback invoked after every theme change.
function Library:OnThemeChange(callback)
	table.insert(Library.Refreshers, callback)
	return callback
end

-- Kept for callers that used the old name.
function Library:ApplyBindings()
	Library:Repaint()
end

--// Connections ///////////////////////////////////////////////////////////////

function Library:Connect(signal, callback)
	local connection = signal:Connect(callback)
	table.insert(Library.Connections, connection)
	return connection
end

--// Font //////////////////////////////////////////////////////////////////////

--[[
	The design is drawn in "fs Tahoma 8px", a bitmap pixel font with no Roblox
	equivalent. It is loaded the same way the i77lhm libraries do it: fetch the
	.ttf, wrap it in a font family manifest that points at getcustomasset, then
	hand that manifest to Font.new.

	The .ttf is hosted in i77lhm/storage, the asset repo behind those MIT
	licensed libraries.

	Falls back to Enum.Font.Code when the executor lacks writefile,
	getcustomasset or HTTP access.
]]
Library.Font = Enum.Font.Code
Library.FontFace = nil

local FONT_NAME = "fs-tahoma-8px"
local FONT_TTF_PATH = "tallin/fonts/fs-tahoma-8px.ttf"
local FONT_MANIFEST_PATH = "tallin/fonts/fs-tahoma-8px.font"
local FONT_SOURCES = {
	"https://github.com/i77lhm/storage/raw/refs/heads/main/fonts/fs-tahoma-8px.ttf",
	"https://github.com/weasely111/beta/raw/refs/heads/main/fs-tahoma-8px.ttf",
}

local FONT_STORAGE = "https://github.com/i77lhm/storage/raw/refs/heads/main/fonts/"

--[[
	Fonts available from the same asset repo as the design font. The pixel faces
	want a size that matches their bitmap grid, so each one carries the size that
	renders it crisply; anything else is left at the library default.
]]
--[[
	Size is the body text size, Ink the vertical nudge for centred text, and Row
	the extra pixels every row gains so the face is not cramped.

	Pixel faces sit tight and need no headroom. Outline faces have real ascenders
	and descenders, so they get a pixel or two, and Comfortaa gets more because it
	is both round and wide.
]]
--[[
	Per font adaptation.

		Size  - body text size
		Title - size for window titles and the taskbar
		Ink   - vertical nudge for centred text
		Row   - extra pixels every row gains

	A bitmap face only renders crisply at the size it was drawn for: its em box is
	usually 16, and asking for 13 makes Roblox resample it, which is what turns
	Proggy Clean bold and clipped. So the pixel faces run at their native size and
	buy the room they need through Row, rather than being squeezed into the 15px
	rows the design uses for fs Tahoma 8px.
]]
local FONT_LIBRARY = {
	--[[
		A bitmap face has Title equal to Size on purpose. There is no larger crisp
		size to step up to: asking for one resamples the glyphs, and the text
		outline then picks up spikes on every corner.
	]]
	{ Name = "Tahoma 8px", File = "fs-tahoma-8px.ttf", Size = 12, Title = 12, Ink = -1, Row = 0 },
	{ Name = "Tahoma", File = "Tahoma-Modern.ttf", Size = 12, Title = 14, Ink = 0, Row = 1 },
	{ Name = "Tahoma Bold", File = "Tahoma-Modern-Bold.ttf", Size = 12, Title = 14, Ink = 0, Row = 1 },
	{ Name = "Tahoma Small", File = "tahoma_bold.ttf", Size = 12, Title = 12, Ink = -1, Row = 0 },

	--[[
		Pixel faces. These sit at 12 or 13 like the design font: their glyphs are
		drawn tall inside the em box, so asking for 16 produces text half again
		the size of everything else. Anything left over is dialled in with the
		Font sliders in the theme.
	]]
	{ Name = "Proggy Clean", File = "ProggyClean.ttf", Size = 13, Title = 13, Ink = -2, Row = 0 },
	{ Name = "Proggy Tiny", File = "ProggyTiny.ttf", Size = 13, Title = 13, Ink = -2, Row = 0 },
	{ Name = "Minecraftia", File = "Minecraftia-Regular.ttf", Size = 12, Title = 12, Ink = -2, Row = 1 },
	{ Name = "Open Sans px", File = "open-sans-px.ttf", Size = 12, Title = 12, Ink = -2, Row = 0 },
	{ Name = "Smallest Pixel", File = "smallest_pixel-7.ttf", Size = 12, Title = 12, Ink = -2, Row = 0 },

	-- Outline faces: real ascenders and descenders, so a couple of pixels each.
	{ Name = "Verdana", File = "Verdana-Font.ttf", Size = 11, Title = 13, Ink = 0, Row = 2 },
	{ Name = "Rubik", File = "Rubik-Regular.ttf", Size = 11, Title = 13, Ink = 0, Row = 2 },
	{ Name = "Inter Medium", File = "Inter_28pt-Medium.ttf", Size = 11, Title = 13, Ink = 0, Row = 2 },
	{
		Name = "Inter SemiBold",
		File = "Inter_28pt-SemiBold.ttf",
		Size = 11,
		Title = 13,
		Ink = 0,
		Row = 2,
	},
	{
		Name = "Hanken Grotesk",
		File = "HankenGrotesk-SemiBold.ttf",
		Size = 11,
		Title = 13,
		Ink = 0,
		Row = 2,
	},
	-- Round and wide, so it gets the most room.
	{ Name = "Comfortaa", File = "Comfortaa-Regular.ttf", Size = 11, Title = 13, Ink = 0, Row = 3 },
	{ Name = "Light Modern", File = "Light Modern.ttf", Size = 12, Title = 14, Ink = 0, Row = 1 },
}

Library.FontLibrary = FONT_LIBRARY

function Library:GetFontNames()
	local names = {}
	for _, entry in FONT_LIBRARY do
		table.insert(names, entry.Name)
	end
	return names
end

--[[
	Fetches every font in the list up front, in the background.

	Switching fonts is otherwise a download followed by a load, and Roblox needs
	a moment before a freshly written face is usable: swap quickly between two
	and some text keeps the old one. Having the files on disk already removes
	that window.
]]
function Library:PreloadFonts()
	if not (Compat.writefile and Compat.getcustomasset) then
		return false
	end

	task.spawn(function()
		FS.EnsureFolder("tallin")
		FS.EnsureFolder("tallin/fonts")

		for _, entry in FONT_LIBRARY do
			if Library.Unloaded then
				return
			end

			local path = "tallin/fonts/" .. entry.File
			if not FS.IsFile(path) then
				local ok, body = pcall(function()
					return (game :: any):HttpGet(FONT_STORAGE .. entry.File:gsub(" ", "%%20"), true)
				end)
				if ok and type(body) == "string" and #body > 1024 then
					FS.WriteFile(path, body)
				end
			end

			-- One per frame, so the download loop cannot stall the UI.
			task.wait()
		end
	end)

	return true
end

-- Wraps an already-written font file into a family manifest and returns a Font.
local function BuildFontFace(ttfPath, manifestPath, familyName)
	if not Compat.getcustomasset then
		return nil
	end

	local okAsset, ttfAsset = pcall(Compat.getcustomasset, ttfPath)
	if not okAsset or not ttfAsset then
		return nil
	end

	local manifest = {
		name = familyName,
		faces = {
			{
				name = "Regular",
				weight = 400,
				style = "normal",
				assetId = ttfAsset,
			},
		},
	}

	-- Rewrite the manifest every run: a stale one points at a dead asset path.
	if Compat.delfile and FS.IsFile(manifestPath) then
		FS.DeleteFile(manifestPath)
	end

	local encodedOk, encoded = pcall(function()
		return HttpService:JSONEncode(manifest)
	end)
	if not encodedOk then
		return nil
	end

	if not FS.WriteFile(manifestPath, encoded) then
		return nil
	end

	local okManifest, manifestAsset = pcall(Compat.getcustomasset, manifestPath)
	if not okManifest or not manifestAsset then
		return nil
	end

	local okFont, face = pcall(function()
		return Font.new(manifestAsset, Enum.FontWeight.Regular, Enum.FontStyle.Normal)
	end)
	if not okFont then
		return nil
	end

	return face
end

-- Downloads the design font once per session and caches it in the global env.
local function LoadTahoma()
	local cache = Compat.getgenv()
	if typeof(cache.TallinFontFace) == "Font" then
		return cache.TallinFontFace
	end

	if not (Compat.writefile and Compat.getcustomasset) then
		return nil
	end

	FS.EnsureFolder("tallin")
	FS.EnsureFolder("tallin/fonts")

	if not FS.IsFile(FONT_TTF_PATH) then
		local downloaded
		for _, url in FONT_SOURCES do
			-- HttpGet is an executor extension, hence the cast.
			local ok, body = pcall(function()
				return (game :: any):HttpGet(url, true)
			end)
			if ok and type(body) == "string" and #body > 1024 then
				downloaded = body
				break
			end
		end

		if not downloaded then
			return nil
		end
		if not FS.WriteFile(FONT_TTF_PATH, downloaded) then
			return nil
		end
	end

	local face = BuildFontFace(FONT_TTF_PATH, FONT_MANIFEST_PATH, FONT_NAME)
	if face then
		cache.TallinFontFace = face
	end
	return face
end

Library.LoadTahoma = LoadTahoma

--[[
	SetFont accepts:
		nil / "tahoma"  - the design font, downloaded on demand
		Enum.Font       - used directly
		Font            - used directly
		number          - Roblox asset id of a .ttf already uploaded
		string url      - direct link to a .ttf
]]
function Library:SetFont(font)
	local face

	if font == nil or font == "tahoma" then
		face = LoadTahoma()
		if not face then
			Library.FontFace = nil
			Library.Font = Enum.Font.Code
		end
	elseif typeof(font) == "EnumItem" and font.EnumType == Enum.Font then
		Library.Font = font
		Library.FontFace = nil
	elseif typeof(font) == "Font" then
		face = font
	elseif type(font) == "string" and font:match("^https?://") then
		local ok, body = pcall(function()
			return (game :: any):HttpGet(font, true)
		end)
		if ok and type(body) == "string" and #body > 1024 then
			FS.EnsureFolder("tallin")
			FS.EnsureFolder("tallin/fonts")
			local path = "tallin/fonts/custom.ttf"
			if FS.WriteFile(path, body) then
				face = BuildFontFace(path, "tallin/fonts/custom.font", "TallinCustom")
			end
		end
	elseif type(font) == "number" or (type(font) == "string" and tonumber(font)) then
		-- An uploaded asset id can be referenced directly in the manifest.
		local manifest = {
			name = "TallinCustom",
			faces = {
				{
					name = "Regular",
					weight = 400,
					style = "normal",
					assetId = "rbxassetid://" .. tostring(tonumber(font)),
				},
			},
		}
		FS.EnsureFolder("tallin")
		FS.EnsureFolder("tallin/fonts")
		local path = "tallin/fonts/custom_asset.font"
		local encodedOk, encoded = pcall(function()
			return HttpService:JSONEncode(manifest)
		end)
		if encodedOk and FS.WriteFile(path, encoded) and Compat.getcustomasset then
			local okAsset, asset = pcall(Compat.getcustomasset, path)
			if okAsset then
				local okFont, built = pcall(function()
					return Font.new(asset, Enum.FontWeight.Regular, Enum.FontStyle.Normal)
				end)
				if okFont then
					face = built
				end
			end
		end
	end

	if face then
		Library.FontFace = face
	end

	-- retro-apply to every text object already on screen
	for _, instance in Library.Instances do
		local isText = typeof(instance) == "Instance"
			and (instance:IsA("TextLabel") or instance:IsA("TextButton") or instance:IsA("TextBox"))
		if isText then
			pcall(function()
				if Library.FontFace then
					instance.FontFace = Library.FontFace
				else
					instance.Font = Library.Font
				end
			end)
		end
	end

	return Library
end

-- Applies the current font choice to a freshly created text object.
local function ApplyFont(instance)
	if Library.FontFace then
		instance.FontFace = Library.FontFace
	else
		instance.Font = Library.Font
	end
	return instance
end

Utils.ApplyFont = ApplyFont

--// Metrics ///////////////////////////////////////////////////////////////////

--[[
	Pixel metrics lifted from the Figma frame. Roblox text renders taller than
	the bitmap Tahoma used in the design, so TextSize values are the closest
	match to the design's glyph box rather than its nominal font size.
]]
local Metrics = {
	TaskbarHeight = 25,
	TaskbarPadding = 3,
	TaskbarButtonHeight = 19,

	WindowTitleHeight = 25,
	TabHeight = 29,
	TabWidth = 125,

	SectionPadding = 5,
	SectionHeaderHeight = 14,
	SectionWidth = 252,

	-- Lua editor line number column
	GutterWidth = 26,

	RowHeight = 15,
	RowGap = 3,
	ToggleSize = 15,
	ToggleCore = 11,
	SliderHeight = 15,
	DropdownHeight = 17,
	ButtonHeight = 18,
	TextboxHeight = 17,
	SwatchWidth = 39,
	SwatchHeight = 13,

	-- Vertical nudge applied to centred text, correcting the bitmap font's
	-- off-centre ink. Set to 0 when using a normal outline font.
	TextInkOffset = -2,

	-- fs Tahoma 8px is a bitmap face: it stays crisp at 11, 12 and 14 only.
	TextTiny = 11,
	TextSmall = 11,
	TextBase = 12,
	TextMedium = 14,
	TextLarge = 14,
}

Library.Metrics = Metrics

--[[
	Font adaptation.

	Metrics above are the design's values for fs Tahoma 8px. Another face has
	different glyph heights, so swapping the font without touching the layout
	leaves text either cramped or overflowing its row.

	Two registries make the layout adapt after the fact. Each text object and each
	row records which metric it was built from, along with the offset it was built
	with, so both can be recomputed when the font changes:

		Utils.Text({ TextSize = Metrics.TextMedium })  ->  role "TextMedium", 0
		self:Row(Metrics.RowHeight - 2)                ->  role "RowHeight", -2

	The nearest metric wins, which is what makes derived sizes like the line above
	follow along instead of being left behind.
]]
local DESIGN_METRICS = table.clone(Metrics)

local TEXT_ROLES = { "TextTiny", "TextSmall", "TextBase", "TextMedium", "TextLarge" }
local ROW_ROLES = {
	"RowHeight",
	"ToggleSize",
	"SliderHeight",
	"DropdownHeight",
	"ButtonHeight",
	"TextboxHeight",
	"SwatchHeight",
	"TabHeight",
}

-- Weak keys: entries disappear with the instances they describe.
local TextRegistry = setmetatable({}, { __mode = "k" })
local RowRegistry = setmetatable({}, { __mode = "k" })

-- Finds the metric a value was derived from, and by how much.
local function ClosestRole(roles, value)
	local bestRole, bestDelta
	for _, role in roles do
		local delta = value - Metrics[role]
		if not bestDelta or math.abs(delta) < math.abs(bestDelta) then
			bestRole, bestDelta = role, delta
		end
	end
	return bestRole, bestDelta or 0
end

--[[
	`basePosition` is the position before the ink nudge was applied. Keeping it
	lets the nudge be recomputed for the next font instead of being baked in,
	which would leave every centred label a pixel out after a switch.
]]
function Utils.TrackText(instance, size, basePosition)
	local role, delta = ClosestRole(TEXT_ROLES, size)
	TextRegistry[instance] = {
		Role = role,
		Delta = delta,
		BasePosition = basePosition,
	}
	return instance
end

-- Controls that are square by design, the toggle box among them.
function Utils.TrackSquare(instance, size)
	local role, delta = ClosestRole(ROW_ROLES, size)
	RowRegistry[instance] = { Role = role, Delta = delta, Square = true }
	return instance
end

function Utils.TrackRow(instance, height)
	local role, delta = ClosestRole(ROW_ROLES, height)
	RowRegistry[instance] = { Role = role, Delta = delta }
	return instance
end

--[[
	Recomputes every metric for the given font entry and pushes the result into
	the objects already on screen.

		Size - text size for the body of the UI
		Ink  - vertical nudge for centred text
		Row  - extra pixels every row gains, for faces that need the headroom
]]
function Library:ApplyFontMetrics(entry)
	entry = entry or Library.CurrentFontEntry or {}
	Library.CurrentFontEntry = entry

	--[[
		Overrides from the theme win over the font's own numbers. Zero means "use
		the font's value", so a fresh install follows the table above and anyone
		can still dial a face in by hand without editing code.
	]]
	local settings = Library.Settings
	local sizeOverride = tonumber(settings.FontSizeOverride) or 0
	local rowOverride = tonumber(settings.FontRowOverride) or -1
	local inkOverride = tonumber(settings.FontInkOverride) or 1

	local size = sizeOverride > 0 and sizeOverride or (tonumber(entry.Size) or DESIGN_METRICS.TextBase)
	local title = sizeOverride > 0 and (sizeOverride + 1) or (tonumber(entry.Title) or (size + 2))
	local rowBump = rowOverride >= 0 and rowOverride or (tonumber(entry.Row) or 0)

	if inkOverride <= 0 then
		entry = table.clone(entry)
		entry.Ink = inkOverride
	end

	--[[
		Titles are given explicitly rather than derived: a bitmap face at its
		native 16 has no larger crisp size to step up to, so its titles stay at
		the body size instead of being scaled and going soft.
	]]
	Metrics.TextInkOffset = tonumber(entry.Ink) or 0
	Metrics.TextTiny = math.max(8, size - (size >= 16 and 2 or 1))
	Metrics.TextSmall = math.max(8, size - (size >= 16 and 2 or 1))
	Metrics.TextBase = size
	Metrics.TextMedium = title
	Metrics.TextLarge = title

	for _, role in ROW_ROLES do
		Metrics[role] = DESIGN_METRICS[role] + rowBump
	end

	-- Push the new sizes, and the new ink nudge, into the text already on screen.
	for instance, record in TextRegistry do
		if typeof(instance) == "Instance" then
			local object = instance :: any
			pcall(function()
				object.TextSize = math.max(8, Metrics[record.Role] + record.Delta)

				if record.BasePosition then
					object.Position = record.BasePosition
						+ UDim2.fromOffset(0, Metrics.TextInkOffset)
				end
			end)
		end
	end

	-- And the new heights into the rows and square controls.
	for instance, record in RowRegistry do
		if typeof(instance) == "Instance" then
			local object = instance :: any
			pcall(function()
				local value = math.max(6, Metrics[record.Role] + record.Delta)

				if record.Square then
					object.Size = UDim2.fromOffset(value, value)
				else
					object.Size = UDim2.new(object.Size.X.Scale, object.Size.X.Offset, 0, value)
				end
			end)
		end
	end

	return Library
end

--[[
	Switches the whole UI to one of the fonts in FONT_LIBRARY, downloading it on
	first use and caching it under tallin/fonts.

	Defined here rather than with the rest of the font code because it writes to
	Metrics, which is declared just above: reaching for it any earlier would bind
	to a global of the same name instead.
]]
function Library:SetFontByName(name)
	local entry
	for _, candidate in FONT_LIBRARY do
		if candidate.Name == name or candidate.File == name then
			entry = candidate
			break
		end
	end

	if not entry then
		Library:Notify(string.format("unknown font %s", tostring(name)))
		return false
	end

	if not (Compat.writefile and Compat.getcustomasset) then
		Library:Notify("executor cannot load custom fonts")
		return false
	end

	FS.EnsureFolder("tallin")
	FS.EnsureFolder("tallin/fonts")

	local path = "tallin/fonts/" .. entry.File

	if not FS.IsFile(path) then
		-- Spaces in a filename have to be escaped for the raw URL.
		local ok, body = pcall(function()
			return (game :: any):HttpGet(FONT_STORAGE .. entry.File:gsub(" ", "%%20"), true)
		end)
		if not (ok and type(body) == "string" and #body > 1024) then
			Library:Notify(string.format("could not download %s", entry.Name))
			return false
		end
		if not FS.WriteFile(path, body) then
			return false
		end
	end

	local face = BuildFontFace(path, path .. ".font", entry.Name)
	if not face then
		Library:Notify(string.format("could not build %s", entry.Name))
		return false
	end

	Library.FontFace = face
	Library.Settings.Font = entry.Name

	-- Size, ink offset and row headroom all travel with the face.
	Library:ApplyFontMetrics(entry)

	--[[
		Repoint every text object at the new face, then once more on the next
		frame: objects built while the switch was running, and any face Roblox had
		not finished loading, would otherwise be left on the previous font.
	]]
	local function repoint()
		for _, instance in Library.Instances do
			local isText = typeof(instance) == "Instance"
				and (
					instance:IsA("TextLabel")
					or instance:IsA("TextButton")
					or instance:IsA("TextBox")
				)
			if isText then
				pcall(function()
					instance.FontFace = face
				end)
			end
		end
	end

	repoint()
	task.defer(repoint)

	return true
end

-- Pull in the design font before anything renders.
pcall(function()
	Library:SetFont("tahoma")
end)

--// ScreenGui /////////////////////////////////////////////////////////////////

local function ResolveGuiParent()
	if Compat.gethui then
		local ok, hui = pcall(Compat.gethui)
		if ok and hui then
			return hui
		end
	end

	local ok, coreGui = pcall(GetService, "CoreGui")
	if ok and coreGui then
		return coreGui
	end

	return LocalPlayer:WaitForChild("PlayerGui")
end

local function CreateScreenGui()
	local screen = Instance.new("ScreenGui")
	screen.Name = HttpService:GenerateGUID(false)
	screen.DisplayOrder = 1000
	screen.IgnoreGuiInset = true
	screen.ResetOnSpawn = false
	screen.ZIndexBehavior = Enum.ZIndexBehavior.Sibling

	if Compat.protectgui then
		pcall(Compat.protectgui, screen)
	end

	screen.Parent = ResolveGuiParent()
	return Track(screen)
end

Library.ScreenGui = CreateScreenGui()

-- Holder keeps every window under one toggleable parent.
Library.Holder = New("Frame", {
	Name = "Holder",
	BackgroundTransparency = 1,
	Size = UDim2.fromScale(1, 1),
	ZIndex = 1,
	Parent = Library.ScreenGui,
})

--[[
	Overlays that outlive the menu: the watermark and the player panel are
	parented here, so closing the menu leaves them on screen.
]]
Library.Persistent = New("Frame", {
	Name = "Persistent",
	BackgroundTransparency = 1,
	Size = UDim2.fromScale(1, 1),
	ZIndex = 2,
	Parent = Library.ScreenGui,
})

--[[
	Fixed layers, so a long session can never shuffle them: ordinary windows
	live at the bottom, then the taskbar, then popups, then the heads-up panels
	that must stay readable over everything, and notifications on top.
]]
Library.ZLayers = {
	Window = 10,
	WindowMax = 1900,
	Taskbar = 4000,
	PopupBlocker = 4400,
	Popup = 4500,
	TopMost = 4700,
	Notification = 5000,
}

-- Windows share a Z stack so clicking one brings it forward.
Library.TopZIndex = Library.ZLayers.Window

--[[
	The counter is clamped to the window layer: without that it grows for as
	long as the menu is open and eventually climbs over the popup and heads-up
	layers, which is what used to push the keybind list under a window.
]]
function Library:BringToFront(frame)
	Library.TopZIndex += 1
	if Library.TopZIndex > Library.ZLayers.WindowMax then
		Library.TopZIndex = Library.ZLayers.Window
	end
	frame.ZIndex = Library.TopZIndex
	return Library.TopZIndex
end

-- Popups stack among themselves inside their own layer.
Library.PopupZIndex = 0

function Library:NextPopupZIndex()
	Library.PopupZIndex += 1
	if Library.PopupZIndex > 90 then
		Library.PopupZIndex = 1
	end
	return Library.PopupZIndex
end

--// Building blocks ///////////////////////////////////////////////////////////

--[[
	The signature look of the design: 1px outline, 1px border, filled body.
	Returns the outer frame and the body frame that children should parent to.
]]
function Utils.Panel(properties)
	local outer = New("Frame", properties or {})
	outer.BorderSizePixel = 0
	Library:Bind(outer, "BackgroundColor3", "Outline")

	local border = New("Frame", {
		Name = "Border",
		BorderSizePixel = 0,
		Position = UDim2.fromOffset(1, 1),
		Size = UDim2.new(1, -2, 1, -2),
		Parent = outer,
	})
	Library:Bind(border, "BackgroundColor3", "Border")

	local body = New("Frame", {
		Name = "Body",
		BorderSizePixel = 0,
		Position = UDim2.fromOffset(1, 1),
		Size = UDim2.new(1, -2, 1, -2),
		Parent = border,
	})
	Library:Bind(body, "BackgroundColor3", "Background")

	return outer, body
end

--[[
	Panel whose body is filled with a two-stop vertical gradient driven by two
	theme keys. Both keys stay live, so changing either one refreshes the fill.
]]
function Utils.Surface(properties, topKey, bottomKey)
	local outer, body = Utils.Panel(properties)

	local gradient = Utils.Gradient(body, Themes.Current[topKey], Themes.Current[bottomKey])
	Library:Bind(gradient, "Color", topKey, function(top)
		return ColorSequence.new(top, Themes.Current[bottomKey])
	end)
	Library:Bind(gradient, "Color", bottomKey, function(bottom)
		return ColorSequence.new(Themes.Current[topKey], bottom)
	end)

	--[[
		UIGradient multiplies the background, so the base has to be white.

		Panel already registered a painter binding this property to Background,
		and that painter has to be *replaced*, not merely overwritten: otherwise
		the next repaint puts the dark colour back, the gradient multiplies into
		near black, and every gradient in the UI looks like it vanished.
	]]
	Library:Paint(body, "BackgroundColor3", function()
		return Color3.new(1, 1, 1)
	end)

	return outer, body, gradient
end

--[[
	White base for a panel body filled by something other than a theme key: a
	gradient, or a colour the element owns. Same reason as above.
]]
function Utils.ClearBase(body)
	return Library:Paint(body, "BackgroundColor3", function()
		return Color3.new(1, 1, 1)
	end)
end

-- Raised control surface used by buttons, dropdowns and textboxes.
function Utils.Raised(properties)
	return Utils.Surface(properties, "ToggleInactive", "ToggleInactiveShade")
end

-- Same surface filled with the accent gradient. Used for "on" states.
function Utils.Accented(properties)
	return Utils.Surface(properties, "Accent", "AccentToggleShade")
end

-- Taskbar and tab buttons use their own slightly lighter pair.
function Utils.TabSurface(properties)
	return Utils.Surface(properties, "TabTop", "Shade")
end

--[[
	Text input, built the same way a label is.

	Raw TextBoxes miss the bitmap font's ink correction and the font tracking that
	Utils.Text applies, which is why their text sits a pixel low next to every
	label around them. Everything editable goes through here instead.
]]
function Utils.Input(properties)
	local defaults = {
		BackgroundTransparency = 1,
		ClearTextOnFocus = false,
		TextSize = Metrics.TextBase,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextYAlignment = Enum.TextYAlignment.Center,
	}

	for key, value in properties do
		defaults[key] = value
	end

	local themeKey = defaults.ThemeKey
	defaults.ThemeKey = nil

	local ink = Metrics.TextInkOffset or 0
	local basePosition

	if defaults.TextYAlignment == Enum.TextYAlignment.Center then
		basePosition = defaults.Position or UDim2.new()
		if ink ~= 0 then
			defaults.Position = basePosition + UDim2.fromOffset(0, ink)
		end
	end

	local box = New("TextBox", defaults)
	ApplyFont(box)
	Utils.Outline(box)
	Utils.TrackText(box, defaults.TextSize, basePosition)

	Library:Bind(box, "TextColor3", themeKey or "TextColor")

	return box
end

--[[
	The design's 1px black text outline.

	UIStroke with a mitred join is used rather than TextStrokeTransparency: the
	built-in stroke is drawn as a soft halo that smears a bitmap font at these
	sizes, while UIStroke stays a crisp single pixel. This is also what the
	reference libraries do.
]]
function Utils.Outline(textObject, thickness)
	textObject.TextStrokeTransparency = 1

	local stroke = New("UIStroke", {
		Thickness = thickness or 1,
		LineJoinMode = Enum.LineJoinMode.Miter,
		Parent = textObject,
	})
	Library:Bind(stroke, "Color", "TextOutline")

	return stroke
end

-- Text label with the design's outline and the bitmap font's ink correction.
function Utils.Text(properties)
	local defaults = {
		BackgroundTransparency = 1,
		TextSize = Metrics.TextBase,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextYAlignment = Enum.TextYAlignment.Center,
		RichText = true,
	}

	for key, value in properties do
		defaults[key] = value
	end

	-- ThemeKey is ours, not a Roblox property, so it must not reach Instance.
	local themeKey = defaults.ThemeKey
	defaults.ThemeKey = nil

	--[[
		fs Tahoma 8px sits low inside its line box, so vertically centred text
		lands a pixel or two below the optical centre. Nudge it back up.
		Metrics.TextInkOffset is tunable if a different face is loaded.
	]]
	local ink = Metrics.TextInkOffset or 0
	local basePosition

	if defaults.TextYAlignment == Enum.TextYAlignment.Center then
		basePosition = defaults.Position or UDim2.new()
		if ink ~= 0 then
			defaults.Position = basePosition + UDim2.fromOffset(0, ink)
		end
	end

	local label = New("TextLabel", defaults)
	ApplyFont(label)
	Utils.Outline(label)

	-- Remembered so a font change can resize and re-nudge it.
	Utils.TrackText(label, defaults.TextSize, basePosition)

	if not properties.TextColor3 then
		Library:Bind(label, "TextColor3", themeKey or "TextColor")
	end

	return label
end

--[[
	Sizes a holder to fit its label. Custom fonts report TextBounds only once
	the face has loaded, so the width is reapplied whenever the bounds change
	instead of being measured a single time.
]]
function Utils.HugWidth(holder, label, padding, minimum)
	padding = padding or 8
	minimum = minimum or 20

	local function apply()
		holder.Size = UDim2.fromOffset(
			math.max(minimum, math.ceil(label.TextBounds.X) + padding),
			holder.Size.Y.Offset
		)
	end

	Library:Connect(label:GetPropertyChangedSignal("TextBounds"), apply)
	apply()

	return apply
end

--[[
	The accent divider under window titles: two 1px halves that fade out from
	the centre, matching the paired gradient lines in the design.
]]
function Utils.Divider(parent, yOffset)
	local fadeOut = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0),
		NumberSequenceKeypoint.new(1, 1),
	})
	local fadeIn = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 1),
		NumberSequenceKeypoint.new(1, 0),
	})

	local left = New("Frame", {
		Name = "DividerLeft",
		BorderSizePixel = 0,
		Position = UDim2.new(0, Metrics.SectionPadding, 0, yOffset),
		Size = UDim2.new(0.5, -Metrics.SectionPadding, 0, 1),
		Parent = parent,
	})
	Library:Bind(left, "BackgroundColor3", "Accent")
	New("UIGradient", { Transparency = fadeIn, Parent = left })

	local right = New("Frame", {
		Name = "DividerRight",
		BorderSizePixel = 0,
		Position = UDim2.new(0.5, 0, 0, yOffset),
		Size = UDim2.new(0.5, -Metrics.SectionPadding, 0, 1),
		Parent = parent,
	})
	Library:Bind(right, "BackgroundColor3", "Accent")
	New("UIGradient", { Transparency = fadeOut, Parent = right })

	return left, right
end

-- Invisible button stretched over a control to catch clicks.
function Utils.Hitbox(parent, zIndex)
	return New("TextButton", {
		Name = "Hitbox",
		BackgroundTransparency = 1,
		Text = "",
		AutoButtonColor = false,
		Size = UDim2.fromScale(1, 1),
		ZIndex = zIndex or 20,
		Parent = parent,
	})
end

--// Luau syntax highlighting //////////////////////////////////////////////////

local LUAU_KEYWORDS = {}
for _, word in {
	"and", "break", "do", "else", "elseif", "end", "false", "for", "function",
	"if", "in", "local", "nil", "not", "or", "repeat", "return", "then", "true",
	"until", "while", "continue", "export", "type", "self",
} do
	LUAU_KEYWORDS[word] = true
end

local LUAU_GLOBALS = {}
for _, word in {
	"game", "workspace", "script", "shared", "_G", "_VERSION",
	"math", "table", "string", "task", "os", "coroutine", "debug", "bit32",
	"utf8", "buffer", "vector",
	"assert", "error", "warn", "print", "pcall", "xpcall", "select", "type",
	"typeof", "tostring", "tonumber", "ipairs", "pairs", "next", "unpack",
	"rawget", "rawset", "rawequal", "rawlen", "setmetatable", "getmetatable",
	"require", "newproxy", "gcinfo", "tick", "time", "elapsedTime",
	"wait", "spawn", "delay", "DebuggerManager", "settings", "stats",
	"Instance", "Vector2", "Vector3", "Vector2int16", "Vector3int16", "CFrame",
	"Color3", "ColorSequence", "ColorSequenceKeypoint", "NumberSequence",
	"NumberSequenceKeypoint", "NumberRange", "UDim", "UDim2", "Rect", "Region3",
	"Ray", "Random", "TweenInfo", "PhysicalProperties", "BrickColor", "Enum",
	"Font", "OverlapParams", "RaycastParams", "DateTime", "Faces", "Axes",
} do
	LUAU_GLOBALS[word] = true
end

--[[
	Globals provided by script executors rather than by Roblox. Highlighted in
	their own colour so it is obvious at a glance which calls will only work
	under an executor.
]]
local EXECUTOR_GLOBALS = {}
for _, word in {
	"getgenv", "getrenv", "getreg", "getgc", "getinstances", "getnilinstances",
	"getloadedmodules", "getscripts", "getrunningscripts", "getcallingscript",
	"getscriptclosure", "getscripthash", "getsenv", "getfenv", "setfenv",
	"hookfunction", "replaceclosure", "hookmetamethod", "getrawmetatable",
	"setrawmetatable", "setreadonly", "isreadonly", "make_writeable",
	"make_readonly", "newcclosure", "checkcaller", "islclosure", "iscclosure",
	"isexecutorclosure", "checkclosure", "clonefunction", "getfunctionhash",
	"getnamecallmethod", "setnamecallmethod", "getcallbackvalue",
	"getconnections", "firesignal", "fireclickdetector", "fireproximityprompt",
	"firetouchinterest", "gethui", "getcustomasset", "getsynasset", "cloneref",
	"compareinstances", "identifyexecutor", "getexecutorname", "request",
	"http_request", "setclipboard", "toclipboard", "setfpscap", "getfpscap",
	"writefile", "readfile", "appendfile", "isfile", "delfile", "listfiles",
	"makefolder", "isfolder", "delfolder", "loadstring", "dumpstring",
	"decompile", "protect_gui", "unprotect_gui", "queue_on_teleport",
	"queueonteleport", "mouse1click", "mouse1press", "mouse1release",
	"mouse2click", "mouse2press", "mouse2release", "mousemoveabs",
	"mousemoverel", "mousescroll", "keypress", "keyrelease", "iskeydown",
	"Drawing", "isrenderobj", "getrenderproperty", "setrenderproperty",
	"cleardrawcache", "getthreadidentity", "setthreadidentity",
	"gethiddenproperty", "sethiddenproperty", "setscriptable", "getproperties",
	"messagebox", "setsimulationradius", "syn", "secure_call", "crypt",
	"lz4compress", "lz4decompress", "base64encode", "base64decode",
	"WebSocket", "websocket", "setidentity", "getidentity",
} do
	EXECUTOR_GLOBALS[word] = true
end

Library.SyntaxKeywords = LUAU_KEYWORDS
Library.SyntaxGlobals = LUAU_GLOBALS
Library.SyntaxExecutorGlobals = EXECUTOR_GLOBALS

local function EscapeRich(text)
	text = text:gsub("&", "&amp;")
	text = text:gsub("<", "&lt;")
	text = text:gsub(">", "&gt;")
	text = text:gsub('"', "&quot;")
	text = text:gsub("'", "&apos;")
	return text
end

local function Span(themeKey, text)
	local color = Themes.Current[themeKey] or Themes.Default[themeKey]
	return string.format('<font color="#%s">%s</font>', Utils.ToHex(color), EscapeRich(text))
end

--[[
	Hand written tokeniser producing RichText. It walks the source once and
	tests for long-bracket comments and long-bracket strings before line
	comments and quotes, so a long comment opener is never mistaken for an
	ordinary line comment.

	Highlighting is presentational only: unterminated strings or comments simply
	colour to the end of the source instead of raising an error.
]]
function Utils.Highlight(source)
	source = tostring(source or "")

	-- Very long sources are left plain: colouring them costs more than it helps.
	if #source > 20000 then
		return EscapeRich(source)
	end

	local out = {}
	local position = 1
	local length = #source

	local function push(themeKey, text)
		table.insert(out, Span(themeKey, text))
	end

	while position <= length do
		local char = source:sub(position, position)
		local pair = source:sub(position, position + 1)

		-- long comment
		if pair == "--" then
			local bracketStart, bracketEnd, equals = source:find("^%-%-%[(=*)%[", position)
			if bracketStart then
				local closing = "]" .. equals .. "]"
				local closeAt = source:find(closing, bracketEnd + 1, true)
				local stop = closeAt and (closeAt + #closing - 1) or length
				push("SyntaxComment", source:sub(position, stop))
				position = stop + 1
				continue
			end

			-- line comment
			local lineEnd = source:find("\n", position, true)
			local stop = lineEnd and (lineEnd - 1) or length
			push("SyntaxComment", source:sub(position, stop))
			position = stop + 1
			continue
		end

		-- long string
		local longStart, longEnd, longEquals = source:find("^%[(=*)%[", position)
		if longStart then
			local closing = "]" .. longEquals .. "]"
			local closeAt = source:find(closing, longEnd + 1, true)
			local stop = closeAt and (closeAt + #closing - 1) or length
			push("SyntaxString", source:sub(position, stop))
			position = stop + 1
			continue
		end

		-- quoted string
		if char == '"' or char == "'" then
			local cursor = position + 1
			while cursor <= length do
				local inner = source:sub(cursor, cursor)
				if inner == "\\" then
					cursor += 2
				elseif inner == char or inner == "\n" then
					break
				else
					cursor += 1
				end
			end
			local stop = math.min(cursor, length)
			push("SyntaxString", source:sub(position, stop))
			position = stop + 1
			continue
		end

		-- number
		if char:match("%d") then
			local numberEnd = select(2, source:find("^0[xX][%x_]+", position))
				or select(2, source:find("^%d+%.?%d*[eE]?[%+%-]?%d*", position))
				or position
			push("SyntaxNumber", source:sub(position, numberEnd))
			position = numberEnd + 1
			continue
		end

		-- identifier
		if char:match("[%a_]") then
			local wordEnd = select(2, source:find("^[%w_]+", position)) or position
			local word = source:sub(position, wordEnd)

			if LUAU_KEYWORDS[word] then
				push("SyntaxKeyword", word)
			elseif EXECUTOR_GLOBALS[word] then
				push("SyntaxExecutor", word)
			elseif LUAU_GLOBALS[word] then
				push("SyntaxGlobal", word)
			else
				push("SyntaxText", word)
			end

			position = wordEnd + 1
			continue
		end

		-- whitespace passes through untouched, keeping newlines intact
		if char:match("%s") then
			local spaceEnd = select(2, source:find("^%s+", position)) or position
			table.insert(out, source:sub(position, spaceEnd))
			position = spaceEnd + 1
			continue
		end

		--[[
			Everything else is punctuation or an operator.

			Quotes and the long bracket opener are excluded from the run: a plain
			`%p+` match is greedy and swallows the quote in `("`, after which the
			string is never recognised and its contents colour as ordinary text.
		]]
		local operatorEnd = select(2, source:find("^[^%w%s\"'%[]+", position)) or position
		push("SyntaxOperator", source:sub(position, operatorEnd))
		position = operatorEnd + 1
	end

	return table.concat(out)
end

--// Dragging //////////////////////////////////////////////////////////////////

--[[
	Drags `target` by `handle`, clamped so the window can't be thrown off screen.
	Positions stay in absolute offsets, which is what the design assumes.
]]
function Utils.Drag(handle, target, onFinished, minY)
	local dragging = false
	local dragStart, startPosition

	Library:Connect(handle.InputBegan, function(input)
		if input.UserInputType ~= Enum.UserInputType.MouseButton1
			and input.UserInputType ~= Enum.UserInputType.Touch then
			return
		end

		dragging = true
		dragStart = input.Position
		startPosition = target.Position

		--[[
			Windows are raised to the front when dragged, but overlays that
			already live high in the stack (popups, the keybind panel) must keep
			their ZIndex. Raising a popup would drop it below its own click
			blocker, and it could never be grabbed again.
		]]
		if target.ZIndex < 3000 then
			Library:BringToFront(target)
		end

		local changed
		changed = input.Changed:Connect(function()
			if input.UserInputState == Enum.UserInputState.End then
				dragging = false
				changed:Disconnect()
				if onFinished then
					onFinished(target.Position)
				end
			end
		end)
	end)

	Library:Connect(UserInputService.InputChanged, function(input)
		if not dragging then
			return
		end
		if input.UserInputType ~= Enum.UserInputType.MouseMovement
			and input.UserInputType ~= Enum.UserInputType.Touch then
			return
		end

		local delta = input.Position - dragStart
		local viewport = Camera and Camera.ViewportSize or Vector2.new(1920, 1080)
		local size = target.AbsoluteSize

		-- Windows stay below the taskbar; the taskbar itself passes minY = 0.
		local top = minY or Metrics.TaskbarHeight

		local x = Utils.Clamp(startPosition.X.Offset + delta.X, 0, math.max(0, viewport.X - size.X))
		local y = Utils.Clamp(startPosition.Y.Offset + delta.Y, top, math.max(top, viewport.Y - size.Y))

		target.Position = UDim2.fromOffset(x, y)
	end)
end

--// Options ///////////////////////////////////////////////////////////////////

--[[
	The reference libraries are inconsistent about option casing (Bbot uses
	Name/Callback, Priv9 uses name/callback), so every option lookup accepts
	both spellings.
]]
local function Field(options, key, default)
	if type(options) ~= "table" then
		return default
	end

	local value = options[key]
	if value ~= nil then
		return value
	end

	local lower = key:sub(1, 1):lower() .. key:sub(2)
	value = options[lower]
	if value ~= nil then
		return value
	end

	value = options[key:lower()]
	if value ~= nil then
		return value
	end

	return default
end

Library.Field = Field

--// Notifications /////////////////////////////////////////////////////////////

local Notifications = {}
Notifications.__index = Notifications
Notifications.Active = {}

Library.NotificationHolder = New("Frame", {
	Name = "Notifications",
	AnchorPoint = Vector2.new(0, 1),
	BackgroundTransparency = 1,
	Position = UDim2.new(0, 8, 1, -8),
	Size = UDim2.fromOffset(300, 400),
	ZIndex = Library.ZLayers.Notification,
	Parent = Library.Holder,
}, {
	New("UIListLayout", {
		FillDirection = Enum.FillDirection.Vertical,
		HorizontalAlignment = Enum.HorizontalAlignment.Left,
		VerticalAlignment = Enum.VerticalAlignment.Bottom,
		SortOrder = Enum.SortOrder.LayoutOrder,
		Padding = UDim.new(0, 4),
	}),
})

--[[
	Notifications are not part of the Figma frame, so they reuse the same
	chrome as everything else: outlined panel, accent strip, outlined text.
]]
function Notifications:Create(options)
	if type(options) == "string" then
		options = { Name = options }
	end

	local text = tostring(Field(options, "Name", Field(options, "Text", "")))
	local duration = tonumber(Field(options, "Duration", Library.Settings.NotificationDuration)) or 5

	local row = New("Frame", {
		Name = "Notification",
		BackgroundTransparency = 1,
		ClipsDescendants = false,
		Size = UDim2.new(0, 0, 0, 20),
		AutomaticSize = Enum.AutomaticSize.X,
		Parent = Library.NotificationHolder,
	})

	--[[
		The row itself is placed by the list layout, so the slide is done by an
		inner frame: it starts one width off screen on whichever side the corner
		faces and tweens back to zero.
	]]
	local slide = New("Frame", {
		Name = "Slide",
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 1),
		Parent = row,
	})

	local outer, body = Utils.Panel({
		Size = UDim2.fromScale(1, 1),
		Parent = slide,
	})

	local strip = New("Frame", {
		Name = "Accent",
		BorderSizePixel = 0,
		Size = UDim2.new(0, 2, 1, 0),
		Parent = body,
	})
	Library:Bind(strip, "BackgroundColor3", "Accent")

	local label = Utils.Text({
		Position = UDim2.fromOffset(8, 0),
		Size = UDim2.new(0, 0, 1, 0),
		AutomaticSize = Enum.AutomaticSize.X,
		Text = text,
		Parent = body,
	})

	-- Size the row from the measured text so the panel hugs its content.
	row.AutomaticSize = Enum.AutomaticSize.None
	row.Size = UDim2.fromOffset(60, 20)
	Utils.HugWidth(row, label, 20, 60)

	local notification = setmetatable({
		Frame = row,
		Slide = slide,
		Outer = outer,
		Label = label,
	}, Notifications)

	-- Slide in from the edge the corner faces.
	local fromRight = tostring(Library.Settings.NotificationCorner):find("Right") ~= nil
	local smoothness = math.max(0, tonumber(Library.Settings.NotificationSmoothness) or 0.22)

	slide.Position = UDim2.fromScale(fromRight and 1.2 or -1.2, 0)
	if smoothness > 0 then
		TweenService:Create(
			slide,
			TweenInfo.new(smoothness, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
			{ Position = UDim2.fromScale(0, 0) }
		):Play()
	else
		slide.Position = UDim2.fromScale(0, 0)
	end

	table.insert(Notifications.Active, notification)

	task.delay(duration, function()
		notification:Destroy()
	end)

	return notification
end

function Notifications:Destroy()
	if not self.Frame then
		return
	end

	-- Slide back out before the row is removed.
	local smoothness = math.max(0, tonumber(Library.Settings.NotificationSmoothness) or 0.22)
	local fromRight = tostring(Library.Settings.NotificationCorner):find("Right") ~= nil

	if smoothness > 0 and self.Slide and self.Slide.Parent then
		local tween = TweenService:Create(
			self.Slide,
			TweenInfo.new(smoothness, Enum.EasingStyle.Quad, Enum.EasingDirection.In),
			{ Position = UDim2.fromScale(fromRight and 1.2 or -1.2, 0) }
		)
		tween:Play()
		tween.Completed:Once(function()
			if self.Frame then
				self.Frame:Destroy()
				self.Frame = nil
			end
		end)
	else
		self.Frame:Destroy()
		self.Frame = nil
	end

	local index = table.find(Notifications.Active, self)
	if index then
		table.remove(Notifications.Active, index)
	end
end

Notifications.CreateNotification = Notifications.Create
Notifications.create_notification = Notifications.Create
Library.Notifications = Notifications

-- Moves the notification stack to one of the four corners.
function Library:SetNotificationCorner(corner)
	corner = tostring(corner or "BottomLeft")
	if not table.find(NOTIFICATION_CORNERS, corner) then
		corner = "BottomLeft"
	end

	Library.Settings.NotificationCorner = corner

	local top = corner:find("Top") ~= nil
	local right = corner:find("Right") ~= nil
	local holder = Library.NotificationHolder
	local layout = holder:FindFirstChildOfClass("UIListLayout")

	-- Anchor the stack into the chosen corner and grow it away from the edge.
	holder.AnchorPoint = Vector2.new(right and 1 or 0, top and 0 or 1)
	holder.Position = UDim2.new(
		right and 1 or 0,
		right and -8 or 8,
		top and 0 or 1,
		top and (Metrics.TaskbarHeight + 8) or -8
	)

	if layout then
		layout.HorizontalAlignment = right and Enum.HorizontalAlignment.Right
			or Enum.HorizontalAlignment.Left
		layout.VerticalAlignment = top and Enum.VerticalAlignment.Top
			or Enum.VerticalAlignment.Bottom
	end

	return Library
end

function Library:Notify(options)
	return Notifications:Create(options)
end

--// Taskbar ///////////////////////////////////////////////////////////////////

--[[
	The full width bar at the top of the design: 23px body, 1px border and 1px
	outline stacked below it, the script name plus date on the left, then one
	button per window.
]]
local function CreateTaskbar()
	local bar = New("Frame", {
		Name = "Taskbar",
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0, Metrics.TaskbarHeight),
		ZIndex = Library.ZLayers.Taskbar,
		Parent = Library.Holder,
	})

	--[[
		Two shapes, one set of children.

		Bar     - full width strip pinned to the top of the screen, with the
		          border and outline drawn as lines along its bottom edge.
		Compact - a small dock that hugs its buttons and can be dragged
		          anywhere, drawn as an outlined panel.
	]]
	local body = New("Frame", {
		Name = "Body",
		BorderSizePixel = 0,
		Size = UDim2.new(1, 0, 0, Metrics.TaskbarHeight - 2),
		Parent = bar,
	})
	Library:Bind(body, "BackgroundColor3", "Background")

	local border = New("Frame", {
		Name = "Border",
		BorderSizePixel = 0,
		Position = UDim2.fromOffset(0, Metrics.TaskbarHeight - 2),
		Size = UDim2.new(1, 0, 0, 1),
		Parent = bar,
	})
	Library:Bind(border, "BackgroundColor3", "Border")

	local outline = New("Frame", {
		Name = "Outline",
		BorderSizePixel = 0,
		Position = UDim2.fromOffset(0, Metrics.TaskbarHeight - 1),
		Size = UDim2.new(1, 0, 0, 1),
		Parent = bar,
	})
	Library:Bind(outline, "BackgroundColor3", "Outline")

	-- Panel chrome used by the compact dock, hidden while in bar mode.
	local panelOuter = New("Frame", {
		Name = "PanelOutline",
		BorderSizePixel = 0,
		Size = UDim2.fromScale(1, 1),
		Visible = false,
		Parent = bar,
	})
	Library:Bind(panelOuter, "BackgroundColor3", "Outline")

	local panelBorder = New("Frame", {
		Name = "PanelBorder",
		BorderSizePixel = 0,
		Position = UDim2.fromOffset(1, 1),
		Size = UDim2.new(1, -2, 1, -2),
		Parent = panelOuter,
	})
	Library:Bind(panelBorder, "BackgroundColor3", "Border")

	local panelBody = New("Frame", {
		Name = "PanelBody",
		BorderSizePixel = 0,
		Position = UDim2.fromOffset(1, 1),
		Size = UDim2.new(1, -2, 1, -2),
		Parent = panelBorder,
	})
	Library:Bind(panelBody, "BackgroundColor3", "Background")

	local row = New("Frame", {
		Name = "Row",
		BackgroundTransparency = 1,
		Position = UDim2.fromOffset(Metrics.SectionPadding, 0),
		Size = UDim2.new(1, -Metrics.SectionPadding, 0, Metrics.TaskbarHeight - 2),
		Parent = body,
	}, {
		New("UIListLayout", {
			FillDirection = Enum.FillDirection.Horizontal,
			VerticalAlignment = Enum.VerticalAlignment.Center,
			SortOrder = Enum.SortOrder.LayoutOrder,
			Padding = UDim.new(0, Metrics.TaskbarPadding),
		}),
	})

	local title = Utils.Text({
		Name = "Title",
		LayoutOrder = 0,
		Size = UDim2.new(0, 0, 0, 16),
		AutomaticSize = Enum.AutomaticSize.X,
		Text = string.format("%s %s", Library.Name, os.date("%d.%m.%y")),
		Parent = row,
	})

	local taskbar: any = {
		Frame = bar,
		Row = row,
		Title = title,
		Buttons = {},
		Body = body,
		Border = border,
		Outline = outline,
		PanelOuter = panelOuter,
		PanelBody = panelBody,
		Layout = row:FindFirstChildOfClass("UIListLayout"),
		Mode = "Bar",
		DragHandle = false,
	}

	--[[
		Compact mode measures the button strip and sizes the dock to it, which is
		what "fit the bar to its contents" means here: the width comes from the
		list layout rather than from the screen.
	]]
	local function fitCompact()
		if taskbar.Mode ~= "Compact" then
			return
		end
		local width = taskbar.Layout and taskbar.Layout.AbsoluteContentSize.X or 0
		bar.Size = UDim2.fromOffset(
			math.max(80, math.ceil(width) + Metrics.SectionPadding * 2 + 4),
			Metrics.TaskbarHeight
		)
	end

	taskbar.Fit = fitCompact

	if taskbar.Layout then
		Library:Connect(taskbar.Layout:GetPropertyChangedSignal("AbsoluteContentSize"), fitCompact)
	end

	function Library:SetTaskbarMode(mode)
		mode = tostring(mode or "Bar")
		if not table.find(TASKBAR_MODES, mode) then
			mode = "Bar"
		end

		taskbar.Mode = mode
		Library.Settings.TaskbarMode = mode

		local compact = mode == "Compact"

		body.Visible = not compact
		border.Visible = not compact
		outline.Visible = not compact
		panelOuter.Visible = compact

		-- The row lives inside whichever chrome is showing.
		row.Parent = compact and panelBody or body
		row.Size = compact and UDim2.new(1, -Metrics.SectionPadding, 1, 0)
			or UDim2.new(1, -Metrics.SectionPadding, 0, Metrics.TaskbarHeight - 2)

		if compact then
			local viewport = Library.ScreenGui.AbsoluteSize
			bar.Position = UDim2.fromOffset(math.floor(viewport.X / 2) - 200, 8)
			fitCompact()

			--[[
				Dragging the dock is what makes compact mode useful, but the
				handle has to sit *below* the panel, not over it.

				Under Sibling ordering the handle's ZIndex places its whole
				subtree, so a handle above the panel swallows every button click.
				Below it, the buttons get their clicks (they are GuiButtons and
				consume input) while empty dock space falls through the plain
				frames onto the handle.
			]]
			if not taskbar.DragHandle then
				local handle = New("TextButton", {
					Name = "DragHandle",
					AutoButtonColor = false,
					BackgroundTransparency = 1,
					Text = "",
					Size = UDim2.fromScale(1, 1),
					ZIndex = 0,
					Parent = bar,
				})
				Utils.Drag(handle, bar, nil, 0)
				taskbar.DragHandle = handle
			end
			taskbar.DragHandle.Visible = true
		else
			bar.Position = UDim2.fromOffset(0, 0)
			bar.Size = UDim2.new(1, 0, 0, Metrics.TaskbarHeight)
			if taskbar.DragHandle then
				taskbar.DragHandle.Visible = false
			end
		end

		return Library
	end

	--[[
		The dock has its own switch, separate from the menu: hiding it leaves
		every window where it is, and the windows have their own switch that
		leaves the dock on screen, so whichever one is showing can bring the
		other back.
	]]
	function Library:SetTaskbarVisible(state)
		state = state and true or false
		Library.Settings.ShowTaskbar = state
		bar.Visible = state
		Library:SyncVisibilityToggles()
		return Library
	end

	function Library:ToggleTaskbar()
		return Library:SetTaskbarVisible(not Library.Settings.ShowTaskbar)
	end

	bar.Visible = Library.Settings.ShowTaskbar ~= false

	-- A key can be bound to the dock like it can to any window.
	table.insert(Library.BindableWindows, {
		Name = "Dock",
		Toggle = function()
			Library:ToggleTaskbar()
		end,
	})
	Library:RefreshBindList()

	-- Keep the clock fresh without a per-frame connection.
	task.spawn(function()
		while not Library.Unloaded and title.Parent do
			title.Text = string.format("%s %s", Library.Name, os.date("%d.%m.%y"))
			task.wait(30)
		end
	end)

	Library.Taskbar = taskbar
	return taskbar
end

function Library:GetTaskbar()
	if not Library.Taskbar then
		CreateTaskbar()
	end
	return Library.Taskbar
end

--[[
	Adds a taskbar entry. Active entries print in the accent colour, inactive
	ones in InactiveTab, matching the tab states in the design.
]]
function Library:TaskbarButton(name, onClick, startActive)
	local taskbar = Library:GetTaskbar()

	local button = New("Frame", {
		Name = name,
		BackgroundTransparency = 1,
		LayoutOrder = #taskbar.Buttons + 1,
		Size = UDim2.fromOffset(40, Metrics.TaskbarButtonHeight),
		Parent = taskbar.Row,
	})

	local _, surfaceBody = Utils.TabSurface({
		Size = UDim2.fromScale(1, 1),
		Parent = button,
	})

	local label = Utils.Text({
		Size = UDim2.fromScale(1, 1),
		TextXAlignment = Enum.TextXAlignment.Center,
		Text = name,
		Parent = surfaceBody,
	})

	-- Width follows the label, as the design's buttons all hug their text.
	Utils.HugWidth(button, label, 8, 20)

	local entry: any = {
		Frame = button,
		Label = label,
		Active = startActive ~= false,
	}

	-- One painter reads the entry's own state, so a repaint can never disagree
	-- with it.
	entry.Painter = Library:Paint(label, "TextColor3", function()
		return entry.Active and Themes.Current.Accent or Themes.Current.InactiveTab
	end, { "Accent", "InactiveTab" })

	function entry:SetActive(active)
		entry.Active = active and true or false
		entry.Painter.Apply()
	end

	local hitbox = Utils.Hitbox(button, 30)
	Library:Connect(hitbox.MouseButton1Click, function()
		if onClick then
			onClick(entry)
		end
	end)

	entry:SetActive(entry.Active)
	table.insert(taskbar.Buttons, entry)

	return entry
end

--// Window ////////////////////////////////////////////////////////////////////

local Window = {}
Window.__index = Window

--[[
	Library:Window({ Name = "tallin", Size = Vector2.new(516, 610) })

	Produces the outlined window from the design: centred title, accent divider,
	a tab strip that appears once the first tab is added, and a content area
	split into two section columns.
]]
function Library:Window(options)
	options = options or {}

	local name = tostring(Field(options, "Name", Library.Name))
	local size = Field(options, "Size", Vector2.new(516, 610))
	if typeof(size) == "UDim2" then
		size = Vector2.new(size.X.Offset, size.Y.Offset)
	end

	local viewport = Camera and Camera.ViewportSize or Vector2.new(1920, 1080)
	local defaultPosition = UDim2.fromOffset(
		math.floor((viewport.X - size.X) / 2),
		math.floor((viewport.Y - size.Y) / 2)
	)

	local frame = New("Frame", {
		Name = name,
		BackgroundTransparency = 1,
		Position = Field(options, "Position", defaultPosition),
		Size = UDim2.fromOffset(size.X, size.Y),
		Visible = Field(options, "Visible", true),
		ZIndex = Library.TopZIndex,
		Parent = Library.Holder,
	})

	local _, body = Utils.Panel({
		Size = UDim2.fromScale(1, 1),
		Parent = frame,
	})

	local titleLabel = Utils.Text({
		Name = "Title",
		Size = UDim2.new(.2, 0, 0, Metrics.WindowTitleHeight - 4),
		TextXAlignment = Enum.TextXAlignment.Center,
		Text = name,
		Parent = body,
	})

	Utils.Divider(body, Metrics.WindowTitleHeight - 2)

	-- Drag handle covers the title strip only.
	local dragHandle = New("TextButton", {
		Name = "DragHandle",
		BackgroundTransparency = 1,
		Text = "",
		AutoButtonColor = false,
		Size = UDim2.new(1, 0, 0, Metrics.WindowTitleHeight),
		ZIndex = 10,
		Parent = body,
	})
	Utils.Drag(dragHandle, frame)

	local tabRow = New("Frame", {
		Name = "TabRow",
		BackgroundTransparency = 1,
		Position = UDim2.fromOffset(Metrics.SectionPadding - 2, Metrics.WindowTitleHeight + 2),
		Size = UDim2.new(1, -(Metrics.SectionPadding - 2) * 2, 0, Metrics.TabHeight),
		Visible = false,
		Parent = body,
	}, {
		New("UIListLayout", {
			FillDirection = Enum.FillDirection.Horizontal,
			SortOrder = Enum.SortOrder.LayoutOrder,
			-- -1 makes adjacent tab outlines overlap into a single shared edge.
			Padding = UDim.new(0, -1),
		}),
	})

	local content = New("Frame", {
		Name = "Content",
		BackgroundTransparency = 1,
		Position = UDim2.fromOffset(0, Metrics.WindowTitleHeight + 2),
		Size = UDim2.new(1, 0, 1, -(Metrics.WindowTitleHeight + 2) - 4),
		Parent = body,
	})

	local window = setmetatable({
		Name = name,
		Frame = frame,
		Body = body,
		Title = titleLabel,
		TabRow = tabRow,
		Content = content,
		Tabs = {},
		ActiveTab = nil,
		Library = Library,
	}, Window)

	--[[
		Resize grip in the bottom right corner. Resizing re-runs the layout pass,
		so tab widths and section columns stay on whole pixels at any size.
	]]
	if Field(options, "Resizable", true) then
		local minSize = Field(options, "MinSize", Vector2.new(240, 150))

		local grip = New("TextButton", {
			Name = "Resize",
			AnchorPoint = Vector2.new(1, 1),
			AutoButtonColor = false,
			BackgroundTransparency = 1,
			Text = "",
			Position = UDim2.new(1, 0, 1, 0),
			Size = UDim2.fromOffset(12, 12),
			ZIndex = 40,
			Parent = body,
		})

		-- No corner marking: the grip is an invisible hit area only.
		local resizing = false
		local startInput, startSize

		Library:Connect(grip.InputBegan, function(input)
			if input.UserInputType ~= Enum.UserInputType.MouseButton1
				and input.UserInputType ~= Enum.UserInputType.Touch then
				return
			end
			resizing = true
			startInput = input.Position
			startSize = Vector2.new(frame.Size.X.Offset, frame.Size.Y.Offset)
			Library:BringToFront(frame)
		end)

		Library:Connect(UserInputService.InputChanged, function(input)
			if not resizing then
				return
			end
			if input.UserInputType ~= Enum.UserInputType.MouseMovement
				and input.UserInputType ~= Enum.UserInputType.Touch then
				return
			end

			local delta = input.Position - startInput
			local width = math.max(minSize.X, math.floor(startSize.X + delta.X))
			local height = math.max(minSize.Y, math.floor(startSize.Y + delta.Y))

			frame.Size = UDim2.fromOffset(width, height)
			-- Hand sizing wins over any automatic sizing the window does.
			window.UserResized = true
			window:UpdateLayout()
		end)

		Library:Connect(UserInputService.InputEnded, function(input)
			if input.UserInputType == Enum.UserInputType.MouseButton1
				or input.UserInputType == Enum.UserInputType.Touch then
				resizing = false
			end
		end)

		window.Grip = grip
	end

	--[[
		Clicking anywhere in the window raises it above the others. A top most
		window keeps a fixed high ZIndex instead, so it always stays readable
		above the rest of the menu.
	]]
	local topMost = Field(options, "TopMost", false) and true or false
	window.TopMost = topMost

	if topMost then
		-- Above the windows, the taskbar and any popup they open.
		frame.ZIndex = Library.ZLayers.TopMost
	end

	local raise = Utils.Hitbox(body, 0)
	raise.Modal = false
	Library:Connect(raise.MouseButton1Down, function()
		if not topMost then
			Library:BringToFront(frame)
		end
	end)

	if Field(options, "Taskbar", true) then
		window.TaskbarEntry = Library:TaskbarButton(name, function()
			window:Toggle()
		end, frame.Visible)

		-- Anything with a taskbar button can also be given a keybind.
		table.insert(Library.BindableWindows, {
			Name = name,
			Toggle = function()
				window:Toggle()
			end,
		})
		Library:RefreshBindList()
	end

	table.insert(Library.Windows, window)
	Library:BringToFront(frame)

	return window
end

function Window:SetVisible(visible)
	self.Frame.Visible = visible and true or false
	--[[
		Shown by hand: it is no longer waiting for the group switch, and the
		group counts as on again, so the switch in the settings window does not
		sit at off while a window is open.
	]]
	if self.Frame.Visible then
		self.HiddenByGroup = false
		if Library.Settings.ShowWindows == false then
			Library.Settings.ShowWindows = true
			Library:SyncVisibilityToggles()
		end
	end
	if self.TaskbarEntry then
		self.TaskbarEntry:SetActive(self.Frame.Visible)
	end
	if self.Frame.Visible and not self.TopMost then
		Library:BringToFront(self.Frame)
	end
	return self
end

function Window:Toggle()
	return self:SetVisible(not self.Frame.Visible)
end

function Window:Show()
	return self:SetVisible(true)
end

function Window:Hide()
	return self:SetVisible(false)
end

function Window:SetTitle(text)
	self.Title.Text = tostring(text)
	return self
end

--[[
	The windows as a group, the other half of the pair with the dock. Only the
	windows that were open at the time are remembered, so switching back does
	not open something the user had closed.
]]
function Library:SetWindowsVisible(state)
	state = state and true or false
	Library.Settings.ShowWindows = state

	for _, window in Library.Windows do
		if state then
			if window.HiddenByGroup then
				window:SetVisible(true)
			end
		elseif window.Frame.Visible then
			window:SetVisible(false)
			window.HiddenByGroup = true
		end
	end

	Library:SyncVisibilityToggles()
	return Library
end

function Library:ToggleWindows()
	return Library:SetWindowsVisible(not Library.Settings.ShowWindows)
end

table.insert(Library.BindableWindows, {
	Name = "Windows",
	Toggle = function()
		Library:ToggleWindows()
	end,
})

--// Per-picker colour animation ///////////////////////////////////////////////

--[[
	Colour pickers can animate themselves. One shared frame loop drives every
	animated picker, so a menu full of them still costs a single connection.
]]
Library.AnimatedPickers = {}
Library.PickerLoop = false

--[[
	Animation modes.

	Rainbow, Fade, Breathe and Pulse work from the picker's own colour. Lerp and
	Blink use a second colour as well, set by the swatch next to the mode.
]]
local PICKER_ANIMATIONS = { "Off", "Rainbow", "Fade", "Breathe", "Pulse", "Lerp", "Blink" }
Library.PickerAnimations = PICKER_ANIMATIONS

-- Modes that need the second colour.
local TWO_COLOUR_MODES = { Lerp = true, Blink = true }
Library.TwoColourModes = TWO_COLOUR_MODES

local function StartPickerLoop()
	if Library.PickerLoop then
		return
	end

	Library.PickerLoop = Library:Connect(RunService.RenderStepped, function()
		if Library.Unloaded then
			return
		end

		for _, picker in Library.AnimatedPickers do
			local mode = picker.Animation
			if mode and mode ~= "Off" then
				local clock = os.clock() * (picker.AnimationSpeed or 1)
				local base = typeof(picker.AnimationBase) == "Color3" and picker.AnimationBase
					or picker.Value
				local hue, saturation, value = base:ToHSV()
				local color

				if mode == "Rainbow" then
					color = Color3.fromHSV((clock * 0.12) % 1, saturation > 0.05 and saturation or 0.6, value)
				elseif mode == "Fade" then
					local alpha = (math.sin(clock * 2) + 1) / 2
					color = Color3.fromHSV(hue, saturation, Utils.Lerp(0.3, value, alpha))
				elseif mode == "Breathe" then
					local alpha = (math.sin(clock * 1.2) + 1) / 2
					color = Color3.fromHSV(
						(hue + Utils.Lerp(-0.08, 0.08, alpha)) % 1,
						Utils.Lerp(saturation * 0.4, saturation, alpha),
						value
					)
				elseif mode == "Pulse" then
					-- Hard on/off blink rather than a smooth ramp.
					local on = math.floor(clock * 2) % 2 == 0
					color = on and base or Utils.Multiply(base, 0.35)
				elseif mode == "Lerp" then
					-- Smooth travel between the two colours.
					local other = typeof(picker.ColourB) == "Color3" and picker.ColourB
						or Utils.Multiply(base, 0.4)
					local alpha = (math.sin(clock * 2) + 1) / 2
					color = base:Lerp(other, alpha)
				elseif mode == "Blink" then
					-- Hard alternation between the two colours.
					local other = typeof(picker.ColourB) == "Color3" and picker.ColourB
						or Utils.Multiply(base, 0.4)
					color = math.floor(clock * 2) % 2 == 0 and base or other
				end

				if color then
					picker.SetAnimated(color)
				end
			end
		end
	end)
end

Library.StartPickerLoop = StartPickerLoop

--// Containers ////////////////////////////////////////////////////////////////

--[[
	Anything that can hold elements: a section, or a folding group nested inside
	one. Every element constructor lives on this prototype, so sections and
	groups expose an identical API at any nesting depth.
]]
local Container = {}
Container.__index = Container
Library.Container = Container

--[[
	Adds a row to the container's list layout. Layout orders step by ten so a
	folding group can be slotted in between a toggle and whatever follows it.
]]
function Container:Row(height, layoutOrder)
	self.NextOrder = (self.NextOrder or 0) + 10

	local row = New("Frame", {
		Name = "Row",
		BackgroundTransparency = 1,
		LayoutOrder = layoutOrder or self.NextOrder,
		Size = UDim2.new(1, 0, 0, height),
		Parent = self.Content,
	})

	-- Remembered so a font change can give it the headroom it needs.
	Utils.TrackRow(row, height)

	return row
end

-- Registers an element so configs and the theme window can find it by flag.
function Container:Register(element, flag)
	table.insert(self.Elements, element)

	if flag ~= nil and flag ~= "" then
		element.Flag = flag
		Library.Elements[flag] = element
	end

	-- A group that just gained its first element may need to become visible.
	if self.SetOpen then
		self:SetOpen(self.IsOpen)
	end

	return element
end

--// Tab ///////////////////////////////////////////////////////////////////////

local Tab = {}
Tab.__index = Tab

local function BuildColumn(parent, side)
	local column = New("ScrollingFrame", {
		Name = side,
		Active = false,
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		ClipsDescendants = true,
		-- Thin accent scrollbar so a long section reads as scrollable.
		ScrollBarThickness = 2,
		ScrollBarImageTransparency = 0.35,
		ScrollingDirection = Enum.ScrollingDirection.Y,
		CanvasSize = UDim2.new(),
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
		-- Whole pixel geometry, assigned by Tab:UpdateColumns.
		Size = UDim2.fromOffset(250, 0),
		Position = UDim2.fromOffset(side == "Left" and 4 or 258, 0),
		Parent = parent,
	}, {
		New("UIListLayout", {
			FillDirection = Enum.FillDirection.Vertical,
			SortOrder = Enum.SortOrder.LayoutOrder,
			Padding = UDim.new(0, Metrics.SectionPadding),
		}),
	})

	return column
end

--[[
	Window:Tab({ Name = "Combat" })

	Tab buttons split the strip evenly, matching the four equal buttons in the
	design. The first tab added becomes the active one.
]]
function Window:Tab(options)
	options = options or {}
	local name = tostring(Field(options, "Name", "tab"))

	local button = New("Frame", {
		Name = name,
		BackgroundTransparency = 1,
		LayoutOrder = #self.Tabs + 1,
		Size = UDim2.new(1, 0, 1, 0),
		Parent = self.TabRow,
	})

	local _, buttonBody = Utils.TabSurface({
		Size = UDim2.fromScale(1, 1),
		Parent = button,
	})

	local label = Utils.Text({
		Size = UDim2.fromScale(1, 1),
		TextXAlignment = Enum.TextXAlignment.Center,
		Text = name,
		Parent = buttonBody,
	})

	local page = New("Frame", {
		Name = name .. "Page",
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 1),
		Visible = false,
		Parent = self.Content,
	})

	local tab = setmetatable({
		Name = name,
		Window = self,
		Button = button,
		Label = label,
		Page = page,
		Active = false,
		Columns = {
			Left = BuildColumn(page, "Left"),
			Right = BuildColumn(page, "Right"),
		},
		Sections = {},
	}, Tab)

	tab.Painter = Library:Paint(label, "TextColor3", function()
		return tab.Active and Themes.Current.Accent or Themes.Current.InactiveTab
	end, { "Accent", "InactiveTab" })

	local hitbox = Utils.Hitbox(button, 30)
	Library:Connect(hitbox.MouseButton1Click, function()
		self:SelectTab(tab)
	end)

	-- Keep the columns pixel exact while the window is being resized.
	Library:Connect(page:GetPropertyChangedSignal("AbsoluteSize"), function()
		tab:UpdateColumns()
	end)

	table.insert(self.Tabs, tab)
	self:UpdateLayout()

	if #self.Tabs == 1 then
		self:SelectTab(tab)
	else
		tab:SetActive(false)
	end

	return tab
end

function Window:UpdateLayout()
	local count = #self.Tabs
	local hasTabs = count > 0

	self.TabRow.Visible = hasTabs

	--[[
		Whole pixel tab widths.

		A fractional share (four tabs across 506px is 126.5 each) puts a button on
		a half pixel and Roblox then resamples everything inside it, which is what
		makes the labels look soft. The leftover pixels are handed out one per
		button instead of being spread as a fraction.
	]]
	-- Guarded: windows without tabs (Lua, Configuration) also run this on resize.
	if hasTabs then
		local inset = (Metrics.SectionPadding - 2) * 2
		local total = math.max(count, self.Frame.Size.X.Offset - 2 - inset)
		local base = math.floor(total / count)
		local remainder = total - base * count
		local cursor = 0

		for index, tab in self.Tabs do
			local width = base + (index <= remainder and 1 or 0)
			tab.Button.Size = UDim2.fromOffset(width, Metrics.TabHeight)
			tab.Button.Position = UDim2.fromOffset(cursor, 0)
			cursor += width
		end
	end

	local top = Metrics.WindowTitleHeight + 2
	if hasTabs then
		top += Metrics.TabHeight + 4
	end

	self.Content.Position = UDim2.fromOffset(0, top)
	self.Content.Size = UDim2.new(1, 0, 1, -top - 4)

	for _, tab in self.Tabs do
		tab:UpdateColumns()
	end

	return self
end

function Window:SelectTab(tab)
	for _, candidate in self.Tabs do
		candidate:SetActive(candidate == tab)
	end
	self.ActiveTab = tab
	return self
end

function Tab:SetActive(active)
	self.Active = active and true or false
	self.Page.Visible = self.Active
	self.Painter.Apply()
	return self
end

function Tab:Select()
	return self.Window:SelectTab(self)
end

--[[
	Column geometry in whole pixels. Called on every layout pass and whenever the
	window is resized, so the two section columns always split the page evenly
	without landing on a half pixel.
]]
function Tab:UpdateColumns()
	local width = self.Page.AbsoluteSize.X
	if width <= 0 then
		width = self.Window.Frame.Size.X.Offset - 4
	end

	local columnWidth = math.max(80, math.floor((width - 12) / 2))

	self.Columns.Left.Position = UDim2.fromOffset(4, 0)
	self.Columns.Left.Size = UDim2.new(0, columnWidth, 1, 0)

	self.Columns.Right.Position = UDim2.fromOffset(4 + columnWidth + 4, 0)
	self.Columns.Right.Size = UDim2.new(0, columnWidth, 1, 0)

	return self
end

--// Player list ///////////////////////////////////////////////////////////////

--[[
	Tab:PlayerList()

	A full width table of everyone in the server: search box, refresh, and the
	columns Name, UserId and Priority. Selecting a row fills the panel underneath
	with that player's avatar and details and lets their priority be set.

	Priorities are kept by user id in list.Priorities, and OnPriority reports
	changes so a cheat can act on them.
]]
local PLAYER_PRIORITIES = { "Friendly", "Enemy", "Neutral" }
Library.PlayerPriorities = PLAYER_PRIORITIES

--[[
	Thumbnails are fetched once per user and kept, since GetUserThumbnailAsync is
	a web call: without a cache every list refresh would re-request the lot and
	the rows would flicker as they came back.
]]
Library.AvatarCache = {}

function Library:GetAvatar(userId, callback)
	local cached = Library.AvatarCache[userId]
	if cached then
		if callback then
			callback(cached)
		end
		return cached
	end

	task.spawn(function()
		local ok, url = pcall(function()
			return Players:GetUserThumbnailAsync(
				userId,
				Enum.ThumbnailType.HeadShot,
				Enum.ThumbnailSize.Size420x420
			)
		end)

		if ok and url then
			Library.AvatarCache[userId] = url
			if callback then
				callback(url)
			end
		end
	end)

	return nil
end

-- Warms the cache for everyone currently in the server.
function Library:PreloadAvatars()
	for _, player in Players:GetPlayers() do
		Library:GetAvatar(player.UserId)
	end
end

-- Forward declaration: the shared button builder is defined with the elements,
-- further down, but the player list needs it for its Refresh button.
local BuildButton

function Tab:PlayerList(options)
	options = options or {}

	local page = self.Page
	-- Tall enough for a row thumbnail.
	local rowHeight = 18

	-- The list takes the whole page, so the usual two columns are not used.
	local frame = New("Frame", {
		Name = "PlayerList",
		BackgroundTransparency = 1,
		Position = UDim2.fromOffset(4, 0),
		Size = UDim2.new(1, -8, 1, 0),
		Parent = page,
	})

	--[[
		Search row plus refresh, given three pixels over the standard field height:
		it carries a button as well as an input, and at the bare height both sat
		tight against the panel edges.
	]]
	local searchHeight = Metrics.TextboxHeight + 3

	local searchRow = New("Frame", {
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0, searchHeight),
		Parent = frame,
	})

	local _, searchBody = Utils.Raised({
		Size = UDim2.new(1, -64, 1, 0),
		Parent = searchRow,
	})

	local search = Utils.Input({
		Position = UDim2.fromOffset(3, 0),
		Size = UDim2.new(1, -6, 1, 0),
		Text = "",
		PlaceholderText = "Search Here",
		Parent = searchBody,
	})
	Library:Bind(search, "PlaceholderColor3", "InactiveButtonText")

	local refreshHolder = New("Frame", {
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.fromScale(1, 0),
		Size = UDim2.fromOffset(60, searchHeight),
		Parent = searchRow,
	})

	--// Column headers.
	local headerRow = New("Frame", {
		BackgroundTransparency = 1,
		Position = UDim2.fromOffset(0, searchHeight + 3),
		Size = UDim2.new(1, 0, 0, rowHeight),
		Parent = frame,
	})

	--[[
		One description of the columns, used for both the headers and the cells.
		Keeping a single source for the geometry is what stops the two from
		drifting apart by a few pixels.
	]]
	--[[
		Column bands, with the same inset on every one so headers and cells share
		an edge. Ids are right aligned: centred numbers of differing length read as
		ragged, which is what made the table look crooked.
	]]
	local pad = 4
	local avatarSize = rowHeight - 2

	--[[
		Column bands. The first one leaves room for a row thumbnail, and the extra
		columns exist because the table has the width to spare: an id alone left
		two thirds of the row empty.
	]]
	local columns = {
		{ Key = "Name", Start = 0.00, Width = 0.34, Align = Enum.TextXAlignment.Left },
		{ Key = "UserId", Start = 0.34, Width = 0.20, Align = Enum.TextXAlignment.Right },
		{ Key = "Team", Start = 0.54, Width = 0.16, Align = Enum.TextXAlignment.Center },
		{ Key = "Distance", Start = 0.70, Width = 0.13, Align = Enum.TextXAlignment.Right },
		{ Key = "Priority", Start = 0.83, Width = 0.17, Align = Enum.TextXAlignment.Right },
	}

	local function columnPosition(column, indent)
		return UDim2.new(column.Start, pad + (indent or 0), 0, 0)
	end

	local function columnSize(column, indent)
		return UDim2.new(column.Width, -pad * 2 - (indent or 0), 1, 0)
	end

	-- The name column is indented past its thumbnail.
	local nameIndent = avatarSize + 3

	for _, column in columns do
		Utils.Text({
			Position = columnPosition(column),
			Size = columnSize(column),
			Text = column.Key,
			TextXAlignment = column.Align,
			ThemeKey = "SectionNameText",
			Parent = headerRow,
		})
	end

	--[[
		No separator under the headers: the list panel below already draws its own
		outline and border, and a rule on top of that reads as one thick strip.
	]]

	--// The table itself.
	-- Tall enough for five detail lines and a square avatar beside them.
	local detailHeight = 78
	local listTop = searchHeight + 3 + rowHeight

	local _, listBody = Utils.Panel({
		Position = UDim2.fromOffset(0, listTop),
		Size = UDim2.new(1, 0, 1, -(listTop + detailHeight + 6)),
		Parent = frame,
	})
	listBody.ClipsDescendants = true

	local rows = New("ScrollingFrame", {
		Active = true,
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Size = UDim2.fromScale(1, 1),
		CanvasSize = UDim2.new(),
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
		ScrollBarThickness = 2,
		ScrollBarImageTransparency = 0.25,
		Parent = listBody,
	}, {
		New("UIListLayout", {
			FillDirection = Enum.FillDirection.Vertical,
			SortOrder = Enum.SortOrder.LayoutOrder,
			Padding = UDim.new(0, 0),
		}),
	})
	Library:Bind(rows, "ScrollBarImageColor3", "Accent")

	--// Detail panel.
	local _, detailBody = Utils.Panel({
		AnchorPoint = Vector2.new(0, 1),
		Position = UDim2.new(0, 0, 1, 0),
		Size = UDim2.new(1, 0, 0, detailHeight),
		Parent = frame,
	})

	--[[
		Detail avatar. The panel clips, and the image fills it exactly with Fit
		rather than Crop: a cropped headshot in a slightly different aspect spills
		past the frame, which is what made it look like it was falling out.
	]]
	local _, avatarBody = Utils.Panel({
		Position = UDim2.fromOffset(4, 4),
		Size = UDim2.fromOffset(detailHeight - 8, detailHeight - 8),
		Parent = detailBody,
	})
	avatarBody.ClipsDescendants = true

	local avatar = New("ImageLabel", {
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Size = UDim2.fromScale(1, 1),
		ScaleType = Enum.ScaleType.Fit,
		Parent = avatarBody,
	})

	--[[
		Caption and value are separate labels on a fixed grid: a single formatted
		string leaves the values ragged, since the captions differ in width.
	]]
	--[[
		Captions are right aligned against a single column edge and the values
		start just past it, so all three values share one left edge instead of
		stepping in and out with the caption widths.
	]]
	local captionLeft = detailHeight + 2
	local captionRight = captionLeft + 72
	local valueLeft = captionRight + 6
	local detailLines = {}

	for index, caption in { "Name", "DisplayName", "UserId", "Team", "Health" } do
		local top = 4 + (index - 1) * 14

		Utils.Text({
			Position = UDim2.fromOffset(captionLeft, top),
			Size = UDim2.fromOffset(captionRight - captionLeft, 12),
			TextSize = Metrics.TextSmall,
			TextXAlignment = Enum.TextXAlignment.Right,
			Text = caption,
			ThemeKey = "InactiveButtonText",
			Parent = detailBody,
		})

		detailLines[caption] = Utils.Text({
			Position = UDim2.fromOffset(valueLeft, top),
			Size = UDim2.new(0.34, 0, 0, 12),
			TextSize = Metrics.TextSmall,
			Text = "-",
			TextTruncate = Enum.TextTruncate.AtEnd,
			Parent = detailBody,
		})
	end

	-- Sits in the Priority column's band, so it lines up with the table above.
	local priorityHolder = New("Frame", {
		BackgroundTransparency = 1,
		Position = UDim2.new(0.62, pad, 0, 5),
		Size = UDim2.new(0.38, -pad * 2, 0, 46),
		Parent = detailBody,
	})

	local priorityContainer = Library:MakeContainer(priorityHolder)

	--// State.
	local list: any = {
		Frame = frame,
		Rows = rows,
		Avatar = avatar,
		Selected = false,
		Priorities = {},
		-- Labels that show live values, refreshed on a timer.
		DistanceLabels = {},
		OnPriority = Field(options, "OnPriority", nil),
		OnSelect = Field(options, "OnSelect", nil),
	}

	local priorityDropdown = priorityContainer:Dropdown({
		Name = "Priority",
		Options = PLAYER_PRIORITIES,
		Default = "Neutral",
		MaxVisible = 5,
		Callback = function(choice)
			local player = list.Selected
			if not player then
				return
			end

			list.Priorities[player.UserId] = choice
			if list.OnPriority then
				pcall(list.OnPriority, player, choice)
			end
			list:Refresh()
		end,
	})

	function list:GetPriority(player)
		if typeof(player) == "Instance" then
			return list.Priorities[(player :: any).UserId] or "Neutral"
		end
		-- Also accepts a name, which is how these lists are usually queried.
		for _, candidate in Players:GetPlayers() do
			if candidate.Name == player or candidate.DisplayName == player then
				return list.Priorities[candidate.UserId] or "Neutral"
			end
		end
		return "Neutral"
	end

	function list:Select(player)
		list.Selected = player

		detailLines.Name.Text = player.Name
		detailLines.DisplayName.Text = player.DisplayName
		detailLines.UserId.Text = tostring(player.UserId)
		detailLines.Team.Text = player.Team and player.Team.Name or "-"

		priorityDropdown:Set(list.Priorities[player.UserId] or "Neutral", true)

		-- Straight from the cache when it is warm, which it normally is.
		local cached = Library.AvatarCache[player.UserId]
		avatar.Image = cached or ""

		if not cached then
			Library:GetAvatar(player.UserId, function(url)
				if avatar.Parent and list.Selected == player then
					avatar.Image = url
				end
			end)
		end

		if list.OnSelect then
			pcall(list.OnSelect, player)
		end

		list:Refresh()
	end

	--[[
		Rebuilt from scratch on every refresh. A server list is short and changes
		rarely, so reusing rows would cost more complexity than it saves.
	]]
	function list:Refresh()
		if not rows.Parent then
			return
		end

		for _, child in rows:GetChildren() do
			if child:IsA("TextButton") then
				child:Destroy()
			end
		end

		table.clear(list.DistanceLabels)

		local query = tostring(search.Text):lower()

		for index, player in Players:GetPlayers() do
			local name = player.Name

			if query ~= "" and not name:lower():find(query, 1, true) then
				continue
			end

			local selected = list.Selected == player
			local priority = player == LocalPlayer and "LocalPlayer"
				or (list.Priorities[player.UserId] or "Neutral")

			local row = New("TextButton", {
				Name = name,
				AutoButtonColor = false,
				BackgroundColor3 = Color3.new(1, 1, 1),
				BackgroundTransparency = 1,
				BorderSizePixel = 0,
				LayoutOrder = index,
				Size = UDim2.new(1, 0, 0, rowHeight),
				Text = "",
				Parent = rows,
			})

			Library:Paint(row, "BackgroundColor3", function()
				return Themes.Current.Accent
			end, { "Accent" })
			row.BackgroundTransparency = 1
			if list.Selected == player then
				Library:Tween(row, { BackgroundTransparency = 0.88 }, 0.1, "Quad")
			end

			--[[
				Row thumbnail. Served from the cache when it is already there, so
				scrolling and refreshing do not re-request anything.
			]]
			local thumb = New("ImageLabel", {
				Name = "Avatar",
				BackgroundTransparency = 1,
				BorderSizePixel = 0,
				Position = UDim2.new(0, pad, 0.5, 0),
				AnchorPoint = Vector2.new(0, 0.5),
				Size = UDim2.fromOffset(avatarSize, avatarSize),
				ScaleType = Enum.ScaleType.Fit,
				Image = Library.AvatarCache[player.UserId] or "",
				Parent = row,
			})

			if not Library.AvatarCache[player.UserId] then
				Library:GetAvatar(player.UserId, function(url)
					if thumb.Parent then
						thumb.Image = url
					end
				end)
			end

			local nameLabel = Utils.Text({
				Position = columnPosition(columns[1], nameIndent),
				Size = columnSize(columns[1], nameIndent),
				Text = name,
				TextXAlignment = columns[1].Align,
				TextTruncate = Enum.TextTruncate.AtEnd,
				Parent = row,
			})

			Library:Paint(nameLabel, "TextColor3", function()
				if player == LocalPlayer then
					return Themes.Current.Accent
				end
				return list.Selected == player and Themes.Current.TextColor
					or Themes.Current.InactiveButtonText
			end, { "Accent", "TextColor", "InactiveButtonText" })

			Utils.Text({
				Position = columnPosition(columns[2]),
				Size = columnSize(columns[2]),
				TextXAlignment = columns[2].Align,
				Text = tostring(player.UserId),
				ThemeKey = "InactiveButtonText",
				Parent = row,
			})

			Utils.Text({
				Position = columnPosition(columns[3]),
				Size = columnSize(columns[3]),
				TextXAlignment = columns[3].Align,
				Text = player.Team and player.Team.Name or "-",
				TextTruncate = Enum.TextTruncate.AtEnd,
				ThemeKey = "InactiveButtonText",
				Parent = row,
			})

			-- Distance is live, so it gets its own label and a painter free
			-- refresher rather than being baked in at build time.
			local distanceLabel = Utils.Text({
				Position = columnPosition(columns[4]),
				Size = columnSize(columns[4]),
				TextXAlignment = columns[4].Align,
				Text = "-",
				ThemeKey = "InactiveButtonText",
				Parent = row,
			})

			table.insert(list.DistanceLabels, { Label = distanceLabel, Player = player })

			local priorityLabel = Utils.Text({
				Position = columnPosition(columns[5]),
				Size = columnSize(columns[5]),
				TextXAlignment = columns[5].Align,
				Text = priority,
				Parent = row,
			})

			-- Friendly and enemy pick up the risk tints from the theme.
			-- Friendly green, enemy yellow, both their own theme keys.
			Library:Paint(priorityLabel, "TextColor3", function()
				if priority == "Enemy" then
					return Themes.Current.PriorityEnemy
				elseif priority == "Friendly" then
					return Themes.Current.PriorityFriendly
				elseif priority == "LocalPlayer" then
					return Themes.Current.DisabledText
				end
				return Themes.Current.InactiveButtonText
			end, { "PriorityEnemy", "PriorityFriendly", "DisabledText", "InactiveButtonText" })

			Library:Connect(row.MouseButton1Click, function()
				list:Select(player)
			end)

			if selected then
				list.Selected = player
			end
		end
	end

	-- Refresh button, built with the shared button so it themes like the rest.
	BuildButton(refreshHolder, {
		Name = "Refresh",
		Callback = function()
			list:Refresh()
		end,
	})

	Library:Connect(search:GetPropertyChangedSignal("Text"), function()
		list:Refresh()
	end)

	Library:Connect(Players.PlayerAdded, function()
		list:Refresh()
	end)
	Library:Connect(Players.PlayerRemoving, function()
		list:Refresh()
	end)

	--[[
		Live values: the distance column and the selected player's health. Both
		come from the character, which appears and disappears, so they are polled
		rather than bound.
	]]
	local function refreshLive()
		local origin = LocalPlayer.Character
			and LocalPlayer.Character:FindFirstChild("HumanoidRootPart")

		for _, entry in list.DistanceLabels do
			local label, player = entry.Label, entry.Player

			if not label.Parent then
				continue
			end

			if player == LocalPlayer then
				label.Text = "-"
				continue
			end

			local root = player.Character and player.Character:FindFirstChild("HumanoidRootPart")
			if origin and root then
				label.Text = tostring(math.floor((root.Position - origin.Position).Magnitude))
			else
				label.Text = "-"
			end
		end

		local selected = list.Selected
		if selected and detailLines.Health then
			local humanoid = selected.Character
				and selected.Character:FindFirstChildOfClass("Humanoid")

			if humanoid then
				detailLines.Health.Text =
					string.format("%d / %d", math.floor(humanoid.Health), math.floor(humanoid.MaxHealth))
			else
				detailLines.Health.Text = "-"
			end
		end
	end

	task.spawn(function()
		while not Library.Unloaded and frame.Parent do
			refreshLive()
			task.wait(0.5)
		end
	end)

	-- Warm the thumbnail cache before the first paint.
	Library:PreloadAvatars()

	list:Refresh()
	self.PlayerListRef = list

	return list
end

--// Section ///////////////////////////////////////////////////////////////////

--[[
	Tab:Section({ Name = "Aimbot", Side = "Left", Size = 200 })

	Outlined panel with a gradient title strip, a 1px rule under it and a
	gradient body. Height follows its contents unless Size is given.
]]
function Tab:Section(options)
	options = options or {}

	local name = Field(options, "Name", "")
	local side = tostring(Field(options, "Side", "Left"))
	side = side:lower() == "right" and "Right" or "Left"

	local fixedHeight = tonumber(Field(options, "Size", nil))
	local hasHeader = name ~= nil and tostring(name) ~= ""
	local headerHeight = hasHeader and Metrics.SectionHeaderHeight + 1 or 0

	local column = self.Columns[side]

	local frame = New("Frame", {
		Name = tostring(name) ~= "" and tostring(name) or "Section",
		BackgroundTransparency = 1,
		LayoutOrder = #column:GetChildren(),
		Size = UDim2.new(1, 0, 0, fixedHeight or (headerHeight + 8)),
		Parent = column,
	})

	local _, body = Utils.Surface({
		Size = UDim2.fromScale(1, 1),
		Parent = frame,
	}, "SectionTop", "SectionBottom")

	local headerLabel
	if hasHeader then
		local header = New("Frame", {
			Name = "Header",
			BorderSizePixel = 0,
			BackgroundColor3 = Color3.new(1, 1, 1),
			Size = UDim2.new(1, 0, 0, Metrics.SectionHeaderHeight),
			Parent = body,
		})

		local headerGradient = Utils.Gradient(
			header,
			Themes.Current.SectionHeaderTop,
			Themes.Current.SectionHeaderBottom
		)
		Library:Bind(headerGradient, "Color", "SectionHeaderTop", function(top)
			return ColorSequence.new(top, Themes.Current.SectionHeaderBottom)
		end)
		Library:Bind(headerGradient, "Color", "SectionHeaderBottom", function(bottom)
			return ColorSequence.new(Themes.Current.SectionHeaderTop, bottom)
		end)

		headerLabel = Utils.Text({
			Position = UDim2.fromOffset(2, 0),
			Size = UDim2.new(1, -4, 0, 0),
			Text = tostring(name),
			ThemeKey = "SectionNameText",
			Parent = header,
		})

		local rule = New("Frame", {
			Name = "Rule",
			BorderSizePixel = 0,
			Position = UDim2.fromOffset(0, Metrics.SectionHeaderHeight),
			Size = UDim2.new(1, 0, 0, 1),
			Parent = body,
		})
		Library:Bind(rule, "BackgroundColor3", "Border")
	end

	-- Clipped, so nothing can draw outside the panel even if a row overflows.
	body.ClipsDescendants = true

	local content = New("Frame", {
		Name = "Content",
		BackgroundTransparency = 1,
		Position = UDim2.fromOffset(2, headerHeight + 2),
		Size = UDim2.new(1, -4, 1, -(headerHeight + 4)),
		Parent = body,
	}, {
		New("UIListLayout", {
			FillDirection = Enum.FillDirection.Vertical,
			SortOrder = Enum.SortOrder.LayoutOrder,
			Padding = UDim.new(0, Metrics.RowGap),
		}),
	})

	local layout = content:FindFirstChildOfClass("UIListLayout")

	local section = setmetatable({
		Name = tostring(name),
		Window = self.Window,
		Tab = self,
		Side = side,
		Frame = frame,
		Body = body,
		Header = headerLabel,
		Content = content,
		Layout = layout,
		Elements = {},
		Depth = 0,
		FixedHeight = fixedHeight,
	}, Container)

	--[[
		Grow with the contents unless the caller pinned a height.

		Two pixels more than the contents measure: the text outline is drawn just
		outside the glyph box, so a section sized exactly to its rows lets the
		outline of the last one bleed over the panel edge.
	]]
	if not fixedHeight then
		local function resize()
			frame.Size = UDim2.new(1, 0, 0, headerHeight + layout.AbsoluteContentSize.Y + 8)
		end
		Library:Connect(layout:GetPropertyChangedSignal("AbsoluteContentSize"), resize)
		resize()
	end

	table.insert(self.Sections, section)
	return section
end

--[[
	Wraps any frame in a container, so the element constructors can be used
	outside a section: the colour picker's own animation controls are built this
	way, as are the built-in windows.
]]
function Library:MakeContainer(parent, gap)
	local content = New("Frame", {
		Name = "Content",
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 1),
		Parent = parent,
	}, {
		New("UIListLayout", {
			FillDirection = Enum.FillDirection.Vertical,
			SortOrder = Enum.SortOrder.LayoutOrder,
			Padding = UDim.new(0, gap or Metrics.RowGap),
		}),
	})

	return setmetatable({
		Name = "Container",
		Frame = parent,
		Content = content,
		Layout = content:FindFirstChildOfClass("UIListLayout"),
		Elements = {},
		Depth = 0,
	}, Container)
end

--[[
	Section:Subsection({ Name = "Hitboxes" })

	A labelled divider inside a section that returns a container of its own, so a
	long section can be broken into titled groups without nesting it under a
	toggle. This is the one element the reference libraries have that folding
	groups do not cover.
]]
function Container:Subsection(options)
	if type(options) == "string" then
		options = { Name = options }
	end
	options = options or {}

	local name = tostring(Field(options, "Name", ""))

	local header = self:Row(Metrics.RowHeight)

	local label = Utils.Text({
		Size = UDim2.new(0, 0, 1, 0),
		AutomaticSize = Enum.AutomaticSize.X,
		Text = name,
		ThemeKey = "SectionNameText",
		Parent = header,
	})

	-- Rule filling the rest of the row, starting after the label.
	local rule = New("Frame", {
		Name = "Rule",
		BorderSizePixel = 0,
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, 0, 0.5, 0),
		Size = UDim2.new(1, 0, 0, 1),
		Parent = header,
	})
	Library:Bind(rule, "BackgroundColor3", "Border")

	local function fitRule()
		local width = math.max(0, header.AbsoluteSize.X - math.ceil(label.TextBounds.X) - 6)
		rule.Size = UDim2.fromOffset(width, 1)
	end

	Library:Connect(label:GetPropertyChangedSignal("TextBounds"), fitRule)
	Library:Connect(header:GetPropertyChangedSignal("AbsoluteSize"), fitRule)
	fitRule()

	local body = New("Frame", {
		Name = "Subsection",
		BackgroundTransparency = 1,
		LayoutOrder = header.LayoutOrder + 5,
		Size = UDim2.new(1, 0, 0, 0),
		Parent = self.Content,
	})

	local content = New("Frame", {
		Name = "Content",
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 1),
		Parent = body,
	}, {
		New("UIListLayout", {
			FillDirection = Enum.FillDirection.Vertical,
			SortOrder = Enum.SortOrder.LayoutOrder,
			Padding = UDim.new(0, Metrics.RowGap),
		}),
	})

	local layout = content:FindFirstChildOfClass("UIListLayout")

	local subsection = setmetatable({
		Name = name,
		Window = self.Window,
		Tab = self.Tab,
		Frame = body,
		Header = label,
		Content = content,
		Layout = layout,
		Elements = {},
		Depth = (self.Depth or 0) + 1,
	}, Container)

	-- Height follows the contents, like a section does.
	local function resize()
		body.Size = UDim2.new(1, 0, 0, layout.AbsoluteContentSize.Y)
	end

	Library:Connect(layout:GetPropertyChangedSignal("AbsoluteContentSize"), resize)
	resize()

	return subsection
end

Container.CreateSubsection = Container.Subsection

function Container:SetName(text)
	self.Name = tostring(text)
	if self.Header then
		self.Header.Text = self.Name
	end
	return self
end

--// Element helpers ///////////////////////////////////////////////////////////

-- Writes a value into the flag store and fires the element callback.
local function Commit(element, value, skipCallback)
	element.Value = value

	if element.Flag then
		Library.Flags[element.Flag] = value
	end

	if not skipCallback and element.Callback then
		local ok, err = pcall(element.Callback, value)
		if not ok then
			Library:Notify(string.format("callback error: %s", tostring(err)))
		end
	end

	return value
end

-- Resolves the label colour for risk-tagged elements.
local function RiskColor(risk)
	if not risk then
		return Themes.Current.TextColor
	end

	risk = tostring(risk):lower()
	if risk == "unsafe" or risk == "danger" then
		return Themes.Current.TextColorUnsafe
	elseif risk == "risky" or risk == "warning" or risk == "mid" then
		return Themes.Current.TextColorMid
	end

	return Themes.Current.TextColor
end

--// Label /////////////////////////////////////////////////////////////////////

function Container:Label(options)
	if type(options) == "string" then
		options = { Name = options }
	end
	options = options or {}

	local row = self:Row(Metrics.RowHeight - 2)
	local label = Utils.Text({
		Size = UDim2.fromScale(1, 1),
		Text = tostring(Field(options, "Name", Field(options, "Text", ""))),
		ThemeKey = Field(options, "ThemeKey", "TextColor"),
		TextXAlignment = Field(options, "Center", false)
				and Enum.TextXAlignment.Center
			or Enum.TextXAlignment.Left,
		Parent = row,
	})

	local element = {
		Type = "Label",
		Row = row,
		Label = label,
		Container = self,
	}

	function element:SetText(text)
		label.Text = tostring(text)
		return element
	end

	return self:Register(element)
end

Container.Text = Container.Label

--// Toggle ////////////////////////////////////////////////////////////////////

-- Forward declarations: toggles hand sub-elements to these, which are defined
-- further down once the container prototype exists.
local AttachColorpicker
local AttachKeybind
local BuildToggleGroup

--[[
	Section:Toggle({ Name = "Enabled", Flag = "flag", Default = false })

	15x15 box with an 11x11 core, label at x=18, and a right hand dock where
	keybinds and colour pickers attach. Pass Folding = true to get a group that
	holds nested elements.
]]
function Container:Toggle(options)
	options = options or {}

	local name = tostring(Field(options, "Name", "toggle"))
	local flag = Field(options, "Flag", nil)
	local callback = Field(options, "Callback", nil)
	local risk = Field(options, "Risk", nil)
	local folding = Field(options, "Folding", false) and true or false
	local default = Field(options, "Default", Field(options, "State", false)) and true or false

	local row = self:Row(Metrics.RowHeight)

	-- Panel gives us exactly the three layers the design uses: 15 outline,
	-- 13 border, 11 core.
	local box, core = Utils.Panel({
		Size = UDim2.fromOffset(Metrics.ToggleSize, Metrics.ToggleSize),
		Parent = row,
	})

	-- Grows with the row when the font changes.
	Utils.TrackSquare(box, Metrics.ToggleSize)

	Utils.ClearBase(core)
	local coreGradient = Utils.Gradient(core, Themes.Current.ToggleInactive, Themes.Current.ToggleInactiveShade)

	local label = Utils.Text({
		Position = UDim2.fromOffset(Metrics.ToggleSize + 3, 0),
		Size = UDim2.new(1, -(Metrics.ToggleSize + 3), 1, 0),
		Text = name,
		Parent = row,
	})

	-- Typed as any: elements gain fields as sub-elements attach to them.
	local element: any = {
		Type = "Toggle",
		Row = row,
		Box = box,
		Core = core,
		Label = label,
		Container = self,
		Callback = callback,
		Value = default,
		Risk = risk,
		Folding = folding,
		Disabled = Field(options, "Disabled", false) and true or false,
		--[[
			Right hand dock. Slots fill from the right edge: the keybind always
			takes the outermost slot and colour pickers stack inwards from it,
			which is how the Toggle and Unsafe rows are drawn in the design.
		]]
		Docks = {},
	}

	-- The core fill and the label colour are painters over the element's state,
	-- so a theme repaint resolves them the same way a click does.
	-- The core keeps the inactive gradient; the accent arrives as a growing fill.
	local corePainter = Library:Paint(coreGradient, "Color", function()
		return ColorSequence.new(Themes.Current.ToggleInactive, Themes.Current.ToggleInactiveShade)
	end, { "ToggleInactive", "ToggleInactiveShade" })

	local labelPainter = Library:Paint(label, "TextColor3", function()
		if element.Disabled then
			return Themes.Current.DisabledText
		end
		-- A keybind holding this row active tints its label too.
		if element.BindActive then
			return Themes.Current.Accent
		end
		return RiskColor(element.Risk)
	end, { "Accent", "TextColor", "TextColorUnsafe", "TextColorMid", "DisabledText" })

	--[[
		Switching fades the accent fill in and out over the whole core, so the
		square simply appears and disappears instead of changing shape. The fill
		covers the core at all times and only its transparency is animated: a
		ColorSequence cannot be tweened, a transparency can.
	]]
	local fill = New("Frame", {
		Name = "Fill",
		BackgroundColor3 = Color3.new(1, 1, 1),
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Size = UDim2.fromScale(1, 1),
		ZIndex = 2,
		Parent = core,
	})

	local fillGradient = Utils.Gradient(fill, Themes.Current.Accent, Themes.Current.AccentToggleShade)
	Library:Bind(fillGradient, "Color", "Accent", function(top)
		return ColorSequence.new(top, Themes.Current.AccentToggleShade)
	end)
	Library:Bind(fillGradient, "Color", "AccentToggleShade", function(bottom)
		return ColorSequence.new(Themes.Current.Accent, bottom)
	end)

	local function refresh(animate)
		corePainter.Apply()
		labelPainter.Apply()

		local target = element.Value and 0 or 1
		if animate == false then
			fill.BackgroundTransparency = target
		else
			Library:Tween(fill, { BackgroundTransparency = target }, nil, "Quad")
		end
	end

	element.Refresh = refresh

	function element:Set(value, skipCallback)
		Commit(element, value and true or false, skipCallback)
		-- Programmatic sets (config load, defaults) land without animating.
		refresh(not skipCallback)
		-- Folding groups open and close with their toggle; plain ones stay put.
		if element.Group and element.Group.FollowState ~= false then
			element.Group:SetOpen(element.Value)
		end
		return element
	end

	function element:Get()
		return element.Value
	end

	function element:SetDisabled(disabled)
		element.Disabled = disabled and true or false
		refresh()
		return element
	end

	local hitbox = Utils.Hitbox(row, 5)
	Library:Connect(hitbox.MouseButton1Click, function()
		if element.Disabled then
			return
		end
		element:Set(not element.Value)
	end)

	--[[
		Reserves a slot in the right hand dock and repositions every slot, so
		the keybind ends up flush right with pickers filling in towards the
		label. Later picker calls sit closer to the keybind.
	]]
	function element:Dock(kind, width, height)
		--[[
			ZIndex matters here. The row already has a click hitbox at ZIndex 5,
			and under Sibling ordering a child's ZIndex only sorts it among its
			own siblings: the whole docked subtree sits wherever its holder sits.
			Without a higher ZIndex on the holder, the row hitbox swallows every
			click meant for the swatch or the keybind.
		]]
		local frame = New("Frame", {
			Name = kind,
			AnchorPoint = Vector2.new(1, 0.5),
			BackgroundTransparency = 1,
			Position = UDim2.new(1, 0, 0.5, 0),
			Size = UDim2.fromOffset(width, height),
			ZIndex = 20,
			Parent = row,
		})

		-- Docked slots grow with the row when the font changes.
		Utils.TrackRow(frame, height)

		table.insert(element.Docks, { Frame = frame, Kind = kind })

		element.Relayout()
		return frame
	end

	--[[
		Lays the docked controls out from the right edge. The keybind takes the
		outermost slot and everything else fills in towards the label, with a two
		pixel gap: the design packs these tightly, and a wider gap reads as the
		controls being unrelated to their row.
	]]
	function element.Relayout()
		local ordered = {}

		for _, dock in element.Docks do
			if dock.Kind ~= "Keybind" then
				table.insert(ordered, dock)
			end
		end
		for _, dock in element.Docks do
			if dock.Kind == "Keybind" then
				table.insert(ordered, dock)
			end
		end

		local offset = 0
		for index = #ordered, 1, -1 do
			local dock = ordered[index]
			dock.Frame.Position = UDim2.new(1, -offset, 0.5, 0)
			offset += dock.Frame.Size.X.Offset + 2
		end

		-- Keep the label clear of the docked controls.
		label.Size = UDim2.new(1, -(Metrics.ToggleSize + 3) - offset, 1, 0)
	end

	-- Sub-elements docked to the right of the label.
	function element:Colorpicker(subOptions)
		return AttachColorpicker(element, subOptions)
	end
	element.ColorPicker = element.Colorpicker
	element.colorpicker = element.Colorpicker

	function element:Keybind(subOptions)
		return AttachKeybind(element, subOptions)
	end
	element.keybind = element.Keybind

	--[[
		Nested group. It is created up front rather than on demand so that it
		always sits directly beneath its toggle in the layout order.
	]]
	element.Group = BuildToggleGroup(element, self)

	--[[
		Nested elements are delegated straight into the group.

		"Label" is deliberately absent: element.Label is the toggle's own text
		object, which the dock and the painters need. Delegating a method under
		that name would overwrite it, and anything reading element.Label.Text
		would then be indexing a function. Nested labels go through AddLabel.
	]]
	local delegated = {
		"Toggle",
		"Slider",
		"Dropdown",
		"Button",
		"Buttons",
		"Textbox",
		"Colorpicker",
		"Keybind",
		"Subsection",
	}
	for _, method in delegated do
		-- Colorpicker and Keybind dock onto the row, so keep those overrides.
		if element[method] == nil then
			element[method] = function(_, subOptions)
				return element.Group[method](element.Group, subOptions)
			end
		end
	end

	function element:AddLabel(subOptions)
		return element.Group:Label(subOptions)
	end

	self:Register(element, flag)
	element:Set(default, true)

	if folding then
		--[[
			A folding toggle gets an expander instead of opening with its own
			state: the feature can be on while its settings stay collapsed, which
			is how these menus normally behave.
		]]
		element.Group.FollowState = false
		element.Group:SetOpen(false)

		-- Just the sign, no box around it.
		local expander = element:Dock("Expander", 9, 13)

		local sign = Utils.Text({
			Size = UDim2.fromScale(1, 1),
			TextXAlignment = Enum.TextXAlignment.Center,
			Text = "+",
			ThemeKey = "InactiveButtonText",
			Parent = expander,
		})

		local signPainter = Library:Paint(sign, "TextColor3", function()
			return element.Group.IsOpen and Themes.Current.Accent
				or Themes.Current.InactiveButtonText
		end, { "Accent", "InactiveButtonText" })

		local expanderHit = Utils.Hitbox(expander, 25)
		Library:Connect(expanderHit.MouseButton1Click, function()
			element.Group:SetOpen(not element.Group.IsOpen)
			sign.Text = element.Group.IsOpen and "-" or "+"
			signPainter.Apply()
		end)

		element.Expander = expander
	else
		-- Non-folding toggles keep their group open, so nested elements behave
		-- like plain siblings instead of disappearing.
		element.Group.FollowState = false
		element.Group:SetOpen(true)
	end

	return element
end

--// Button ////////////////////////////////////////////////////////////////////

-- Shared builder for single and paired buttons. Assigned to the local declared
-- alongside the player list, which uses it too.
function BuildButton(parent, options, width)
	local name = tostring(Field(options, "Name", Field(options, "Text", "button")))
	local callback = Field(options, "Callback", nil)

	local holder = New("Frame", {
		Name = name,
		BackgroundTransparency = 1,
		Size = width or UDim2.new(1, 0, 1, 0),
		Parent = parent,
	})

	local outer, body = Utils.Raised({
		Size = UDim2.fromScale(1, 1),
		Parent = holder,
	})

	local label = Utils.Text({
		Size = UDim2.fromScale(1, 1),
		TextXAlignment = Enum.TextXAlignment.Center,
		Text = name,
		ThemeKey = "InactiveButtonText",
		Parent = body,
	})

	local element: any = {
		Type = "Button",
		Frame = holder,
		Outer = outer,
		Body = body,
		Label = label,
		Callback = callback,
		Hovered = false,
		Pressed = false,
	}

	--[[
		Hover fills the surface with the accent gradient and prints the label in
		the accent colour too, exactly as the highlighted button is drawn in the
		design. It stays legible because of the 1px black text outline.
	]]
	--[[
		The highlight is a separate accent layer whose transparency is tweened: a
		ColorSequence cannot be animated, a transparency can. What triggers it is
		a setting, so buttons can light on hover, on press, or on both.
	]]
	local highlight = New("Frame", {
		Name = "Highlight",
		BackgroundColor3 = Color3.new(1, 1, 1),
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Size = UDim2.fromScale(1, 1),
		--[[
			Behind the label. This frame is created after it, and later siblings
			render on top, so without an explicit ZIndex the highlight covers the
			text and the button reads as blank while lit.
		]]
		ZIndex = 0,
		Parent = body,
	})

	label.ZIndex = 2

	local highlightGradient =
		Utils.Gradient(highlight, Themes.Current.Accent, Themes.Current.AccentToggleShade)
	Library:Bind(highlightGradient, "Color", "Accent", function(top)
		return ColorSequence.new(top, Themes.Current.AccentToggleShade)
	end)
	Library:Bind(highlightGradient, "Color", "AccentToggleShade", function(bottom)
		return ColorSequence.new(Themes.Current.Accent, bottom)
	end)

	local function highlighted()
		local mode = tostring(Library.Settings.ButtonHighlight or "Hover")
		if mode == "Press" then
			return element.Pressed and true or false
		elseif mode == "Both" then
			return (element.Hovered or element.Pressed) and true or false
		end
		return element.Hovered and true or false
	end

	local labelPainter = Library:Paint(label, "TextColor3", function()
		if highlighted() then
			return Themes.Current.Accent
		end
		return Themes.Current.InactiveButtonText
	end, { "Accent", "InactiveButtonText" })

	local function refresh()
		labelPainter.Apply()

		local duration = tonumber(Library.Settings.ButtonTweenDuration)
		Library:Tween(highlight, { BackgroundTransparency = highlighted() and 0 or 1 }, duration)
	end

	element.Refresh = refresh

	local hitbox = Utils.Hitbox(holder, 5)

	Library:Connect(hitbox.MouseEnter, function()
		element.Hovered = true
		refresh()
	end)
	Library:Connect(hitbox.MouseLeave, function()
		element.Hovered = false
		element.Pressed = false
		refresh()
	end)
	Library:Connect(hitbox.MouseButton1Down, function()
		element.Pressed = true
		refresh()
	end)
	Library:Connect(hitbox.MouseButton1Up, function()
		element.Pressed = false
		refresh()
	end)
	Library:Connect(hitbox.MouseButton1Click, function()
		if element.Callback then
			local ok, err = pcall(element.Callback)
			if not ok then
				Library:Notify(string.format("callback error: %s", tostring(err)))
			end
		end
	end)

	function element:SetText(text)
		label.Text = tostring(text)
		return element
	end

	refresh()
	return element
end

function Container:Button(options)
	if type(options) == "string" then
		options = { Name = options }
	end
	options = options or {}

	local row = self:Row(Metrics.ButtonHeight)
	local element = BuildButton(row, options)
	element.Row = row
	element.Container = self

	return self:Register(element, Field(options, "Flag", nil))
end

--[[
	Section:Buttons({ { Name = "Create", Callback = f }, { Name = "Delete" } })

	Lays out equal buttons across one row, the paired layout used by the config
	window in the design.
]]
function Container:Buttons(list)
	list = list or {}

	local row = self:Row(Metrics.ButtonHeight)
	local count = math.max(1, #list)
	local gap = 4
	local built = {}

	for index, options in list do
		local width = UDim2.new(1 / count, -(gap * (count - 1)) / count, 1, 0)
		local element = BuildButton(row, options, width)

		-- Position by hand: a list layout would fight the fractional widths.
		element.Frame.Position = UDim2.new(
			(index - 1) / count,
			((index - 1) * gap) / count,
			0,
			0
		)

		element.Row = row
		element.Container = self
		self:Register(element, Field(options, "Flag", nil))
		table.insert(built, element)
	end

	return built
end

--// Textbox ///////////////////////////////////////////////////////////////////

function Container:Textbox(options)
	options = options or {}

	local name = Field(options, "Name", nil)
	local flag = Field(options, "Flag", nil)
	local callback = Field(options, "Callback", nil)
	local default = tostring(Field(options, "Default", Field(options, "Value", "")))
	local placeholder = tostring(Field(options, "Placeholder", "Type here..."))
	local clearOnFocus = Field(options, "ClearOnFocus", false) and true or false

	-- Optional caption above the field, like the dropdown labels in the design.
	if name and tostring(name) ~= "" then
		local caption = self:Row(Metrics.RowHeight - 2)
		Utils.Text({
			Size = UDim2.fromScale(1, 1),
			Text = tostring(name),
			ThemeKey = "CaptionText",
			Parent = caption,
		})
	end

	local row = self:Row(Metrics.TextboxHeight)
	local _, body = Utils.Raised({
		Size = UDim2.fromScale(1, 1),
		Parent = row,
	})

	local input = New("TextBox", {
		BackgroundTransparency = 1,
		ClearTextOnFocus = clearOnFocus,
		Size = UDim2.new(1, -6, 1, 0),
		Position = UDim2.fromOffset(3, Metrics.TextInkOffset or 0),
		Text = default,
		PlaceholderText = placeholder,
		TextSize = Metrics.TextBase,
		TextXAlignment = Enum.TextXAlignment.Center,
		TextYAlignment = Enum.TextYAlignment.Center,
		TextTruncate = Enum.TextTruncate.AtEnd,
		Parent = body,
	})
	ApplyFont(input)
	Library:Bind(input, "TextColor3", "InactiveButtonText")
	Utils.Outline(input)
	Library:Bind(input, "PlaceholderColor3", "InactiveButtonText", function(color)
		return Utils.Multiply(color, 0.68)
	end)

	local element = {
		Type = "Textbox",
		Row = row,
		Input = input,
		Container = self,
		Callback = callback,
		Value = default,
	}

	function element:Set(value, skipCallback)
		input.Text = tostring(value)
		Commit(element, input.Text, skipCallback)
		return element
	end

	function element:Get()
		return element.Value
	end

	Library:Connect(input.FocusLost, function(enterPressed)
		Commit(element, input.Text)
		if enterPressed and Field(options, "ClearOnEnter", false) then
			input.Text = ""
		end
	end)

	self:Register(element, flag)
	Commit(element, default, true)

	return element
end

--// Slider ////////////////////////////////////////////////////////////////////

--[[
	Section:Slider({ Name = "FOV", Min = 0, Max = 180, Default = 90 })

	Full width bar with the accent gradient as the fill and a centred caption,
	matching the slider in the design.
]]
function Container:Slider(options)
	options = options or {}

	local name = tostring(Field(options, "Name", "slider"))
	local flag = Field(options, "Flag", nil)
	local callback = Field(options, "Callback", nil)
	local min = tonumber(Field(options, "Min", 0)) or 0
	local max = tonumber(Field(options, "Max", 100)) or 100
	local interval = tonumber(Field(options, "Interval", Field(options, "Increment", 1))) or 1
	local suffix = tostring(Field(options, "Suffix", ""))
	local showName = Field(options, "ShowName", true) and true or false
	local default = tonumber(Field(options, "Default", min)) or min

	local row = self:Row(Metrics.SliderHeight)

	local _, body = Utils.Panel({
		Size = UDim2.fromScale(1, 1),
		Parent = row,
	})
	Library:Bind(body, "BackgroundColor3", "ToggleInactiveShade")

	local fill = New("Frame", {
		Name = "Fill",
		BackgroundColor3 = Color3.new(1, 1, 1),
		BorderSizePixel = 0,
		Size = UDim2.fromScale(0, 1),
		Parent = body,
	})
	local fillGradient =
		Utils.Gradient(fill, Themes.Current.Accent, Themes.Current.AccentToggleShade)
	Library:Bind(fillGradient, "Color", "Accent", function(top)
		return ColorSequence.new(top, Themes.Current.AccentToggleShade)
	end)
	Library:Bind(fillGradient, "Color", "AccentToggleShade", function(bottom)
		return ColorSequence.new(Themes.Current.Accent, bottom)
	end)

	local label = Utils.Text({
		Size = UDim2.fromScale(1, 1),
		TextXAlignment = Enum.TextXAlignment.Center,
		Text = name,
		ZIndex = 3,
		Parent = body,
	})

	local element = {
		Type = "Slider",
		Row = row,
		Fill = fill,
		Label = label,
		Container = self,
		Callback = callback,
		Min = min,
		Max = max,
		Interval = interval,
		Suffix = suffix,
		Value = default,
	}

	--[[
		At the top of the range the caption reads "max" instead of the number,
		the way the slider is labelled in the design. MinText and MaxText
		override the words, and either can be turned off with false.
	]]
	local maxText = Field(options, "MaxText", "max")
	local minText = Field(options, "MinText", nil)

	local function format(value)
		local body = string.format("%s%s", tostring(value), suffix)

		if maxText and value >= element.Max then
			body = tostring(maxText)
		elseif minText and value <= element.Min then
			body = tostring(minText)
		end

		if showName then
			return string.format("%s: %s", name, body)
		end
		return body
	end

	function element:Set(value, skipCallback)
		value = tonumber(value) or element.Min
		value = Utils.Clamp(Utils.Round(value, element.Interval), element.Min, element.Max)

		local span = element.Max - element.Min
		local alpha = span > 0 and (value - element.Min) / span or 0

		fill.Size = UDim2.fromScale(alpha, 1)
		label.Text = format(value)

		Commit(element, value, skipCallback)
		return element
	end

	function element:Get()
		return element.Value
	end

	function element:SetRange(newMin, newMax)
		element.Min = tonumber(newMin) or element.Min
		element.Max = tonumber(newMax) or element.Max
		return element:Set(element.Value, true)
	end

	-- Dragging: map the cursor's X within the bar onto the value range.
	local dragging = false

	local function updateFromInput(inputPosition)
		local absolutePosition = body.AbsolutePosition.X
		local absoluteSize = math.max(1, body.AbsoluteSize.X)
		local alpha = Utils.Clamp((inputPosition.X - absolutePosition) / absoluteSize, 0, 1)
		element:Set(element.Min + (element.Max - element.Min) * alpha)
	end

	local hitbox = Utils.Hitbox(row, 5)

	Library:Connect(hitbox.InputBegan, function(input)
		if input.UserInputType ~= Enum.UserInputType.MouseButton1
			and input.UserInputType ~= Enum.UserInputType.Touch then
			return
		end
		dragging = true
		updateFromInput(input.Position)
	end)

	Library:Connect(hitbox.InputEnded, function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1
			or input.UserInputType == Enum.UserInputType.Touch then
			dragging = false
		end
	end)

	Library:Connect(UserInputService.InputChanged, function(input)
		if not dragging then
			return
		end
		if input.UserInputType == Enum.UserInputType.MouseMovement
			or input.UserInputType == Enum.UserInputType.Touch then
			updateFromInput(input.Position)
		end
	end)

	Library:Connect(UserInputService.InputEnded, function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 then
			dragging = false
		end
	end)

	self:Register(element, flag)
	element:Set(default, true)

	return element
end

--// Popups ////////////////////////////////////////////////////////////////////

Library.OpenPopups = {}

--[[
	Floating panel anchored under a control. Popups live on the holder rather
	than inside their section, because section columns clip their contents.
	Position is refreshed while open so scrolling and window drags keep up.
]]
function Utils.Popup(anchor, width, height, options)
	options = options or {}

	--[[
		Full screen button sitting just under the popup. It swallows clicks that
		miss the popup, which is what stops the window underneath from starting
		a drag while a colour is being picked. Clicks that land on it still
		reach the global handler below, so the popup closes as expected.
	]]
	local blocker = New("TextButton", {
		Name = "PopupBlocker",
		AutoButtonColor = false,
		BackgroundTransparency = 1,
		Text = "",
		Size = UDim2.fromScale(1, 1),
		Visible = false,
		ZIndex = Library.ZLayers.PopupBlocker,
		Parent = Library.Holder,
	})

	local frame = New("Frame", {
		Name = "Popup",
		BackgroundTransparency = 1,
		Size = UDim2.fromOffset(width, height),
		Visible = false,
		ZIndex = Library.ZLayers.Popup,
		Parent = Library.Holder,
	})

	local _, body = Utils.Raised({
		Size = UDim2.fromScale(1, 1),
		Parent = frame,
	})

	local popup: any = {
		Frame = frame,
		Body = body,
		Blocker = blocker,
		Anchor = anchor,
		IsOpen = false,
		Tracker = false,
		-- Set once the user drags the popup: it then stays where it was put.
		Pinned = false,
		-- Nesting: the popup this one opened from, and the one it opened.
		Owner = false,
		Child = false,
		-- When it last closed, used to swallow the click that closed it.
		ClosedAt = 0,
	}

	--[[
		Anchoring maths runs in the holder's own space rather than in camera
		space: the viewport size is read from the ScreenGui, so it stays correct
		whatever the topbar inset does, and a stale camera can no longer push
		popups to the wrong edge.
	]]
	local function reposition()
		if popup.Pinned then
			return
		end

		local origin = Library.Holder.AbsolutePosition
		local viewport = Library.ScreenGui.AbsoluteSize
		local position = anchor.AbsolutePosition - origin
		local size = anchor.AbsoluteSize

		--[[
			Dropdowns track the width of the control they belong to, so resizing
			the window keeps the list the same width as its field instead of
			leaving it stuck at whatever the width was when it was built.
		]]
		--[[
			Width is rounded, not truncated, and the x position is rounded the
			same way. Flooring the two independently loses a pixel on one edge
			whenever the control lands on a fractional coordinate, which shows up
			as a missing sliver of outline.
		]]
		if options.MatchAnchorWidth and size.X > 0 then
			frame.Size = UDim2.fromOffset(math.floor(size.X + 0.5), frame.Size.Y.Offset)
		end

		local popupHeight = frame.AbsoluteSize.Y > 0 and frame.AbsoluteSize.Y or frame.Size.Y.Offset

		local x = Utils.Clamp(
			math.floor(position.X + 0.5),
			0,
			math.max(0, viewport.X - frame.Size.X.Offset)
		)
		local below = math.floor(position.Y + size.Y + 0.5)
		local above = below - size.Y - popupHeight - 1
		local y = below

		-- Only flip when there is genuinely no room below and more room above.
		local roomBelow = viewport.Y - below
		if roomBelow < popupHeight and above >= 0 and position.Y > roomBelow then
			y = above
		end

		y = Utils.Clamp(y, 0, math.max(0, viewport.Y - popupHeight))
		frame.Position = UDim2.fromOffset(math.floor(x), math.floor(y))
	end

	popup.Reposition = reposition

	function popup:Open()
		if popup.IsOpen then
			return popup
		end

		--[[
			One popup at a time, except for nesting: a popup whose anchor lives
			inside another popup is a child of it, and opening the child must not
			close the parent. That is what lets the animation dropdown inside a
			colour picker open without the picker disappearing.
		]]
		popup.Owner = false

		for _, other in Library.OpenPopups do
			if other ~= popup then
				if other.Frame:IsAncestorOf(anchor) then
					popup.Owner = other
					other.Child = popup
				else
					other:Close()
				end
			end
		end

		popup.IsOpen = true
		reposition()
		frame.Visible = true
		blocker.Visible = true
		local depth = Library:NextPopupZIndex()
		blocker.ZIndex = Library.ZLayers.PopupBlocker + depth
		frame.ZIndex = Library.ZLayers.Popup + depth

		if not table.find(Library.OpenPopups, popup) then
			table.insert(Library.OpenPopups, popup)
		end

		popup.Tracker = Library:Connect(RunService.Heartbeat, function()
			if not anchor.Parent or not anchor.Visible then
				popup:Close()
				return
			end
			reposition()
		end)

		return popup
	end

	function popup:Close()
		if not popup.IsOpen then
			return popup
		end

		popup.IsOpen = false
		popup.ClosedAt = os.clock()
		frame.Visible = false
		blocker.Visible = false

		-- Drop the nesting links, and take any child down with it.
		if popup.Child then
			local child = popup.Child
			popup.Child = false
			child:Close()
		end
		if popup.Owner then
			popup.Owner.Child = false
			popup.Owner = false
		end

		if popup.Tracker then
			popup.Tracker:Disconnect()
			popup.Tracker = nil
		end

		local index = table.find(Library.OpenPopups, popup)
		if index then
			table.remove(Library.OpenPopups, index)
		end

		return popup
	end

	--[[
		Toggling from a control's own click handler.

		The global click handler closes a popup when its control is clicked,
		since the blocker sits above that control. The click then carries on to
		the control and would immediately reopen what was just closed, so a
		toggle that lands in the same moment as a close is ignored.
	]]
	function popup:Toggle()
		if popup.IsOpen then
			return popup:Close()
		end
		if os.clock() - (popup.ClosedAt or 0) < 0.08 then
			return popup
		end
		return popup:Open()
	end

	--[[
		Optional title strip. Dragging it pins the popup, so it stops following
		its anchor and can be parked anywhere, which is what makes picking a
		colour next to the edge of a window practical.
	]]
	local title = Field(options, "Title", nil)
	if title then
		local strip = New("Frame", {
			Name = "Title",
			BackgroundColor3 = Color3.new(1, 1, 1),
			BorderSizePixel = 0,
			Size = UDim2.new(1, 0, 0, Metrics.SectionHeaderHeight),
			Parent = body,
		})
		local stripGradient = Utils.Gradient(
			strip,
			Themes.Current.SectionHeaderTop,
			Themes.Current.SectionHeaderBottom
		)
		Library:Bind(stripGradient, "Color", "SectionHeaderTop", function(top)
			return ColorSequence.new(top, Themes.Current.SectionHeaderBottom)
		end)

		popup.TitleLabel = Utils.Text({
			Position = UDim2.fromOffset(3, 0),
			Size = UDim2.new(1, -6, 1, 0),
			Text = tostring(title),
			ThemeKey = "SectionNameText",
			Parent = strip,
		})

		local handle = New("TextButton", {
			Name = "Handle",
			AutoButtonColor = false,
			BackgroundTransparency = 1,
			Text = "",
			Size = UDim2.fromScale(1, 1),
			ZIndex = 10,
			Parent = strip,
		})

		--[[
			Pinned on press, not on release.

			While a popup is open it is re-anchored under its control every frame.
			Pinning only at the end of a drag meant the two fought each other for
			the whole gesture: the drag set one position, the tracker put it back,
			and the popup flickered between them.
		]]
		Library:Connect(handle.InputBegan, function(input)
			if input.UserInputType == Enum.UserInputType.MouseButton1
				or input.UserInputType == Enum.UserInputType.Touch then
				popup.Pinned = true
			end
		end)

		Utils.Drag(handle, frame)

		-- A pinned popup can be snapped back under its anchor.
		Library:Connect(handle.MouseButton2Click, function()
			popup.Pinned = false
			reposition()
		end)

		popup.ContentOffset = Metrics.SectionHeaderHeight
	else
		popup.ContentOffset = 0
	end

	return popup
end

-- Clicking outside every open popup dismisses them.
Library:Connect(UserInputService.InputBegan, function(input, processed)
	if input.UserInputType ~= Enum.UserInputType.MouseButton1
		and input.UserInputType ~= Enum.UserInputType.Touch then
		return
	end
	if #Library.OpenPopups == 0 then
		return
	end

	local position = Vector2.new(input.Position.X, input.Position.Y)

	local function contains(instance)
		if not instance or not instance.Parent then
			return false
		end
		local topLeft = instance.AbsolutePosition
		local bottomRight = topLeft + instance.AbsoluteSize
		return position.X >= topLeft.X
			and position.X <= bottomRight.X
			and position.Y >= topLeft.Y
			and position.Y <= bottomRight.Y
	end

	--[[
		A click inside a nested popup counts as a click inside its parents too,
		otherwise picking an item in a nested dropdown would dismiss the popup
		that owns it.
	]]
	local function claimed(popup)
		local cursor = popup
		while cursor do
			if contains(cursor.Frame) or contains(cursor.Anchor) then
				return true
			end
			cursor = cursor.Child
		end
		return false
	end

	for index = #Library.OpenPopups, 1, -1 do
		local popup = Library.OpenPopups[index]

		--[[
			Clicking the control again closes its popup.

			The blocker sits above the control, so the field's own click event
			never fires while the popup is open, which is why the toggle has to
			happen here instead.
		]]
		if contains(popup.Anchor) and not contains(popup.Frame) then
			popup:Close()
		elseif not claimed(popup) then
			popup:Close()
		end
	end
end)

--// Dropdown //////////////////////////////////////////////////////////////////

--[[
	Section:Dropdown({ Name = "Target", Options = { "Head", "Torso" } })

	Caption above a raised field, with a floating list underneath. Multi = true
	turns it into a checklist whose selection renders as a comma joined string,
	the way the design shows "saygex, niger, ballsack".
]]
function Container:Dropdown(options)
	options = options or {}

	local name = Field(options, "Name", nil)
	local flag = Field(options, "Flag", nil)
	local callback = Field(options, "Callback", nil)
	local multi = Field(options, "Multi", false) and true or false
	-- At least five rows are shown before the list starts scrolling.
	local maxVisible = math.max(5, tonumber(Field(options, "MaxVisible", 6)) or 6)
	local placeholder = tostring(Field(options, "Placeholder", "..."))

	local items = Field(options, "Options", Field(options, "Items", Field(options, "List", {})))
	if type(items) ~= "table" then
		items = {}
	end
	items = table.clone(items)

	local default = Field(options, "Default", nil)

	if name and tostring(name) ~= "" then
		local caption = self:Row(Metrics.RowHeight - 2)
		Utils.Text({
			Size = UDim2.fromScale(1, 1),
			Text = tostring(name),
			ThemeKey = "CaptionText",
			Parent = caption,
		})
	end

	local row = self:Row(Metrics.DropdownHeight)
	local _, body = Utils.Raised({
		Size = UDim2.fromScale(1, 1),
		Parent = row,
	})

	body.ClipsDescendants = true

	local display = Utils.Text({
		Position = UDim2.fromOffset(3, 0),
		Size = UDim2.new(1, -16, 1, 0),
		Text = placeholder,
		ThemeKey = "InactiveButtonText",
		TextTruncate = Enum.TextTruncate.AtEnd,
		Parent = body,
	})

	-- Indicator on the right edge of the closed field.
	local arrow = Utils.Text({
		Name = "Arrow",
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, -3, 0.5, 0),
		Size = UDim2.fromOffset(8, 8),
		TextSize = Metrics.TextTiny,
		TextXAlignment = Enum.TextXAlignment.Right,
		Text = "+",
		ThemeKey = "InactiveButtonText",
		Parent = body,
	})

	--[[
		Rows are 14px: at 12px text a 12px row clips the descenders and the
		lines visually collide.
	]]
	local itemHeight = 14

	--[[
		The popup's own chrome has to be paid for: the panel costs a pixel of
		outline and a pixel of border top and bottom, and the list is inset by two
		more on each side. Eight pixels in total, and leaving them out is what cut
		the last row off.
	]]
	local POPUP_CHROME = 8

	local function listHeight(count)
		return math.max(1, math.min(count, maxVisible)) * itemHeight + POPUP_CHROME
	end

	local popup = Utils.Popup(row, 244, listHeight(#items), { MatchAnchorWidth = true })

	--[[
		The open list gets the same vertical gradient as a section body, so it
		reads as part of the panel work rather than as a flat black box.
	]]
	Utils.ClearBase(popup.Body)
	local listGradient =
		Utils.Gradient(popup.Body, Themes.Current.SectionTop, Themes.Current.SectionBottom)
	Library:Bind(listGradient, "Color", "SectionTop", function(top)
		return ColorSequence.new(top, Themes.Current.SectionBottom)
	end)
	Library:Bind(listGradient, "Color", "SectionBottom", function(bottom)
		return ColorSequence.new(Themes.Current.SectionTop, bottom)
	end)

	--[[
		A real scrollbar rather than wheel-only scrolling: Roblox's own bar is
		draggable, so a long list can be paged without a wheel.
	]]
	local list = New("ScrollingFrame", {
		Name = "List",
		Active = true,
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Position = UDim2.fromOffset(2, 2),
		Size = UDim2.new(1, -4, 1, -4),
		CanvasSize = UDim2.new(),
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
		-- Two pixels: thick enough to grab, thin enough not to read as a border.
		ScrollBarThickness = 2,
		ScrollBarImageTransparency = 0.25,
		ScrollBarImageColor3 = Color3.fromRGB(191, 190, 238),
		ScrollingDirection = Enum.ScrollingDirection.Y,
		Parent = popup.Body,
	}, {
		New("UIListLayout", {
			FillDirection = Enum.FillDirection.Vertical,
			SortOrder = Enum.SortOrder.LayoutOrder,
			Padding = UDim.new(0, 0),
		}),
	})

	Library:Bind(list, "ScrollBarImageColor3", "Accent")

	local element = {
		Type = "Dropdown",
		Row = row,
		Display = display,
		Popup = popup,
		Container = self,
		Callback = callback,
		Multi = multi,
		Items = items,
		Value = multi and {} or nil,
		Buttons = {},
		Painters = {},
	}

	-- Renders the closed field text from the current selection.
	local function updateDisplay()
		if multi then
			local picked = {}
			for _, item in element.Items do
				if element.Value[item] then
					table.insert(picked, tostring(item))
				end
			end
			display.Text = #picked > 0 and table.concat(picked, ", ") or placeholder
		else
			display.Text = element.Value ~= nil and tostring(element.Value) or placeholder
		end
	end

	local function paintButtons()
		for _, painter in element.Painters do
			painter.Apply()
		end
	end

	local function rebuild()
		for _, child in list:GetChildren() do
			if child:IsA("TextButton") then
				child:Destroy()
			end
		end
		element.Buttons = {}
		table.clear(element.Painters)

		for index, item in element.Items do
			local button = New("TextButton", {
				Name = tostring(item),
				AutoButtonColor = false,
				BackgroundTransparency = 1,
				LayoutOrder = index,
				Size = UDim2.new(1, 0, 0, itemHeight),
				Position = UDim2.fromOffset(0, Metrics.TextInkOffset or 0),
				Text = "  " .. tostring(item),
				TextSize = Metrics.TextBase,
				TextXAlignment = Enum.TextXAlignment.Left,
				TextYAlignment = Enum.TextYAlignment.Center,
				TextTruncate = Enum.TextTruncate.AtEnd,
				Parent = list,
			})
			ApplyFont(button)
			Utils.Outline(button)

			element.Buttons[item] = button

			-- Selected rows print in the accent colour, the rest stay dim.
			table.insert(
				element.Painters,
				Library:Paint(button, "TextColor3", function()
					local selected
					if multi then
						selected = element.Value[item] and true or false
					else
						selected = element.Value == item
					end
					return selected and Themes.Current.Accent or Themes.Current.InactiveButtonText
				end, { "Accent", "InactiveButtonText" })
			)

			Library:Connect(button.MouseButton1Click, function()
				if multi then
					element.Value[item] = not element.Value[item] or nil
					updateDisplay()
					paintButtons()
					Commit(element, element.Value)
				else
					element:Set(item)
					popup:Close()
				end
			end)
		end

		-- Match the popup to the field and to the number of visible rows.
		popup.Frame.Size = UDim2.fromOffset(math.max(80, row.AbsoluteSize.X), listHeight(#element.Items))
		paintButtons()
	end

	function element:Set(value, skipCallback)
		if multi then
			local selection = {}
			if type(value) == "table" then
				-- Accept both { "a", "b" } and { a = true, b = true }.
				local isArray = value[1] ~= nil
				if isArray then
					for _, item in value do
						selection[item] = true
					end
				else
					for item, state in value do
						if state then
							selection[item] = true
						end
					end
				end
			end
			element.Value = selection
		else
			element.Value = value
		end

		updateDisplay()
		paintButtons()
		Commit(element, element.Value, skipCallback)
		return element
	end

	function element:Get()
		return element.Value
	end

	function element:SetItems(newItems)
		element.Items = type(newItems) == "table" and table.clone(newItems) or {}

		-- Drop selections that no longer exist.
		if multi then
			for item in element.Value do
				if not table.find(element.Items, item) then
					element.Value[item] = nil
				end
			end
		elseif element.Value ~= nil and not table.find(element.Items, element.Value) then
			element.Value = nil
		end

		rebuild()
		updateDisplay()
		return element
	end

	element.Refresh = paintButtons
	Library:OnThemeChange(paintButtons)

	local hitbox = Utils.Hitbox(row, 5)
	Library:Connect(hitbox.MouseButton1Click, function()
		popup:Toggle()
		arrow.Text = popup.IsOpen and "-" or "+"
	end)

	-- The arrow also has to follow a popup closed from somewhere else.
	Library:Connect(popup.Frame:GetPropertyChangedSignal("Visible"), function()
		arrow.Text = popup.Frame.Visible and "-" or "+"
	end)

	rebuild()
	self:Register(element, flag)

	if default ~= nil then
		element:Set(default, true)
	else
		updateDisplay()
		Commit(element, element.Value, true)
	end

	return element
end

--// Colorpicker ///////////////////////////////////////////////////////////////

--[[
	Builds the picker into a 27x13 swatch, the size used everywhere in the
	design. The popup is assembled from gradients only, so it needs no uploaded
	image assets: hue base, white overlay across, black overlay down.
]]
local function BuildColorpicker(holder, options, ownerRow)
	options = options or {}

	local callback = Field(options, "Callback", nil)
	local useAlpha = Field(options, "Alpha", Field(options, "Transparency", false)) and true or false
	local default = Field(options, "Color", Field(options, "Default", Color3.fromRGB(191, 190, 238)))
	if typeof(default) == "string" then
		default = Utils.FromHex(default) or Color3.fromRGB(191, 190, 238)
	end

	local _, swatchBody = Utils.Panel({
		Size = UDim2.fromScale(1, 1),
		Parent = holder,
	})
	swatchBody.BackgroundColor3 = default

	--[[
		Geometry. The field is deliberately large: picking a shade inside a
		100px square was too fiddly, and the popup now carries a title strip so
		it can be dragged out from under whatever window opened it.
	]]
	local FIELD_WIDTH = 180
	local FIELD_HEIGHT = 140
	local STRIP_WIDTH = 14
	local popupWidth = 4 + FIELD_WIDTH + 4 + STRIP_WIDTH + 4
	-- Room for the hex field plus the animation controls underneath it.
	local ANIMATION_HEIGHT = 92
	local popupHeight = Metrics.SectionHeaderHeight
		+ 4
		+ FIELD_HEIGHT
		+ 4
		+ (useAlpha and (STRIP_WIDTH + 4) or 0)
		+ Metrics.TextboxHeight
		+ 4
		+ ANIMATION_HEIGHT

	local popup = Utils.Popup(ownerRow or holder, popupWidth, popupHeight, {
		Title = tostring(Field(options, "Name", "colour")),
	})

	local top = popup.ContentOffset + 4

	-- Saturation / value field.
	local field = New("Frame", {
		Name = "Field",
		BackgroundColor3 = Color3.fromRGB(255, 0, 0),
		BorderSizePixel = 0,
		Position = UDim2.fromOffset(4, top),
		Size = UDim2.fromOffset(FIELD_WIDTH, FIELD_HEIGHT),
		Parent = popup.Body,
	})

	New("Frame", {
		Name = "Saturation",
		BackgroundColor3 = Color3.new(1, 1, 1),
		BorderSizePixel = 0,
		Size = UDim2.fromScale(1, 1),
		Parent = field,
	}, {
		New("UIGradient", {
			Color = ColorSequence.new(Color3.new(1, 1, 1), Color3.new(1, 1, 1)),
			Transparency = NumberSequence.new({
				NumberSequenceKeypoint.new(0, 0),
				NumberSequenceKeypoint.new(1, 1),
			}),
		}),
	})

	New("Frame", {
		Name = "Value",
		BackgroundColor3 = Color3.new(0, 0, 0),
		BorderSizePixel = 0,
		Size = UDim2.fromScale(1, 1),
		Parent = field,
	}, {
		New("UIGradient", {
			Color = ColorSequence.new(Color3.new(0, 0, 0), Color3.new(0, 0, 0)),
			Rotation = 90,
			Transparency = NumberSequence.new({
				NumberSequenceKeypoint.new(0, 1),
				NumberSequenceKeypoint.new(1, 0),
			}),
		}),
	})

	--[[
		A small white square with a black outline. Both are needed: white alone
		disappears into the pale corner of the field, black alone into the dark
		one, and the pair stays readable everywhere.
	]]
	local cursor = New("Frame", {
		Name = "Cursor",
		BackgroundColor3 = Color3.new(1, 1, 1),
		BorderSizePixel = 0,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Size = UDim2.fromOffset(4, 4),
		ZIndex = 5,
		Parent = field,
	}, {
		New("UIStroke", {
			Color = Color3.new(0, 0, 0),
			Thickness = 1,
			LineJoinMode = Enum.LineJoinMode.Miter,
		}),
	})

	-- Hue strip.
	local hue = New("Frame", {
		Name = "Hue",
		BackgroundColor3 = Color3.new(1, 1, 1),
		BorderSizePixel = 0,
		Position = UDim2.fromOffset(4 + FIELD_WIDTH + 4, top),
		Size = UDim2.fromOffset(STRIP_WIDTH, FIELD_HEIGHT),
		Parent = popup.Body,
	}, {
		New("UIGradient", {
			Rotation = 90,
			Color = ColorSequence.new({
				ColorSequenceKeypoint.new(0.00, Color3.fromRGB(255, 0, 0)),
				ColorSequenceKeypoint.new(0.17, Color3.fromRGB(255, 255, 0)),
				ColorSequenceKeypoint.new(0.33, Color3.fromRGB(0, 255, 0)),
				ColorSequenceKeypoint.new(0.50, Color3.fromRGB(0, 255, 255)),
				ColorSequenceKeypoint.new(0.67, Color3.fromRGB(0, 0, 255)),
				ColorSequenceKeypoint.new(0.83, Color3.fromRGB(255, 0, 255)),
				ColorSequenceKeypoint.new(1.00, Color3.fromRGB(255, 0, 0)),
			}),
		}),
	})

	-- Thin white line with a black outline, so it reads over every hue.
	local hueCursor = New("Frame", {
		Name = "HueCursor",
		BackgroundColor3 = Color3.new(1, 1, 1),
		BorderSizePixel = 0,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.new(0.5, 0, 0, 0),
		Size = UDim2.new(1, 2, 0, 1),
		ZIndex = 5,
		Parent = hue,
	}, {
		New("UIStroke", {
			Color = Color3.new(0, 0, 0),
			Thickness = 1,
			LineJoinMode = Enum.LineJoinMode.Miter,
		}),
	})

	local alphaStrip, alphaCursor
	if useAlpha then
		alphaStrip = New("Frame", {
			Name = "Alpha",
			BackgroundColor3 = Color3.new(1, 1, 1),
			BorderSizePixel = 0,
			Position = UDim2.fromOffset(4, top + FIELD_HEIGHT + 4),
			Size = UDim2.fromOffset(FIELD_WIDTH + 4 + STRIP_WIDTH, STRIP_WIDTH),
			Parent = popup.Body,
		}, {
			New("UIGradient", {
				Color = ColorSequence.new(Color3.new(1, 1, 1), Color3.new(0, 0, 0)),
			}),
		})

		alphaCursor = New("Frame", {
			Name = "AlphaCursor",
			BackgroundColor3 = Color3.new(1, 1, 1),
			BorderSizePixel = 0,
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.new(1, 0, 0.5, 0),
			Size = UDim2.new(0, 1, 1, 2),
			ZIndex = 5,
			Parent = alphaStrip,
		}, {
			New("UIStroke", {
				Color = Color3.new(0, 0, 0),
				Thickness = 1,
				LineJoinMode = Enum.LineJoinMode.Miter,
			}),
		})
	end

	local hexRow = New("Frame", {
		Name = "HexRow",
		BackgroundTransparency = 1,
		Position = UDim2.fromOffset(
			4,
			top + FIELD_HEIGHT + 4 + (useAlpha and (STRIP_WIDTH + 4) or 0)
		),
		Size = UDim2.fromOffset(FIELD_WIDTH + 4 + STRIP_WIDTH, Metrics.TextboxHeight),
		Parent = popup.Body,
	})

	local _, hexBody = Utils.Panel({
		Size = UDim2.fromScale(1, 1),
		Parent = hexRow,
	})

	local hexInput = New("TextBox", {
		BackgroundTransparency = 1,
		ClearTextOnFocus = false,
		Size = UDim2.new(1, -4, 1, 0),
		Position = UDim2.fromOffset(2, 0),
		Text = "#" .. Utils.ToHex(default),
		TextSize = Metrics.TextBase,
		TextXAlignment = Enum.TextXAlignment.Center,
		Parent = hexBody,
	})
	ApplyFont(hexInput)
	Library:Bind(hexInput, "TextColor3", "TextColor")
	Utils.Outline(hexInput)

	local h, s, v = default:ToHSV()

	local element: any = {
		Type = "Colorpicker",
		Frame = holder,
		Swatch = swatchBody,
		Popup = popup,
		Callback = callback,
		Value = default,
		Alpha = useAlpha and (tonumber(Field(options, "AlphaValue", 1)) or 1) or 1,
		Hue = h,
		Saturation = s,
		Brightness = v,
	}

	--[[
		The swatch shows the picked colour, so it owns its background. Panel bound
		that property to the Background theme key, and this painter replaces that
		binding: otherwise the next repaint paints the panel colour over the
		swatch and every picker in the UI turns grey.
	]]
	local swatchPainter = Library:Paint(swatchBody, "BackgroundColor3", function()
		return element.Value
	end)

	--[[
		The swatch can be drawn as a gradient of the picked colour rather than a
		flat block, matching the way every other filled surface in the design is
		shaded. Both the switch and the depth are settings, and every swatch is
		registered so changing them updates the ones already on screen.
	]]
	local swatchGradient = Utils.Gradient(swatchBody, Color3.new(1, 1, 1), Color3.new(1, 1, 1))

	local function refreshSwatchGradient()
		if Library.Settings.PickerGradient == false then
			swatchGradient.Color = ColorSequence.new(Color3.new(1, 1, 1), Color3.new(1, 1, 1))
			return
		end

		local shade = tonumber(Library.Settings.PickerGradientShade) or 0.45
		swatchGradient.Color = ColorSequence.new(Color3.new(1, 1, 1), Color3.new(shade, shade, shade))
	end

	table.insert(Library.SwatchGradients, refreshSwatchGradient)
	refreshSwatchGradient()

	local function apply(skipCallback)
		local color = Color3.fromHSV(element.Hue, element.Saturation, element.Brightness)
		element.Value = color

		swatchPainter.Apply()
		field.BackgroundColor3 = Color3.fromHSV(element.Hue, 1, 1)
		cursor.Position = UDim2.fromScale(element.Saturation, 1 - element.Brightness)
		hueCursor.Position = UDim2.new(0.5, 0, element.Hue, 0)
		hexInput.Text = "#" .. Utils.ToHex(color)

		if alphaStrip then
			alphaStrip.BackgroundColor3 = color
			alphaCursor.Position = UDim2.new(element.Alpha, 0, 0.5, 0)
			swatchBody.BackgroundTransparency = 1 - element.Alpha
		end

		if element.Flag then
			Library.Flags[element.Flag] = color
			if useAlpha then
				Library.Flags[element.Flag .. "_alpha"] = element.Alpha
			end
		end

		--[[
			A colour chosen by hand becomes the new animation base, so the
			animation keeps cycling around what was just picked. Frames produced
			by the animation itself are excluded, or the base would drift.
		]]
		if not element.Animating and element.Animation and element.Animation ~= "Off" then
			element.AnimationBase = color
		end

		if not skipCallback and element.Callback then
			local ok, err = pcall(element.Callback, color, element.Alpha)
			if not ok then
				Library:Notify(string.format("callback error: %s", tostring(err)))
			end
		end
	end

	function element:Set(color, alpha, skipCallback)
		if typeof(color) == "string" then
			color = Utils.FromHex(color)
		end
		if typeof(color) == "Color3" then
			element.Hue, element.Saturation, element.Brightness = color:ToHSV()
		end
		if alpha ~= nil then
			element.Alpha = Utils.Clamp(tonumber(alpha) or 1, 0, 1)
		end
		apply(skipCallback)
		return element
	end

	function element:Get()
		return element.Value, element.Alpha
	end

	-- Drag handling shared by the field, hue strip and alpha strip.
	local function bindDrag(target, handler)
		local dragging = false

		Library:Connect(target.InputBegan, function(input)
			if input.UserInputType ~= Enum.UserInputType.MouseButton1
				and input.UserInputType ~= Enum.UserInputType.Touch then
				return
			end
			dragging = true
			handler(input.Position)
		end)

		Library:Connect(target.InputEnded, function(input)
			if input.UserInputType == Enum.UserInputType.MouseButton1
				or input.UserInputType == Enum.UserInputType.Touch then
				dragging = false
			end
		end)

		Library:Connect(UserInputService.InputChanged, function(input)
			if not dragging then
				return
			end
			if input.UserInputType == Enum.UserInputType.MouseMovement
				or input.UserInputType == Enum.UserInputType.Touch then
				handler(input.Position)
			end
		end)

		Library:Connect(UserInputService.InputEnded, function(input)
			if input.UserInputType == Enum.UserInputType.MouseButton1 then
				dragging = false
			end
		end)
	end

	bindDrag(field, function(position)
		local origin = field.AbsolutePosition
		local size = field.AbsoluteSize
		element.Saturation = Utils.Clamp((position.X - origin.X) / math.max(1, size.X), 0, 1)
		element.Brightness = 1 - Utils.Clamp((position.Y - origin.Y) / math.max(1, size.Y), 0, 1)
		apply()
	end)

	bindDrag(hue, function(position)
		local origin = hue.AbsolutePosition
		local size = hue.AbsoluteSize
		element.Hue = Utils.Clamp((position.Y - origin.Y) / math.max(1, size.Y), 0, 1)
		apply()
	end)

	if alphaStrip then
		bindDrag(alphaStrip, function(position)
			local origin = alphaStrip.AbsolutePosition
			local size = alphaStrip.AbsoluteSize
			element.Alpha = Utils.Clamp((position.X - origin.X) / math.max(1, size.X), 0, 1)
			apply()
		end)
	end

	Library:Connect(hexInput.FocusLost, function()
		local parsed = Utils.FromHex(hexInput.Text)
		if parsed then
			element:Set(parsed)
		else
			hexInput.Text = "#" .. Utils.ToHex(element.Value)
		end
	end)

	--[[
		Animation controls, inside the picker itself.

		SetAnimated writes the colour straight through without touching the
		animation base, so the mode keeps cycling around the colour that was
		originally chosen instead of drifting away from it.
	]]
	element.Animation = "Off"
	element.AnimationSpeed = 1
	element.AnimationBase = element.Value

	function element.SetAnimated(color)
		element.Animating = true
		element.Hue, element.Saturation, element.Brightness = color:ToHSV()
		apply()
		element.Animating = false
	end

	local animArea = New("Frame", {
		Name = "Animation",
		BackgroundTransparency = 1,
		Position = UDim2.fromOffset(
			4,
			top + FIELD_HEIGHT + 4 + (useAlpha and (STRIP_WIDTH + 4) or 0) + Metrics.TextboxHeight + 2
		),
		Size = UDim2.fromOffset(FIELD_WIDTH + 4 + STRIP_WIDTH, ANIMATION_HEIGHT - 4),
		Parent = popup.Body,
	})

	local animContainer = Library:MakeContainer(animArea)

	animContainer:Dropdown({
		Name = "Animation",
		Options = PICKER_ANIMATIONS,
		Default = "Off",
		MaxVisible = 5,
		Callback = function(mode)
			element.Animation = mode

			if mode == "Off" then
				local index = table.find(Library.AnimatedPickers, element)
				if index then
					table.remove(Library.AnimatedPickers, index)
				end
				-- Snap back to the colour the animation was built around.
				if typeof(element.AnimationBase) == "Color3" then
					element:Set(element.AnimationBase)
				end
			else
				element.AnimationBase = element.Value
				if not table.find(Library.AnimatedPickers, element) then
					table.insert(Library.AnimatedPickers, element)
				end
				StartPickerLoop()
			end
		end,
	})

	animContainer:Slider({
		Name = "Speed",
		Min = 0.1,
		Max = 5,
		Interval = 0.1,
		Default = 1,
		Callback = function(value)
			element.AnimationSpeed = value
		end,
	})

	--[[
		Second colour, used by Lerp and Blink. It is a hex field with a preview
		swatch rather than a nested picker: a picker inside a picker would need a
		popup inside a popup for no real gain.
	]]
	element.ColourB = Utils.Multiply(element.Value, 0.4)

	local secondRow = animContainer:Row(Metrics.TextboxHeight)

	Utils.Text({
		Size = UDim2.new(0, 58, 1, 0),
		Text = "2nd colour",
		ThemeKey = "CaptionText",
		Parent = secondRow,
	})

	local _, secondPreview = Utils.Panel({
		Position = UDim2.fromOffset(60, 2),
		Size = UDim2.fromOffset(Metrics.SwatchWidth, Metrics.SwatchHeight),
		Parent = secondRow,
	})
	secondPreview.BackgroundColor3 = element.ColourB
	-- Painted flat, so a theme repaint cannot overwrite the chosen colour.
	Library:Paint(secondPreview, "BackgroundColor3", function()
		return element.ColourB
	end)

	local secondField = New("Frame", {
		BackgroundTransparency = 1,
		Position = UDim2.fromOffset(92, 0),
		Size = UDim2.new(1, -92, 1, 0),
		Parent = secondRow,
	})

	local _, secondBody = Utils.Panel({
		Size = UDim2.fromScale(1, 1),
		Parent = secondField,
	})

	local secondInput = New("TextBox", {
		BackgroundTransparency = 1,
		ClearTextOnFocus = false,
		Position = UDim2.fromOffset(2, 0),
		Size = UDim2.new(1, -4, 1, 0),
		Text = "#" .. Utils.ToHex(element.ColourB),
		TextSize = Metrics.TextBase,
		TextXAlignment = Enum.TextXAlignment.Center,
		Parent = secondBody,
	})
	ApplyFont(secondInput)
	Utils.Outline(secondInput)
	Library:Bind(secondInput, "TextColor3", "TextColor")

	Library:Connect(secondInput.FocusLost, function()
		local parsed = Utils.FromHex(secondInput.Text)
		if parsed then
			element.ColourB = parsed
		end
		secondInput.Text = "#" .. Utils.ToHex(element.ColourB)
		secondPreview.BackgroundColor3 = element.ColourB
	end)

	function element:SetSecondColour(color)
		if typeof(color) == "string" then
			color = Utils.FromHex(color)
		end
		if typeof(color) == "Color3" then
			element.ColourB = color
			secondInput.Text = "#" .. Utils.ToHex(color)
			secondPreview.BackgroundColor3 = color
		end
		return element
	end

	local hitbox = Utils.Hitbox(holder, 25)
	Library:Connect(hitbox.MouseButton1Click, function()
		popup:Toggle()
	end)

	apply(true)
	return element
end

-- Docked onto a toggle row.
AttachColorpicker = function(host, options)
	local holder = host:Dock("Colorpicker", Metrics.SwatchWidth, Metrics.SwatchHeight)
	local element = BuildColorpicker(holder, options, host.Row)
	element.Container = host.Container
	host.Container:Register(element, Field(options or {}, "Flag", nil))
	return element
end

-- Standalone row: label on the left, swatch on the right.
function Container:Colorpicker(options)
	options = options or {}

	local row = self:Row(Metrics.RowHeight)

	Utils.Text({
		Size = UDim2.new(1, -(Metrics.SwatchWidth + 4), 1, 0),
		Text = tostring(Field(options, "Name", "color")),
		Parent = row,
	})

	local holder = New("Frame", {
		Name = "Swatch",
		AnchorPoint = Vector2.new(1, 0.5),
		BackgroundTransparency = 1,
		Position = UDim2.new(1, 0, 0.5, 0),
		Size = UDim2.fromOffset(Metrics.SwatchWidth, Metrics.SwatchHeight),
		Parent = row,
	})

	local element = BuildColorpicker(holder, options, row)
	element.Row = row
	element.Container = self

	return self:Register(element, Field(options, "Flag", nil))
end

Container.ColorPicker = Container.Colorpicker

--// Keybind ///////////////////////////////////////////////////////////////////

local KEYBIND_MODES = { "Always", "Toggle", "Hold" }

--[[
	Keybind field. Left click starts capture, right click cycles the mode.
	Modes match what cheat menus usually offer:
		Always - fires on every press
		Toggle - flips a boolean and reports it
		Hold   - true while held, false on release
]]
-- `host` is the toggle this keybind is docked onto, when there is one.
local function BuildKeybind(holder, options, label, host)
	options = options or {}

	local callback = Field(options, "Callback", nil)
	local mode = tostring(Field(options, "Mode", "Toggle"))
	local showInList = Field(options, "ShowInList", false) and true or false
	local default = Field(options, "Default", Field(options, "Key", nil))

	local text = Utils.Text({
		Size = UDim2.fromScale(1, 1),
		TextXAlignment = Enum.TextXAlignment.Right,
		Text = "[ - ]",
		Parent = holder,
	})

	--[[
		The slot follows the text, so a long key name is not clipped and a short
		one leaves no gap. Docked rows are re-laid out whenever the width changes.
	]]
	Library:Connect(text:GetPropertyChangedSignal("TextBounds"), function()
		local width = math.max(Metrics.SwatchWidth, math.ceil(text.TextBounds.X) + 2)
		if holder.Size.X.Offset ~= width then
			holder.Size = UDim2.fromOffset(width, holder.Size.Y.Offset)
			if host and host.Relayout then
				host.Relayout()
			end
		end
	end)

	local element: any = {
		Type = "Keybind",
		Frame = holder,
		Label = text,
		Callback = callback,
		Mode = table.find(KEYBIND_MODES, mode) and mode or "Toggle",
		Key = nil,
		Active = false,
		Capturing = false,
		ShowInList = showInList,
		Name = tostring(Field(options, "Name", label or "keybind")),
	}

	--[[
		The field shows the key, and its colour shows whether the feature is
		currently on: accent while active, dim otherwise. Hold and Toggle both
		report a state, Always fires and does not stay on, so it is never lit.
	]]
	local function render()
		if element.Capturing then
			text.Text = "[...]"
			return
		end

		--[[
			Bracketed key only. The mode is shown by the right click menu and the
			state by the colour, so the field stays as narrow as the design's
			27px slot allows.
		]]
		text.Text = string.format("[ %s ]", element.Key and Utils.KeyName(element.Key) or "-")
	end



	function element:Set(key, skipCallback)
		if typeof(key) == "string" then
			-- Accept plain names like "LeftShift" or "MB1".
			local found
			for _, item in Enum.KeyCode:GetEnumItems() do
				if item.Name:lower() == key:lower() or Utils.KeyName(item):lower() == key:lower() then
					found = item
					break
				end
			end
			key = found
		end

		element.Key = typeof(key) == "EnumItem" and key or nil

		-- Dropping the key also drops any active state it was holding.
		if not element.Key then
			element.Active = false
		end

		render()
		if element.StatePainter then
			element.StatePainter.Apply()
		end

		-- Lets the theme window persist a bind without owning the element.
		if element.OnKeyChanged then
			pcall(element.OnKeyChanged, element.Key)
		end

		if element.Flag then
			Library.Flags[element.Flag] = element.Key and element.Key.Name or nil
			Library.Flags[element.Flag .. "_mode"] = element.Mode
		end

		Library:RefreshKeybindList()

		if not skipCallback and element.Callback and element.Mode == "Always" then
			-- nothing to report until the key is pressed
		end

		return element
	end

	function element:SetMode(newMode)
		if table.find(KEYBIND_MODES, newMode) then
			element.Mode = newMode

			-- Switching mode drops any state the old mode was holding.
			element.Active = false

			if element.Flag then
				Library.Flags[element.Flag .. "_mode"] = newMode
			end

			if element.Render then
				element.Render()
			end
			Library:RefreshKeybindList()
		end
		return element
	end

	function element:Get()
		return element.Key, element.Mode
	end

	function element:GetState()
		return element.Active
	end

	--[[
		The field is lit while the bind is active, so whether the feature it
		drives is running is never in doubt:

			accent - active (Toggle is on, or Hold is being held)
			white  - bound but idle
			dim    - not bound
			yellow - waiting for a key
	]]
	local statePainter = Library:Paint(text, "TextColor3", function()
		if element.Capturing then
			return Themes.Current.TextColorMid
		elseif element.Active then
			return Themes.Current.Accent
		elseif element.Key then
			return Themes.Current.TextColor
		end
		return Themes.Current.InactiveButtonText
	end, { "Accent", "TextColor", "TextColorMid", "InactiveButtonText" })

	element.StatePainter = statePainter

	local function repaint()
		render()
		statePainter.Apply()
	end

	element.Render = repaint

	local function fire(state)
		element.Active = state and true or false
		repaint()

		--[[
			The row the bind belongs to lights up as well, so the feature reads as
			running from its own label rather than only from the key field.
		]]
		if host then
			host.BindActive = element.Active
			if host.Refresh then
				host.Refresh(false)
			end
		end

		if element.Callback then
			local ok, err = pcall(element.Callback, element.Active)
			if not ok then
				Library:Notify(string.format("callback error: %s", tostring(err)))
			end
		end
		Library:RefreshKeybindList()
	end

	local hitbox = Utils.Hitbox(holder, 25)

	Library:Connect(hitbox.MouseButton1Click, function()
		element.Capturing = true
		repaint()
	end)

	--[[
		Right click opens a small mode menu rather than cycling blindly, so the
		three modes are visible and the current one is marked.
	]]
	-- Plus the panel chrome, or the last mode would be clipped.
	local modeRow = 14
	local modePopup = Utils.Popup(holder, 70, #KEYBIND_MODES * modeRow + 8)
	local modeButtons = {}

	local modePainters = {}

	for index, modeName in KEYBIND_MODES do
		local button = New("TextButton", {
			Name = modeName,
			AutoButtonColor = false,
			BackgroundTransparency = 1,
			Position = UDim2.fromOffset(2, 2 + (index - 1) * modeRow),
			Size = UDim2.new(1, -4, 0, modeRow),
			Text = modeName,
			TextSize = Metrics.TextBase,
			TextXAlignment = Enum.TextXAlignment.Center,
			Parent = modePopup.Body,
		})
		ApplyFont(button)
		Utils.Outline(button)

		modeButtons[modeName] = button

		-- The active mode prints in the accent colour.
		modePainters[index] = Library:Paint(button, "TextColor3", function()
			return element.Mode == modeName and Themes.Current.Accent
				or Themes.Current.InactiveButtonText
		end, { "Accent", "InactiveButtonText" })

		Library:Connect(button.MouseButton1Click, function()
			element:SetMode(modeName)
			for _, painter in modePainters do
				painter.Apply()
			end
			modePopup:Close()
		end)
	end

	element.ModePopup = modePopup

	Library:Connect(hitbox.MouseButton2Click, function()
		modePopup:Toggle()
	end)

	Library:Connect(UserInputService.InputBegan, function(input, processed)
		-- Capture mode swallows the next key, including mouse buttons.
		--[[
			Capture mode swallows the next key. Pressing the key that is already
			bound clears the bind, so the same gesture both sets and unsets it,
			and Escape or Backspace clear it outright.
		]]
		if element.Capturing then
			local captured

			if input.UserInputType == Enum.UserInputType.Keyboard then
				captured = input.KeyCode
				if captured == Enum.KeyCode.Backspace or captured == Enum.KeyCode.Escape then
					captured = nil
				end
			elseif input.UserInputType == Enum.UserInputType.MouseButton2
				or input.UserInputType == Enum.UserInputType.MouseButton3 then
				captured = input.UserInputType
			else
				return
			end

			element.Capturing = false

			-- Same key twice unbinds it.
			if captured ~= nil and captured == element.Key then
				captured = nil
			end

			element.Active = false
			element:Set(captured)
			repaint()
			return
		end

		if processed or not element.Key then
			return
		end

		local matched = (input.KeyCode == element.Key) or (input.UserInputType == element.Key)
		if not matched then
			return
		end

		if element.Mode == "Toggle" then
			fire(not element.Active)
		elseif element.Mode == "Hold" then
			fire(true)
		else
			fire(true)
		end
	end)

	Library:Connect(UserInputService.InputEnded, function(input)
		if not element.Key or element.Mode ~= "Hold" then
			return
		end
		local matched = (input.KeyCode == element.Key) or (input.UserInputType == element.Key)
		if matched then
			fire(false)
		end
	end)

	if default ~= nil then
		element:Set(default, true)
	else
		render()
	end

	if showInList then
		table.insert(Library.KeybindList, element)
		Library:RefreshKeybindList()
	end

	return element
end

AttachKeybind = function(host, options)
	local holder = host:Dock("Keybind", Metrics.SwatchWidth, Metrics.SwatchHeight)
	local element = BuildKeybind(holder, options, host.Label.Text, host)
	element.Container = host.Container
	host.Container:Register(element, Field(options or {}, "Flag", nil))
	return element
end

function Container:Keybind(options)
	options = options or {}

	local row = self:Row(Metrics.RowHeight)

	Utils.Text({
		Size = UDim2.new(1, -(Metrics.SwatchWidth + 4), 1, 0),
		Text = tostring(Field(options, "Name", "keybind")),
		Parent = row,
	})

	local holder = New("Frame", {
		Name = "Key",
		AnchorPoint = Vector2.new(1, 0.5),
		BackgroundTransparency = 1,
		Position = UDim2.new(1, 0, 0.5, 0),
		Size = UDim2.fromOffset(Metrics.SwatchWidth, Metrics.SwatchHeight),
		Parent = row,
	})

	local element = BuildKeybind(holder, options, tostring(Field(options, "Name", "keybind")))
	element.Row = row
	element.Container = self

	return self:Register(element, Field(options, "Flag", nil))
end


--// Folding groups ////////////////////////////////////////////////////////////

--[[
	Nested container that lives directly under its toggle. Closing it hides the
	frame and drops its height to zero, so the section's list layout collapses
	the gap as well.
]]
BuildToggleGroup = function(toggle, parent)
	local frame = New("Frame", {
		Name = "Group",
		BackgroundTransparency = 1,
		-- Sits between its toggle and the next row, thanks to the step of ten.
		LayoutOrder = toggle.Row.LayoutOrder + 5,
		Size = UDim2.new(1, 0, 0, 0),
		Visible = false,
		Parent = parent.Content,
	})

	-- Nested content is indented so nesting depth reads at a glance.
	local content = New("Frame", {
		Name = "Content",
		BackgroundTransparency = 1,
		Position = UDim2.fromOffset(Metrics.ToggleSize + 3, 0),
		Size = UDim2.new(1, -(Metrics.ToggleSize + 3), 1, 0),
		Parent = frame,
	}, {
		New("UIListLayout", {
			FillDirection = Enum.FillDirection.Vertical,
			SortOrder = Enum.SortOrder.LayoutOrder,
			Padding = UDim.new(0, Metrics.RowGap),
		}),
	})

	local layout = content:FindFirstChildOfClass("UIListLayout")

	local group = setmetatable({
		Name = toggle.Label.Text .. "Group",
		Window = parent.Window,
		Tab = parent.Tab,
		Frame = frame,
		Content = content,
		Layout = layout,
		Elements = {},
		Depth = (parent.Depth or 0) + 1,
		--[[
			Back reference to the toggle that owns this group. Deliberately not
			called "Toggle": that name belongs to Container:Toggle, and a field
			under the same name shadows the method, so nested toggles would try
			to call a table.
		]]
		OwnerToggle = toggle,
		FollowState = true,
		IsOpen = false,
	}, Container)

	local function resize()
		if not group.IsOpen then
			frame.Size = UDim2.new(1, 0, 0, 0)
			return
		end
		frame.Size = UDim2.new(1, 0, 0, layout.AbsoluteContentSize.Y)
	end

	Library:Connect(layout:GetPropertyChangedSignal("AbsoluteContentSize"), resize)

	function group:SetOpen(open)
		group.IsOpen = open and true or false
		-- Empty groups stay hidden so they cost no vertical space.
		frame.Visible = group.IsOpen and #group.Elements > 0
		resize()
		return group
	end

	group.Resize = resize
	return group
end

--// Plain window container ////////////////////////////////////////////////////

--[[
	Window:Container() gives a window the full element API without tabs or
	sections, which is what the built-in windows in the design use: their
	contents sit directly under the title.
]]
function Window:Container(options)
	options = options or {}

	local padding = tonumber(Field(options, "Padding", 4)) or 4

	local content = New("Frame", {
		Name = "PlainContent",
		BackgroundTransparency = 1,
		Position = UDim2.fromOffset(padding, 0),
		Size = UDim2.new(1, -padding * 2, 1, 0),
		Parent = self.Content,
	}, {
		New("UIListLayout", {
			FillDirection = Enum.FillDirection.Vertical,
			SortOrder = Enum.SortOrder.LayoutOrder,
			Padding = UDim.new(0, tonumber(Field(options, "Gap", Metrics.RowGap)) or Metrics.RowGap),
		}),
	})

	local layout = content:FindFirstChildOfClass("UIListLayout")

	local container = setmetatable({
		Name = self.Name,
		Window = self,
		Frame = content,
		Content = content,
		Layout = layout,
		Elements = {},
		Depth = 0,
	}, Container)

	self.Root = container

	-- Windows that grow with their contents, used by the keybind list.
	if Field(options, "AutoHeight", false) then
		local extra = Metrics.WindowTitleHeight + 2 + padding * 2
		local function resize()
			self.Frame.Size = UDim2.fromOffset(
				self.Frame.Size.X.Offset,
				layout.AbsoluteContentSize.Y + extra
			)
		end
		Library:Connect(layout:GetPropertyChangedSignal("AbsoluteContentSize"), resize)
		resize()
	end

	return container
end

--// Configs ///////////////////////////////////////////////////////////////////

local CONFIG_FOLDER = "tallin/configs"

--[[
	Flag values are JSON encoded, so Color3 and EnumItem have to be wrapped in
	a tagged table on the way out and rebuilt on the way in.
]]
local function Serialize(value)
	local kind = typeof(value)

	if kind == "Color3" then
		return {
			__type = "Color3",
			R = math.floor(value.R * 255 + 0.5),
			G = math.floor(value.G * 255 + 0.5),
			B = math.floor(value.B * 255 + 0.5),
		}
	elseif kind == "EnumItem" then
		return {
			__type = "EnumItem",
			Enum = tostring(value.EnumType),
			Name = value.Name,
		}
	elseif kind == "table" then
		local copy = {}
		for key, item in value do
			copy[tostring(key)] = Serialize(item)
		end
		return { __type = "table", Values = copy }
	end

	return value
end

local function Deserialize(value)
	if type(value) ~= "table" then
		return value
	end

	if value.__type == "Color3" then
		return Color3.fromRGB(value.R or 0, value.G or 0, value.B or 0)
	elseif value.__type == "EnumItem" then
		-- Only KeyCode and UserInputType are ever stored.
		local ok, item = pcall(function()
			if value.Enum == "Enum.KeyCode" then
				return Enum.KeyCode[value.Name]
			elseif value.Enum == "Enum.UserInputType" then
				return Enum.UserInputType[value.Name]
			end
			return nil
		end)
		return ok and item or nil
	elseif value.__type == "table" then
		local copy = {}
		for key, item in value.Values or {} do
			copy[key] = Deserialize(item)
		end
		return copy
	end

	return value
end

function Library:GetConfigPath(name)
	return string.format("%s/%s.json", CONFIG_FOLDER, tostring(name))
end

function Library:GetConfigs()
	local names = {}

	if not Compat.HasFilesystem then
		return names
	end

	FS.EnsureFolder("tallin")
	FS.EnsureFolder(CONFIG_FOLDER)

	for _, path in FS.ListFiles(CONFIG_FOLDER) do
		local name = tostring(path):match("([^/\\]+)%.json$")
		if name then
			table.insert(names, name)
		end
	end

	table.sort(names)
	return names
end

--[[
	Snapshots every flag. Element values are read from the elements themselves
	rather than from Library.Flags, so derived entries like a picker's alpha and
	a keybind's mode travel with it.
]]
function Library:SaveConfig(name)
	if not name or tostring(name) == "" then
		Library:Notify("config name is empty")
		return false
	end
	if not Compat.HasFilesystem then
		Library:Notify("executor has no file access")
		return false
	end

	local data = {}

	for flag, value in Library.Flags do
		data[flag] = Serialize(value)
	end

	for flag, element in Library.Elements do
		if element.Type == "Colorpicker" then
			local color, alpha = element:Get()
			data[flag] = Serialize(color)
			data[flag .. "_alpha"] = alpha
		elseif element.Type == "Keybind" then
			local key, mode = element:Get()
			data[flag] = key and Serialize(key) or nil
			data[flag .. "_mode"] = mode
		end
	end

	local encoded
	local ok = pcall(function()
		encoded = HttpService:JSONEncode(data)
	end)
	if not ok or not encoded then
		Library:Notify("failed to encode config")
		return false
	end

	FS.EnsureFolder("tallin")
	FS.EnsureFolder(CONFIG_FOLDER)

	local written = FS.WriteFile(Library:GetConfigPath(name), encoded)
	if not written then
		Library:Notify("failed to write config")
		return false
	end

	Library:Notify(string.format("saved config %s", tostring(name)))
	Library:RefreshConfigList()
	return true
end

function Library:LoadConfig(name)
	local path = Library:GetConfigPath(name)

	if not FS.IsFile(path) then
		Library:Notify(string.format("config %s not found", tostring(name)))
		return false
	end

	local ok, contents = FS.ReadFile(path)
	if not ok or type(contents) ~= "string" then
		Library:Notify("failed to read config")
		return false
	end

	local decoded
	local decodedOk = pcall(function()
		decoded = HttpService:JSONDecode(contents)
	end)
	if not decodedOk or type(decoded) ~= "table" then
		Library:Notify("config is corrupt")
		return false
	end

	Library:ApplyFlags(decoded)
	Library:Notify(string.format("loaded config %s", tostring(name)))
	return true
end

-- Pushes a decoded table of flags into the matching elements.
function Library:ApplyFlags(data)
	for flag, raw in data do
		-- Suffixed entries are applied together with their parent element.
		if not (flag:match("_alpha$") or flag:match("_mode$")) then
			local element = Library.Elements[flag]
			local value = Deserialize(raw)

			if element and element.Set then
				local applied = pcall(function()
					if element.Type == "Colorpicker" then
						element:Set(value, data[flag .. "_alpha"])
					elseif element.Type == "Keybind" then
						element:Set(value)
						if data[flag .. "_mode"] then
							element:SetMode(data[flag .. "_mode"])
						end
					else
						element:Set(value)
					end
				end)
				if not applied then
					Library.Flags[flag] = value
				end
			else
				Library.Flags[flag] = value
			end
		end
	end

	return true
end

function Library:DeleteConfig(name)
	local path = Library:GetConfigPath(name)

	if not FS.IsFile(path) then
		Library:Notify(string.format("config %s not found", tostring(name)))
		return false
	end

	FS.DeleteFile(path)
	Library:Notify(string.format("deleted config %s", tostring(name)))
	Library:RefreshConfigList()
	return true
end


--// Theme persistence /////////////////////////////////////////////////////////

local THEME_FOLDER = "tallin/themes"

-- Every key the library actually paints with, which is what the theme window
-- offers for editing. Themes.Order is only the subset the design listed.
function Library:GetThemeKeys()
	local keys = {}
	local seen = {}

	for _, key in Themes.Order do
		if Themes.Default[key] ~= nil and not seen[key] then
			seen[key] = true
			table.insert(keys, key)
		end
	end

	local rest = {}
	for key in Themes.Default do
		if not seen[key] then
			table.insert(rest, key)
		end
	end
	table.sort(rest)

	for _, key in rest do
		table.insert(keys, key)
	end

	return keys
end

function Library:GetThemes()
	-- The design default, then the built-in palettes, then anything saved.
	local names = { "DEFAULT" }

	for _, name in Themes.PaletteOrder do
		table.insert(names, name)
	end

	if not Compat.HasFilesystem then
		return names
	end

	FS.EnsureFolder("tallin")
	FS.EnsureFolder(THEME_FOLDER)

	local custom = {}
	for _, path in FS.ListFiles(THEME_FOLDER) do
		local name = tostring(path):match("([^/\\]+)%.json$")
		if name then
			table.insert(custom, name)
		end
	end
	table.sort(custom)

	for _, name in custom do
		table.insert(names, name)
	end

	return names
end

--[[
	Expands a nine colour palette into the full theme.

	Everything the shorthand does not carry is derived from what it does: shades
	come from multiplying, and the risk tints and most syntax colours keep the
	design's values, since a palette says nothing about them.
]]
function Library:ExpandPalette(name)
	local packed = Themes.Palettes[name]
	if not packed then
		return nil
	end

	local parts = string.split(packed, " ")
	local function hex(index)
		return Utils.FromHex(parts[index]) or Color3.new()
	end

	local outline = hex(1)
	local accent = hex(2)
	local lightText = hex(3)
	local darkText = hex(4)
	local lightContrast = hex(5)
	local cursorOutline = hex(6)
	local darkContrast = hex(7)
	local textBorder = hex(8)
	local inline = hex(9)

	return {
		-- text
		TextColor = lightText,
		TextOutline = textBorder,
		SectionNameText = darkText,
		CaptionText = darkText,
		InactiveButtonText = Utils.Multiply(darkText, 0.72),
		DisabledText = Utils.Multiply(darkText, 0.45),
		TextColorUnsafe = Themes.Default.TextColorUnsafe,
		TextColorMid = Themes.Default.TextColorMid,

		-- accent
		Accent = accent,
		AccentToggleShade = Utils.Multiply(accent, 0.571),

		-- chrome
		Outline = outline,
		Border = inline,
		Background = darkContrast,
		InactiveTab = Utils.Multiply(darkText, 0.5),
		Shade = cursorOutline,
		TabTop = lightContrast,

		-- section panel
		SectionTop = Utils.Multiply(darkContrast, 0.85),
		SectionBottom = darkContrast,
		SectionHeaderTop = inline,
		SectionHeaderBottom = darkContrast,

		-- raised controls
		ToggleInactive = lightContrast,
		ToggleInactiveShade = Utils.Multiply(lightContrast, 0.45),

		-- left as designed: a palette says nothing about these
		PriorityFriendly = Themes.Default.PriorityFriendly,
		PriorityEnemy = Themes.Default.PriorityEnemy,
		SyntaxText = Themes.Default.SyntaxText,
		SyntaxComment = Themes.Default.SyntaxComment,
		SyntaxKeyword = accent,
		SyntaxString = Themes.Default.SyntaxString,
		SyntaxNumber = Themes.Default.SyntaxNumber,
		SyntaxGlobal = Themes.Default.SyntaxGlobal,
		SyntaxExecutor = Themes.Default.SyntaxExecutor,
		SyntaxOperator = darkText,
	}
end

function Library:LoadPalette(name)
	local expanded = Library:ExpandPalette(name)
	if not expanded then
		return false
	end

	--[[
		Accent only mode takes the palette's highlight and leaves everything else
		alone, which is how most people want to use these: the shape of the theme
		stays, the colour changes.
	]]
	if Library.Settings.ThemeAccentOnly then
		Themes.Pinned.AccentToggleShade = false
		Library:RefreshTheme("Accent", expanded.Accent)
		Library:RefreshTheme("SyntaxKeyword", expanded.SyntaxKeyword)
		Library:Notify(string.format("accent from %s", name))
		return true
	end

	-- A palette replaces the lot, so previously pinned keys are released.
	Themes.Pinned = {}

	for key, color in expanded do
		Themes.Current[key] = color
	end

	Library:Repaint()
	for index = #Library.Refreshers, 1, -1 do
		pcall(Library.Refreshers[index])
	end

	Library:Notify(string.format("theme %s", name))
	return true
end

-- Snapshots the palette. An animated accent is saved as its base colour, never
-- as whatever frame the animation happens to be on.
function Library:SerializeTheme()
	local data = {}

	for _, key in Library:GetThemeKeys() do
		local color = Themes.Current[key]
		if key == "Accent" and typeof(Library.AnimationBase) == "Color3" then
			color = Library.AnimationBase
		end
		data[key] = Serialize(color)
	end

	return data
end

function Library:SaveNamedTheme(name)
	if not name or tostring(name) == "" or tostring(name) == "DEFAULT" then
		Library:Notify("pick a name other than DEFAULT")
		return false
	end
	if not Compat.HasFilesystem then
		Library:Notify("executor has no file access")
		return false
	end

	local encoded
	local ok = pcall(function()
		encoded = HttpService:JSONEncode(Library:SerializeTheme())
	end)
	if not ok then
		return false
	end

	FS.EnsureFolder("tallin")
	FS.EnsureFolder(THEME_FOLDER)

	local written = FS.WriteFile(string.format("%s/%s.json", THEME_FOLDER, name), encoded)
	if written then
		Library:Notify(string.format("saved theme %s", tostring(name)))
		Library:RefreshThemeList()
	end

	return written and true or false
end

function Library:LoadNamedTheme(name)
	name = tostring(name)

	if name == "DEFAULT" then
		Library:SetAccentAnimation("Off")
		for key, color in Themes.Default do
			Themes.Current[key] = color
		end
		Themes.Pinned = {}
		Library:Repaint()
		for index = #Library.Refreshers, 1, -1 do
			pcall(Library.Refreshers[index])
		end
		Library:RefreshThemeList()
		Library:Notify("theme reset to default")
		return true
	end

	-- Built-in palettes are not files, so they are checked first.
	if Themes.Palettes[name] then
		local ok = Library:LoadPalette(name)
		if ok then
			Library:RefreshThemeList()
		end
		return ok
	end

	local path = string.format("%s/%s.json", THEME_FOLDER, name)
	if not FS.IsFile(path) then
		Library:Notify(string.format("theme %s not found", name))
		return false
	end

	local ok, contents = FS.ReadFile(path)
	if not ok or type(contents) ~= "string" then
		return false
	end

	local decoded
	local decodedOk = pcall(function()
		decoded = HttpService:JSONDecode(contents)
	end)
	if not decodedOk or type(decoded) ~= "table" then
		Library:Notify("theme file is corrupt")
		return false
	end

	for key, raw in decoded do
		local color = Deserialize(raw)
		if typeof(color) == "Color3" then
			Library:RefreshTheme(key, color)
		end
	end

	Library:RefreshThemeList()
	Library:Notify(string.format("loaded theme %s", name))
	return true
end

function Library:DeleteTheme(name)
	name = tostring(name)
	if name == "DEFAULT" then
		Library:Notify("the default theme cannot be deleted")
		return false
	end

	local path = string.format("%s/%s.json", THEME_FOLDER, name)
	if not FS.IsFile(path) then
		return false
	end

	FS.DeleteFile(path)
	Library:Notify(string.format("deleted theme %s", name))
	Library:RefreshThemeList()
	return true
end


function Library:SaveTheme()
	if not Compat.HasFilesystem then
		return false
	end

	local data = Library:SerializeTheme()

	local encoded
	local ok = pcall(function()
		encoded = HttpService:JSONEncode(data)
	end)
	if not ok then
		return false
	end

	FS.EnsureFolder("tallin")
	return FS.WriteFile(Library.ThemeFile, encoded) and true or false
end

function Library:LoadTheme()
	if not FS.IsFile(Library.ThemeFile) then
		return false
	end

	local ok, contents = FS.ReadFile(Library.ThemeFile)
	if not ok or type(contents) ~= "string" then
		return false
	end

	local decoded
	local decodedOk = pcall(function()
		decoded = HttpService:JSONDecode(contents)
	end)
	if not decodedOk or type(decoded) ~= "table" then
		return false
	end

	for key, raw in decoded do
		local color = Deserialize(raw)
		if typeof(color) == "Color3" then
			Library:RefreshTheme(key, color)
		end
	end

	return true
end

--// Unload ////////////////////////////////////////////////////////////////////

--[[
	Tears everything down: connections first so nothing fires mid teardown,
	then instances, then the caches that would otherwise leak into the next run.
]]
function Library:Unload()
	if Library.Unloaded then
		return
	end
	Library.Unloaded = true

	for _, connection in Library.Connections do
		pcall(function()
			connection:Disconnect()
		end)
	end
	table.clear(Library.Connections)

	if Library.UnloadCallback then
		pcall(Library.UnloadCallback)
	end

	if Library.ScreenGui then
		pcall(function()
			Library.ScreenGui:Destroy()
		end)
	end

	table.clear(Library.Instances)
	table.clear(Library.Elements)
	table.clear(Library.Windows)
	table.clear(Library.KeybindList)
	table.clear(Library.ThemeBindings)
	table.clear(Library.Refreshers)
	table.clear(Library.OpenPopups)

	local cache = Compat.getgenv()
	cache.TallinLibrary = nil
end

function Library:OnUnload(callback)
	Library.UnloadCallback = callback
	return Library
end

--// Menu keybind //////////////////////////////////////////////////////////////

--[[
	Opening and closing the menu. Slide tweens the whole holder a short way up
	and only hides it once the tween is done, so the menu leaves and returns
	smoothly. The persistent overlay is untouched either way.
]]
--[[
	Which transparency properties each class exposes. Fading the menu means
	driving all of them at once, since Roblox has no single opacity property for
	a subtree that would not also rasterise it and soften the text.
]]
local function TransparencyProperties(instance)
	if instance:IsA("TextLabel") or instance:IsA("TextButton") or instance:IsA("TextBox") then
		return { "TextTransparency", "BackgroundTransparency" }
	elseif instance:IsA("ImageLabel") or instance:IsA("ImageButton") then
		return { "ImageTransparency", "BackgroundTransparency" }
	elseif instance:IsA("ScrollingFrame") then
		return { "BackgroundTransparency", "ScrollBarImageTransparency" }
	elseif instance:IsA("Frame") or instance:IsA("CanvasGroup") then
		return { "BackgroundTransparency" }
	elseif instance:IsA("UIStroke") then
		return { "Transparency" }
	end
	return nil
end

--[[
	The resting transparency of every faded property, captured once. Fading then
	interpolates from that value to fully transparent, so nothing that was
	already semi-transparent (the tinted selection rows, the outlines) comes back
	looking wrong.
]]
local FadeBase = setmetatable({}, { __mode = "k" })

--[[
	Cached fade targets. Rebuilt only when `refresh` is true (at the start of a
	close transition) or when nothing has been cached yet. Between open/close
	cycles the set of instances rarely changes, so reusing the list avoids
	walking thousands of instances every frame of the fade.
]]

local function CollectFadeTargets(refresh)
	if not refresh and FadeTargetCache then
		return FadeTargetCache
	end

	local targets = {}
	local instances = Library.Instances
	local holder = Library.Holder
	local persistent = Library.Persistent

	for i = 1, #instances do
		local instance = instances[i]
		if typeof(instance) ~= "Instance" or not instance.Parent then
			continue
		end
		-- The persistent overlay is not part of the menu.
		if instance == persistent or persistent:IsAncestorOf(instance) then
			continue
		end
		if not (instance == holder or holder:IsAncestorOf(instance)) then
			continue
		end

		local properties = TransparencyProperties(instance)
		if not properties then
			continue
		end

		local base = FadeBase[instance]
		if refresh or not base then
			base = {}
			for _, property in properties do
				local ok, value = pcall(function()
					return (instance :: any)[property]
				end)
				if ok and type(value) == "number" then
					base[property] = value
				end
			end
			FadeBase[instance] = base
		end

		targets[#targets + 1] = { Instance = instance, Base = base }
	end

	FadeTargetCache = targets
	return targets
end

--[[
	Opening and closing the menu.

	Fade walks every tracked object once and drives its transparency from a
	single frame loop, which is how the reference libraries do it: the menu
	dissolves in place rather than sliding anywhere. Alpha 0 is fully visible,
	1 is gone.
]]
function Library:SetOpen(open, immediate)
	open = open and true or false
	Library.Open = open

	local transition = tostring(Library.Settings.MenuTransition or "Fade")
	local duration = immediate and 0 or (tonumber(Library.Settings.TweenDuration) or 0.18)

	-- Stop a transition that is still running.
	if Library.MenuFade then
		Library.MenuFade:Disconnect()
		Library.MenuFade = false
	end

	local function applyAlpha(targets, alpha)
		for _, target in targets do
			for property, base in target.Base do
				pcall(function()
					target.Instance[property] = base + (1 - base) * alpha
				end)
			end
		end
	end

	if transition == "Instant" or duration <= 0 then
		local targets = CollectFadeTargets(not open)
		applyAlpha(targets, 0)
		Library.Holder.Visible = open
		return Library
	end

	-- Closing reads the resting values first, since the menu is at rest then.
	local targets = CollectFadeTargets(not open)

	if open then
		Library.Holder.Visible = true
		applyAlpha(targets, 1)
	end

	local elapsed = 0
	local from = open and 1 or 0
	local to = open and 0 or 1

	Library.MenuFade = Library:Connect(RunService.RenderStepped, function(delta)
		elapsed += delta
		local progress = math.min(1, elapsed / duration)

		-- Ease out, matching the easing used by the rest of the transitions.
		local eased = 1 - (1 - progress) ^ 3
		applyAlpha(targets, from + (to - from) * eased)

		if progress < 1 then
			return
		end

		if Library.MenuFade then
			Library.MenuFade:Disconnect()
			Library.MenuFade = false
		end

		if not open then
			Library.Holder.Visible = false
			-- Restore the resting values so the next open starts clean.
			applyAlpha(targets, 0)
		end
	end)

	return Library
end

function Library:ToggleOpen()
	return Library:SetOpen(not Library.Open)
end

Library:Connect(UserInputService.InputBegan, function(input, processed)
	if processed or Library.Unloaded then
		return
	end
	if input.KeyCode ~= Library.MenuKeybind then
		return
	end

	Library:ToggleOpen()
end)

function Library:SetMenuKeybind(key)
	if typeof(key) == "EnumItem" then
		Library.MenuKeybind = key
	end
	return Library
end

--// Settings //////////////////////////////////////////////////////////////////

function Library:SaveSettings()
	if not Compat.HasFilesystem then
		return false
	end

	--[[
		The whole settings table goes to disk. It only ever holds plain values,
		so a copy encodes as is, and every new setting is persisted without
		having to be listed here as well.
	]]
	local data = table.clone(Library.Settings)
	data.WindowBinds = table.clone(Library.Settings.WindowBinds)

	local encoded
	local ok = pcall(function()
		encoded = HttpService:JSONEncode(data)
	end)
	if not ok then
		return false
	end

	FS.EnsureFolder("tallin")
	return FS.WriteFile(Library.SettingsFile, encoded) and true or false
end

function Library:LoadSettings()
	if not FS.IsFile(Library.SettingsFile) then
		return false
	end

	local ok, contents = FS.ReadFile(Library.SettingsFile)
	if not ok or type(contents) ~= "string" then
		return false
	end

	local decoded
	local decodedOk = pcall(function()
		decoded = HttpService:JSONDecode(contents)
	end)
	if not decodedOk or type(decoded) ~= "table" then
		return false
	end

	for key, value in decoded do
		if Library.Settings[key] ~= nil then
			Library.Settings[key] = value
		end
	end

	-- Reapply the ones that own live state.
	if type(Library.Settings.MenuKeybind) == "string" then
		local key = Enum.KeyCode[Library.Settings.MenuKeybind]
		if key then
			Library.MenuKeybind = key
		end
	end
	Library:SetNotificationCorner(Library.Settings.NotificationCorner)
	Library:SetAccentAnimation(
		Library.Settings.AccentAnimation,
		Library.Settings.AccentAnimationSpeed
	)
	if Library.SetTaskbarMode then
		Library:SetTaskbarMode(Library.Settings.TaskbarMode)
	end
	if Library.SetTaskbarVisible then
		Library:SetTaskbarVisible(Library.Settings.ShowTaskbar ~= false)
	end
	if Library.Settings.ShowWindows == false then
		Library:SetWindowsVisible(false)
	end
	if Library.Settings.Font and Library.Settings.Font ~= "Tahoma 8px" then
		pcall(function()
			Library:SetFontByName(Library.Settings.Font)
		end)
	else
		-- Still apply any manual tuning saved for the design font.
		pcall(function()
			Library:ApplyFontMetrics(Library.CurrentFontEntry)
		end)
	end

	return true
end

--// Accent animation //////////////////////////////////////////////////////////

--[[
	Drives Accent over time. The animated colour is written through
	RefreshTheme, so every accent painter follows along, while the colour the
	user actually chose is kept in AnimationBase and restored when the animation
	stops. That base is also what gets saved, so a theme file never captures a
	frame of the animation.

	The loop runs at 20Hz rather than per frame: a repaint touches every painter,
	and this is fast enough to look smooth without doing that 60 times a second.
]]
Library.AnimationBase = false
Library.AnimationThread = false

function Library:SetAccentAnimation(mode, speed)
	mode = tostring(mode or "Off")
	if not table.find(ACCENT_ANIMATIONS, mode) then
		mode = "Off"
	end

	if speed ~= nil then
		Library.Settings.AccentAnimationSpeed = math.max(0.05, tonumber(speed) or 1)
	end

	local previous = Library.Settings.AccentAnimation
	Library.Settings.AccentAnimation = mode

	if mode == "Off" then
		if previous ~= "Off" and typeof(Library.AnimationBase) == "Color3" then
			Library:RefreshTheme("Accent", Library.AnimationBase)
		end
		Library.AnimationBase = false
		return Library
	end

	if typeof(Library.AnimationBase) ~= "Color3" then
		Library.AnimationBase = Themes.Current.Accent
	end

	-- One loop serves every mode, so switching modes never stacks threads.
	if Library.AnimationThread then
		return Library
	end

	--[[
		Driven per frame rather than on a timer, and it writes the colour
		directly before repainting just the accent dependent properties. Going
		through RefreshTheme here would run the whole theme-change path sixty
		times a second, which is what made the colour crawl and stutter.
	]]
	Library.AnimationThread = Library:Connect(RunService.RenderStepped, function()
		if Library.Unloaded or Library.Settings.AccentAnimation == "Off" then
			return
		end

		local speedFactor = Library.Settings.AccentAnimationSpeed or 1
		local clock = os.clock() * speedFactor
		local base = typeof(Library.AnimationBase) == "Color3" and Library.AnimationBase
			or Themes.Default.Accent
		local hue, saturation, value = base:ToHSV()
		local color

		local current = Library.Settings.AccentAnimation
		if current == "Rainbow" then
			-- Pastel sweep, keeping the tone of the design's own accent.
			color = Color3.fromHSV((clock * 0.12) % 1, 0.28, 0.95)
		elseif current == "Fade" then
			local alpha = (math.sin(clock * 2) + 1) / 2
			color = Color3.fromHSV(hue, saturation, Utils.Lerp(0.35, value, alpha))
		elseif current == "Breathe" then
			local alpha = (math.sin(clock * 1.2) + 1) / 2
			color = Color3.fromHSV(
				(hue + Utils.Lerp(-0.06, 0.06, alpha)) % 1,
				Utils.Lerp(saturation * 0.5, saturation, alpha),
				value
			)
		end

		if not color then
			return
		end

		Themes.Current.Accent = color
		if not Themes.Pinned.AccentToggleShade then
			Themes.Current.AccentToggleShade = Utils.Multiply(color, 0.571)
		end
		Library:RepaintKeys({ "Accent", "AccentToggleShade" })
	end)

	return Library
end

--// Theme window //////////////////////////////////////////////////////////////

--[[
	One row per theme key, each with a swatch that opens a picker. Editing a
	swatch calls RefreshTheme, so the whole UI retints live.
]]
function Library:ThemeWindow(options)
	options = options or {}

	if Library.ThemeWindowRef then
		return Library.ThemeWindowRef
	end

	--[[
		Same footprint as the design, but split across tabs: the palette alone
		is far longer than the twelve rows the mockup showed, and binds,
		notification behaviour and the accent animation all belong here too.
	]]
	--[[
		Given room to breathe: the palette alone runs to about thirty keys, so it
		is split across both columns, and the rest of the settings get their own
		tabs. The window is resizable like any other, and the columns re-split on
		whole pixels as it grows.
	]]
	local window = Library:Window({
		Name = Field(options, "Name", "Theme"),
		-- Six tabs and a scrolling palette want the room.
		Size = Field(options, "Size", Vector2.new(520, 430)),
		Position = Field(options, "Position", nil),
		Visible = Field(options, "Visible", false),
		MinSize = Vector2.new(380, 280),
	})

	--[[
		No animation tab: colour animations belong to the picker that owns the
		colour. Animating the accent means setting an animation on the Accent
		picker in the Colors tab.
	]]
	local colours = window:Tab({ Name = "Colors" })
	local themes = window:Tab({ Name = "Themes" })
	local interface = window:Tab({ Name = "UI" })
	local binds = window:Tab({ Name = "Binds" })
	local notifs = window:Tab({ Name = "Notifs" })

	--// Colours: every key the library paints with, not just the design's list.
	local keys = Library:GetThemeKeys()
	local half = math.ceil(#keys / 2)

	local paletteLeft = colours:Section({ Name = "Palette", Side = "Left" })
	local paletteRight = colours:Section({ Name = "More", Side = "Right" })

	for index, key in keys do
		local target = index <= half and paletteLeft or paletteRight
		local picker = target:Colorpicker({
			Name = key,
			Color = Themes.Current[key],
			Callback = function(color)
				-- Editing the accent by hand takes over from the animation.
				if key == "Accent" and Library.Settings.AccentAnimation ~= "Off" then
					Library.AnimationBase = color
				end
				Library:RefreshTheme(key, color)
				Library:SaveTheme()
			end,
		})
		picker.ThemeKey = key
	end

	--// Themes: the design default, the built-in palettes, then anything saved.
	local themeList = themes:Section({ Name = "Themes", Side = "Left" })
	local themeTools = themes:Section({ Name = "Options", Side = "Right" })
	local selectedTheme = "DEFAULT"

	local themeName = themeList:Textbox({
		Placeholder = "theme name",
		ClearOnFocus = false,
	})

	--[[
		Scrollable: there are eighteen themes before anyone saves one of their own,
		and a fixed frame with clipping simply hid the rest.
	]]
	local themeRows = New("ScrollingFrame", {
		Name = "ThemeRows",
		Active = true,
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		ClipsDescendants = true,
		Size = UDim2.new(1, 0, 0, 200),
		CanvasSize = UDim2.new(),
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
		ScrollBarThickness = 2,
		ScrollBarImageTransparency = 0.25,
		ScrollingDirection = Enum.ScrollingDirection.Y,
		Parent = themeList.Content,
		LayoutOrder = 5,
	}, {
		New("UIListLayout", {
			FillDirection = Enum.FillDirection.Vertical,
			SortOrder = Enum.SortOrder.LayoutOrder,
			Padding = UDim.new(0, 0),
		}),
	})
	Library:Bind(themeRows, "ScrollBarImageColor3", "Accent")

	function Library:RefreshThemeList()
		if not themeRows.Parent then
			return
		end

		for _, child in themeRows:GetChildren() do
			if child:IsA("TextButton") then
				child:Destroy()
			end
		end

		for index, name in Library:GetThemes() do
			local button = New("TextButton", {
				Name = name,
				AutoButtonColor = false,
				BackgroundColor3 = Themes.Current.Accent,
				BackgroundTransparency = 1,
				BorderSizePixel = 0,
				LayoutOrder = index,
				Size = UDim2.new(1, 0, 0, Metrics.RowHeight),
				Position = UDim2.fromOffset(0, Metrics.TextInkOffset or 0),
				Text = name,
				TextSize = Metrics.TextBase,
				TextXAlignment = Enum.TextXAlignment.Center,
				TextYAlignment = Enum.TextYAlignment.Center,
				Parent = themeRows,
			})
			ApplyFont(button)
			Utils.Outline(button)

			-- Same one-of-many treatment as the config list.
			Library:Paint(button, "BackgroundColor3", function()
				return Themes.Current.Accent
			end)
			button.BackgroundTransparency = 1
			if name == selectedTheme then
				Library:Tween(button, { BackgroundTransparency = 0.9 }, 0.1, "Quad")
			end
			Library:Paint(button, "TextColor3", function()
				if name == selectedTheme then
					return Themes.Current.TextColor
				end
				return Themes.Current.InactiveButtonText
			end)

			Library:Connect(button.MouseButton1Click, function()
				selectedTheme = name
				if name ~= "DEFAULT" then
					themeName:Set(name, true)
				end
				Library:LoadNamedTheme(name)
			end)
		end
	end

	themeList:Buttons({
		{
			Name = "Save",
			Callback = function()
				local name = themeName:Get()
				if name == "" then
					Library:Notify("enter a theme name")
					return
				end
				if Library:SaveNamedTheme(name) then
					selectedTheme = name
					Library:RefreshThemeList()
				end
			end,
		},
		{
			Name = "Delete",
			Callback = function()
				local name = themeName:Get()
				if name == "" then
					name = selectedTheme
				end
				if Library:DeleteTheme(name) then
					selectedTheme = "DEFAULT"
					Library:RefreshThemeList()
				end
			end,
		},
	})

	--// Options for how a theme is applied.
	themeTools:Toggle({
		Name = "Accent only",
		Default = Library.Settings.ThemeAccentOnly,
		Callback = function(state)
			Library.Settings.ThemeAccentOnly = state
			Library:SaveSettings()
		end,
	})

	themeTools:Button({
		Name = "Random accent",
		Callback = function()
			Library:RefreshTheme("Accent", Color3.fromHSV(math.random(), 0.35, 0.95))
			Library:SaveTheme()
		end,
	})

	themeTools:Button({
		Name = "Invert text",
		Callback = function()
			-- Handy on the lighter palettes.
			local text = Themes.Current.TextColor
			Library:RefreshTheme("TextColor", Color3.new(1 - text.R, 1 - text.G, 1 - text.B))
			Library:SaveTheme()
		end,
	})

	--[[
		Clipboard exchange. The theme travels as the same JSON that gets written to
		disk, so anything copied out of here can be pasted straight into a file.
	]]
	themeTools:Buttons({
		{
			Name = "Copy",
			Callback = function()
				local clipboard = Compat.setclipboard
				if not clipboard then
					Library:Notify("executor has no clipboard access")
					return
				end

				local ok, encoded = pcall(function()
					return HttpService:JSONEncode(Library:SerializeTheme())
				end)
				if ok then
					pcall(clipboard, encoded)
					Library:Notify("theme copied")
				end
			end,
		},
		{
			Name = "Paste",
			Callback = function()
				local read = Compat.getclipboard
				if not read then
					Library:Notify("executor cannot read the clipboard")
					return
				end

				local okRead, text = pcall(read)
				if not okRead or type(text) ~= "string" then
					return
				end

				local okDecode, decoded = pcall(function()
					return HttpService:JSONDecode(text)
				end)
				if not okDecode or type(decoded) ~= "table" then
					Library:Notify("clipboard is not a theme")
					return
				end

				for key, raw in decoded do
					local color = Deserialize(raw)
					if typeof(color) == "Color3" then
						Library:RefreshTheme(key, color)
					end
				end
				Library:Notify("theme pasted")
			end,
		},
	})

	--// Interface: transitions and the shape of the taskbar.
	local uiSection = interface:Section({ Name = "Transitions", Side = "Left" })

	uiSection:Dropdown({
		Name = "Menu transition",
		Options = MENU_TRANSITIONS,
		Default = Library.Settings.MenuTransition,
		Callback = function(mode)
			Library.Settings.MenuTransition = mode
			Library:SaveSettings()
		end,
	})

	uiSection:Slider({
		Name = "Duration",
		Min = 0,
		Max = 1,
		Interval = 0.02,
		Suffix = "s",
		Default = Library.Settings.TweenDuration,
		Callback = function(value)
			Library.Settings.TweenDuration = value
			Library:SaveSettings()
		end,
	})

	uiSection:Dropdown({
		Name = "Easing",
		Options = TWEEN_STYLES,
		Default = Library.Settings.TweenStyle,
		Callback = function(style)
			Library.Settings.TweenStyle = style
			Library:SaveSettings()
		end,
	})

	--// Lua editor behaviour. Its colours are in the palette with the rest.
	local luaSection = interface:Section({ Name = "Lua editor", Side = "Left" })

	local function luaSetting(key, value)
		Library.Settings[key] = value
		Library:SaveSettings()
		if Library.LuaWindowRef and Library.LuaWindowRef.ApplySettings then
			Library.LuaWindowRef.ApplySettings()
		end
	end

	luaSection:Toggle({
		Name = "Auto scroll to caret",
		Default = Library.Settings.LuaAutoScroll,
		Callback = function(state)
			luaSetting("LuaAutoScroll", state)
		end,
	})

	luaSection:Toggle({
		Name = "Line numbers",
		Default = Library.Settings.LuaLineNumbers,
		Callback = function(state)
			luaSetting("LuaLineNumbers", state)
		end,
	})

	luaSection:Toggle({
		Name = "Highlight current line",
		Default = Library.Settings.LuaHighlightLine,
		Callback = function(state)
			luaSetting("LuaHighlightLine", state)
		end,
	})

	luaSection:Toggle({
		Name = "Blinking caret",
		Default = Library.Settings.LuaCaretBlink,
		Callback = function(state)
			luaSetting("LuaCaretBlink", state)
		end,
	})

	luaSection:Toggle({
		Name = "Auto indent",
		Default = Library.Settings.LuaAutoIndent,
		Callback = function(state)
			luaSetting("LuaAutoIndent", state)
		end,
	})

	luaSection:Dropdown({
		Name = "Font size",
		Options = { "11", "12", "14" },
		Default = tostring(Library.Settings.LuaFontSize),
		Callback = function(value)
			luaSetting("LuaFontSize", tonumber(value) or 11)
		end,
	})

	luaSection:Dropdown({
		Name = "Indent size",
		Options = { "2", "4", "8" },
		Default = tostring(Library.Settings.LuaIndentSize),
		Callback = function(value)
			luaSetting("LuaIndentSize", tonumber(value) or 4)
		end,
	})

	--// Font.
	local fontSection = interface:Section({ Name = "Font", Side = "Right" })

	fontSection:Dropdown({
		Name = "UI font",
		Options = Library:GetFontNames(),
		Default = Library.Settings.Font,
		MaxVisible = 8,
		Callback = function(name)
			if Library:SetFontByName(name) then
				Library:SaveSettings()
			end
		end,
	})

	--[[
		Live tuning. Every font in the list ships with values that suit it, and
		these three override them: text size, how much headroom each row gets, and
		the vertical nudge for centred text. Each one has an "auto" position that
		hands control back to the font.
	]]
	local function retune()
		Library:ApplyFontMetrics()
		Library:SaveSettings()
	end

	fontSection:Slider({
		Name = "Text size",
		Min = 0,
		Max = 20,
		Interval = 1,
		Default = Library.Settings.FontSizeOverride,
		MinText = "auto",
		Callback = function(value)
			Library.Settings.FontSizeOverride = value
			retune()
		end,
	})

	fontSection:Slider({
		Name = "Row headroom",
		Min = -1,
		Max = 8,
		Interval = 1,
		Default = Library.Settings.FontRowOverride,
		MinText = "auto",
		Callback = function(value)
			Library.Settings.FontRowOverride = value
			retune()
		end,
	})

	fontSection:Slider({
		Name = "Ink offset",
		Min = -5,
		Max = 1,
		Interval = 1,
		Default = Library.Settings.FontInkOverride,
		MaxText = "auto",
		Callback = function(value)
			Library.Settings.FontInkOverride = value
			retune()
		end,
	})

	fontSection:Button({
		Name = "Reset to font defaults",
		Callback = function()
			Library.Settings.FontSizeOverride = 0
			Library.Settings.FontRowOverride = -1
			Library.Settings.FontInkOverride = 1
			retune()
			Library:Notify("font tuning reset")
		end,
	})

	--// Buttons.
	local buttonSection = interface:Section({ Name = "Buttons", Side = "Right" })

	buttonSection:Dropdown({
		Name = "Light up on",
		Options = BUTTON_HIGHLIGHTS,
		Default = Library.Settings.ButtonHighlight,
		Callback = function(mode)
			Library.Settings.ButtonHighlight = mode
			Library:SaveSettings()
		end,
	})

	buttonSection:Slider({
		Name = "Button tween",
		Min = 0,
		Max = 0.6,
		Interval = 0.02,
		Suffix = "s",
		Default = Library.Settings.ButtonTweenDuration,
		Callback = function(value)
			Library.Settings.ButtonTweenDuration = value
			Library:SaveSettings()
		end,
	})

	--// Colour picker swatches.
	local swatchSection = interface:Section({ Name = "Swatches", Side = "Right" })

	swatchSection:Toggle({
		Name = "Gradient swatches",
		Default = Library.Settings.PickerGradient,
		Callback = function(state)
			Library.Settings.PickerGradient = state
			Library:RefreshSwatchGradients()
			Library:SaveSettings()
		end,
	})

	swatchSection:Slider({
		Name = "Gradient depth",
		Min = 0.1,
		Max = 1,
		Interval = 0.05,
		Default = Library.Settings.PickerGradientShade,
		Callback = function(value)
			Library.Settings.PickerGradientShade = value
			Library:RefreshSwatchGradients()
			Library:SaveSettings()
		end,
	})

	local dockSection = interface:Section({ Name = "Dock", Side = "Right" })

	dockSection:Dropdown({
		Name = "Taskbar",
		Options = TASKBAR_MODES,
		Default = Library.Settings.TaskbarMode,
		Callback = function(mode)
			Library:SetTaskbarMode(mode)
			Library:SaveSettings()
		end,
	})

	dockSection:Label({ Name = "Compact can be dragged" })

	-- Two switches, one per half of the menu.
	Library.DockToggleRef = dockSection:Toggle({
		Name = "Show dock",
		Default = Library.Settings.ShowTaskbar,
		Callback = function(state)
			Library:SetTaskbarVisible(state)
			Library:SaveSettings()
		end,
	})

	Library.WindowsToggleRef = dockSection:Toggle({
		Name = "Show windows",
		Default = Library.Settings.ShowWindows,
		Callback = function(state)
			Library:SetWindowsVisible(state)
			Library:SaveSettings()
		end,
	})

	dockSection:Toggle({
		Name = "Keep watermark open",
		Default = Library.Settings.PersistWatermark,
		Callback = function(state)
			Library.Settings.PersistWatermark = state
			Library:SaveSettings()

			-- Move the overlays between the two layers straight away.
			local target = state and Library.Persistent or Library.Holder
			if Library.WatermarkRef then
				Library.WatermarkRef.Frame.Parent = target
			end
			if Library.PlayerPanelRef then
				Library.PlayerPanelRef.Frame.Parent = target
			end
		end,
	})

	dockSection:Button({
		Name = "Close menu",
		Callback = function()
			Library:SetOpen(false)
		end,
	})

	--// Binds: the menu itself plus one per window that has a taskbar button.
	local menuSection = binds:Section({ Name = "Menu", Side = "Left" })

	local menuBind = menuSection:Keybind({
		Name = "Toggle UI",
		Default = Library.MenuKeybind,
		Mode = "Always",
		Callback = function() end,
	})

	menuBind.OnKeyChanged = function(key)
		if key then
			Library:SetMenuKeybind(key)
			Library.Settings.MenuKeybind = key.Name
			Library:SaveSettings()
		end
	end

	--[[
		Window binds are rebuilt on demand: the theme window is itself one of the
		first windows created, so the rest do not exist yet at this point. Every
		window with a taskbar button calls RefreshBindList as it appears.
	]]
	local windowSection = binds:Section({ Name = "Windows", Side = "Left" })

	function Library:RefreshBindList()
		if not windowSection.Content.Parent then
			return
		end

		for _, child in windowSection.Content:GetChildren() do
			if child:IsA("Frame") then
				child:Destroy()
			end
		end
		table.clear(windowSection.Elements)
		windowSection.NextOrder = 0

		for _, entry in Library.BindableWindows do
			local saved = Library.Settings.WindowBinds[entry.Name]
			local bind = windowSection:Keybind({
				Name = entry.Name,
				Default = saved and Enum.KeyCode[saved] or nil,
				Mode = "Always",
				Callback = function()
					entry.Toggle()
				end,
			})

			bind.OnKeyChanged = function(key)
				Library.Settings.WindowBinds[entry.Name] = key and key.Name or nil
				Library:SaveSettings()
			end
		end
	end

	--// Notifications.
	local notifSection = notifs:Section({ Name = "Notifications", Side = "Left" })

	notifSection:Dropdown({
		Name = "Corner",
		Options = NOTIFICATION_CORNERS,
		Default = Library.Settings.NotificationCorner,
		Callback = function(corner)
			Library:SetNotificationCorner(corner)
			Library:SaveSettings()
		end,
	})

	notifSection:Slider({
		Name = "Smoothness",
		Min = 0,
		Max = 1,
		Interval = 0.02,
		Suffix = "s",
		Default = Library.Settings.NotificationSmoothness,
		Callback = function(value)
			Library.Settings.NotificationSmoothness = value
			Library:SaveSettings()
		end,
	})

	notifSection:Slider({
		Name = "Duration",
		Min = 1,
		Max = 15,
		Interval = 1,
		Suffix = "s",
		Default = Library.Settings.NotificationDuration,
		Callback = function(value)
			Library.Settings.NotificationDuration = value
			Library:SaveSettings()
		end,
	})

	notifSection:Button({
		Name = "Test notification",
		Callback = function()
			Library:Notify("test notification")
		end,
	})

	Library.ThemeWindowRef = window
	Library:RefreshThemeList()

	return window
end

--// Keybind list //////////////////////////////////////////////////////////////

--[[
	The standalone keybind panel: one row per keybind that asked for
	ShowInList, name on the left and key on the right. Rows are rebuilt from
	scratch whenever a bind changes, which keeps the ordering stable.
]]
function Library:KeybindWindow(options)
	options = options or {}

	if Library.KeybindWindowRef then
		return Library.KeybindWindowRef
	end

	--[[
		The keybind list is a heads-up panel, not a window to work in, so it sits
		above the others and is not pulled into the normal focus stack.
	]]
	local window = Library:Window({
		Name = Field(options, "Name", "Keybinds"),
		Size = Vector2.new(190, 120),
		Position = Field(options, "Position", nil),
		Visible = Field(options, "Visible", false),
		TopMost = true,
	})



	local list = New("Frame", {
		Name = "KeybindList",
		BackgroundTransparency = 1,
		Position = UDim2.fromOffset(4, 0),
		Size = UDim2.new(1, -8, 1, 0),
		Parent = window.Content,
	}, {
		New("UIListLayout", {
			FillDirection = Enum.FillDirection.Vertical,
			SortOrder = Enum.SortOrder.LayoutOrder,
			Padding = UDim.new(0, 1),
		}),
	})

	local layout = list:FindFirstChildOfClass("UIListLayout")

	function Library:RefreshKeybindList()
		if not list.Parent then
			return
		end

		for _, child in list:GetChildren() do
			if child:IsA("Frame") then
				child:Destroy()
			end
		end

		local shown = 0
		for index, element in Library.KeybindList do
			if element.Key then
				shown += 1

				local row = New("Frame", {
					Name = element.Name,
					BackgroundTransparency = 1,
					LayoutOrder = index,
					Size = UDim2.new(1, 0, 0, Metrics.RowHeight),
					Parent = list,
				})

				Utils.Text({
					Size = UDim2.new(1, -60, 1, 0),
					TextYAlignment = Enum.TextYAlignment.Center,
					Text = element.Name,
					Parent = row,
				})

				local keyLabel = Utils.Text({
					AnchorPoint = Vector2.new(1, 0),
					Position = UDim2.fromScale(1, 0),
					Size = UDim2.new(0, 60, 1, 0),
					TextXAlignment = Enum.TextXAlignment.Right,
					TextYAlignment = Enum.TextYAlignment.Center,
					-- Full mode word here: the list has room, unlike the field.
					Text = string.format("%s [%s]", Utils.KeyName(element.Key), element.Mode),
					Parent = row,
				})

				-- Lit while the bind is active, matching the field itself.
				Library:Paint(keyLabel, "TextColor3", function()
					return element.Active and Themes.Current.Accent or Themes.Current.TextColor
				end, { "Accent", "TextColor" })
			end
		end

		--[[
			Collapse to the title strip when nothing is bound, but stop doing so
			once the window has been resized by hand: otherwise the list keeps
			forcing its own height back and the window can never be made small
			again.
		]]
		if not window.UserResized then
			window.Frame.Size = UDim2.fromOffset(
				window.Frame.Size.X.Offset,
				Metrics.WindowTitleHeight + 6 + math.max(0, layout.AbsoluteContentSize.Y)
			)
		end
	end

	Library.KeybindWindowRef = window
	Library:RefreshKeybindList()

	return window
end

--// Watermark /////////////////////////////////////////////////////////////////

--[[
	Single line panel. Values are wrapped in accent coloured RichText spans, the
	way the design highlights the date, time, fps and ping.
]]
function Library:Watermark(options)
	options = options or {}

	if Library.WatermarkRef then
		return Library.WatermarkRef
	end

	local viewport = Camera and Camera.ViewportSize or Vector2.new(1920, 1080)

	local frame = New("Frame", {
		Name = "Watermark",
		BackgroundTransparency = 1,
		Position = Field(
			options,
			"Position",
			UDim2.fromOffset(viewport.X - 260, Metrics.TaskbarHeight + 6)
		),
		Size = UDim2.fromOffset(243, 25),
		Visible = Field(options, "Visible", true),
		ZIndex = 3000,
		-- Persistent layer: stays on screen while the menu is closed.
		Parent = Library.Settings.PersistWatermark and Library.Persistent or Library.Holder,
	})

	local _, body = Utils.Panel({
		Size = UDim2.fromScale(1, 1),
		Parent = frame,
	})

	-- Body text size: the title size resamples a bitmap face and frays its outline.
	local label = Utils.Text({
		Position = UDim2.fromOffset(4, 0),
		Size = UDim2.new(1, -8, 1, 0),
		TextXAlignment = Enum.TextXAlignment.Center,
		Parent = body,
	})

	Utils.Drag(Utils.Hitbox(frame, 10), frame)

	-- Hug the text, like the design's tightly fitted watermark.
	Utils.HugWidth(frame, label, 8, 120)

	local watermark: any = {
		Frame = frame,
		Label = label,
		Fields = Field(options, "Fields", nil),
		TaskbarEntry = false,
	}

	-- Wraps a value in an accent span for RichText.
	local function accent(text)
		return string.format(
			'<font color="#%s">%s</font>',
			Utils.ToHex(Themes.Current.Accent),
			tostring(text)
		)
	end

	watermark.Accent = accent

	--[[
		FPS is sampled by its own frame counter rather than by waiting on
		RenderStepped inside the text builder: that builder now runs as a painter,
		and a painter must never yield since it can be called from a frame loop.
	]]
	local frameCount = 0
	local frameClock = os.clock()
	local fpsSample = 0

	Library:Connect(RunService.RenderStepped, function()
		frameCount += 1
		local now = os.clock()
		if now - frameClock >= 0.5 then
			fpsSample = math.floor(frameCount / (now - frameClock) + 0.5)
			frameCount = 0
			frameClock = now
		end
	end)

	local function defaultFields()
		local fps = fpsSample
		local ping = "N/A"

		local okPing, stat = pcall(function()
			return math.floor(Stats.Network.ServerStatsItem["Data Ping"]:GetValue())
		end)
		if okPing then
			ping = stat
		end

		return {
			Library.Name,
			accent(os.date("%d")) .. " " .. accent(os.date("%b"):lower()),
			accent(os.date("%H")) .. ":" .. accent(os.date("%M")),
			accent(fps) .. " Fps",
			accent(ping) .. " Ping",
		}
	end

	--[[
		The text itself is painted.

		Accent colours are baked into RichText spans, so the string has to be
		rebuilt for the colour to change. Registering that rebuild as a painter
		keyed on Accent means it happens on every accent repaint, including each
		frame of a colour animation, instead of only when the one second refresh
		ticks over.
	]]
	local textPainter = Library:Paint(label, "Text", function()
		local parts = watermark.Fields and watermark.Fields(accent) or defaultFields()
		return table.concat(parts, " | ")
	end, { "Accent" })

	function watermark:Refresh()
		textPainter.Apply()
	end

	function watermark:SetVisible(visible)
		frame.Visible = visible and true or false
		if watermark.TaskbarEntry then
			watermark.TaskbarEntry:SetActive(frame.Visible)
		end
		return watermark
	end

	function watermark:Toggle()
		return watermark:SetVisible(not frame.Visible)
	end

	-- The design puts a Watermark button in the taskbar, so it gets one here too.
	if Field(options, "Taskbar", true) then
		watermark.TaskbarEntry = Library:TaskbarButton("Watermark", function()
			watermark:Toggle()
		end, frame.Visible)

		table.insert(Library.BindableWindows, {
			Name = "Watermark",
			Toggle = function()
				watermark:Toggle()
			end,
		})
		Library:RefreshBindList()
	end

	task.spawn(function()
		while not Library.Unloaded and frame.Parent do
			watermark:Refresh()
			task.wait(1)
		end
	end)

	Library.WatermarkRef = watermark
	return watermark
end

--// Player panel //////////////////////////////////////////////////////////////

--[[
	Avatar, a stack of stat lines and a health bar. The stat lines are supplied
	by the caller as { Label = "Rank", Get = function() end } entries, since
	everything past name and id is game specific.
]]
function Library:PlayerPanel(options)
	options = options or {}

	if Library.PlayerPanelRef then
		return Library.PlayerPanelRef
	end

	local viewport = Camera and Camera.ViewportSize or Vector2.new(1920, 1080)

	local frame = New("Frame", {
		Name = "PlayerPanel",
		BackgroundTransparency = 1,
		Position = Field(
			options,
			"Position",
			UDim2.fromOffset(viewport.X - 272, Metrics.TaskbarHeight + 40)
		),
		Size = UDim2.fromOffset(255, 89),
		Visible = Field(options, "Visible", true),
		ZIndex = 3000,
		-- Persistent layer: stays on screen while the menu is closed.
		Parent = Library.Settings.PersistWatermark and Library.Persistent or Library.Holder,
	})

	local _, body = Utils.Panel({
		Size = UDim2.fromScale(1, 1),
		Parent = frame,
	})

	Utils.Drag(Utils.Hitbox(frame, 10), frame)

	-- Avatar: outlined 81x81 frame holding a 77x77 headshot.
	local _, avatarBody = Utils.Panel({
		Position = UDim2.fromOffset(2, 2),
		Size = UDim2.fromOffset(81, 81),
		Parent = body,
	})
	Library:Bind(avatarBody, "BackgroundColor3", "Background")

	local avatar = New("ImageLabel", {
		BackgroundTransparency = 1,
		Position = UDim2.fromOffset(1, 1),
		Size = UDim2.fromOffset(77, 77),
		ScaleType = Enum.ScaleType.Crop,
		Parent = avatarBody,
	})

	task.spawn(function()
		local ok, url = pcall(function()
			return Players:GetUserThumbnailAsync(
				LocalPlayer.UserId,
				Enum.ThumbnailType.HeadShot,
				Enum.ThumbnailSize.Size420x420
			)
		end)
		if ok and url and avatar.Parent then
			avatar.Image = url
		end
	end)

	local info = New("Frame", {
		Name = "Info",
		BackgroundTransparency = 1,
		Position = UDim2.fromOffset(87, 4),
		Size = UDim2.new(1, -91, 0, 60),
		Parent = body,
	}, {
		New("UIListLayout", {
			FillDirection = Enum.FillDirection.Vertical,
			SortOrder = Enum.SortOrder.LayoutOrder,
			Padding = UDim.new(0, 2),
		}),
	})

	local function accent(text)
		return string.format(
			'<font color="#%s">%s</font>',
			Utils.ToHex(Themes.Current.Accent),
			tostring(text)
		)
	end

	-- Name and id come for free; anything else is caller supplied.
	local fields = Field(options, "Fields", nil) or {}
	local lines = {
		{ Label = "Name", Get = function()
			return LocalPlayer.DisplayName
		end },
		{ Label = "Id", Get = function()
			return LocalPlayer.UserId
		end },
	}
	for _, entry in fields do
		table.insert(lines, entry)
	end

	local labels = {}
	for index, entry in lines do
		local label = Utils.Text({
			LayoutOrder = index,
			Size = UDim2.new(1, 0, 0, Metrics.TextSmall),
			TextSize = Metrics.TextSmall,
			ThemeKey = "InactiveButtonText",
			Parent = info,
		})
		labels[index] = label
	end

	Utils.Text({
		Position = UDim2.fromOffset(87, 58),
		Size = UDim2.fromOffset(60, Metrics.TextSmall),
		TextSize = Metrics.TextSmall,
		Text = "Health",
		ThemeKey = "InactiveButtonText",
		Parent = body,
	})

	local _, healthBody = Utils.Panel({
		Position = UDim2.fromOffset(87, 70),
		Size = UDim2.new(1, -91, 0, 13),
		Parent = body,
	})
	Utils.ClearBase(healthBody)

	local healthFill = New("Frame", {
		BackgroundColor3 = Color3.new(1, 1, 1),
		BorderSizePixel = 0,
		Size = UDim2.fromScale(1, 1),
		Parent = healthBody,
	})
	local healthGradient =
		Utils.Gradient(healthFill, Themes.Current.Accent, Themes.Current.AccentToggleShade)
	Library:Bind(healthGradient, "Color", "Accent", function(top)
		return ColorSequence.new(top, Themes.Current.AccentToggleShade)
	end)
	Library:Bind(healthGradient, "Color", "AccentToggleShade", function(bottom)
		return ColorSequence.new(Themes.Current.Accent, bottom)
	end)

	local healthText = Utils.Text({
		Size = UDim2.fromScale(1, 1),
		TextSize = Metrics.TextTiny,
		TextXAlignment = Enum.TextXAlignment.Center,
		Text = "100%",
		ZIndex = 3,
		Parent = healthBody,
	})

	local panel: any = {
		Frame = frame,
		Avatar = avatar,
		Labels = labels,
		HealthFill = healthFill,
		HealthText = healthText,
		TaskbarEntry = false,
	}

	--[[
		Same trick as the watermark: each row's text is a painter keyed on Accent,
		so the accent coloured values follow a colour animation smoothly rather
		than jumping whenever the half second refresh fires.
	]]
	local rowPainters = {}
	for index, entry in lines do
		local label = labels[index]
		if label then
			rowPainters[index] = Library:Paint(label, "Text", function()
				local ok, value = pcall(entry.Get)
				return string.format(
					"%s: %s",
					tostring(entry.Label),
					accent(ok and tostring(value) or "N/A")
				)
			end, { "Accent" })
		end
	end

	local healthPainter = Library:Paint(healthText, "Text", function()
		local character = LocalPlayer.Character
		local humanoid = character and character:FindFirstChildOfClass("Humanoid")
		if humanoid and humanoid.MaxHealth > 0 then
			local alpha = Utils.Clamp(humanoid.Health / humanoid.MaxHealth, 0, 1)
			return string.format("%d%%", math.floor(alpha * 100 + 0.5))
		end
		return "0%"
	end, { "Accent" })

	function panel:Refresh()
		for _, painter in rowPainters do
			painter.Apply()
		end
		healthPainter.Apply()

		local character = LocalPlayer.Character
		local humanoid = character and character:FindFirstChildOfClass("Humanoid")
		if humanoid and humanoid.MaxHealth > 0 then
			local alpha = Utils.Clamp(humanoid.Health / humanoid.MaxHealth, 0, 1)
			healthFill.Size = UDim2.fromScale(alpha, 1)
			healthText.Text = string.format("%d%%", math.floor(alpha * 100 + 0.5))
		else
			healthFill.Size = UDim2.fromScale(0, 1)
			healthText.Text = "0%"
		end
	end

	function panel:SetVisible(visible)
		frame.Visible = visible and true or false
		if panel.TaskbarEntry then
			panel.TaskbarEntry:SetActive(frame.Visible)
		end
		return panel
	end

	function panel:Toggle()
		return panel:SetVisible(not frame.Visible)
	end

	if Field(options, "Taskbar", true) then
		panel.TaskbarEntry = Library:TaskbarButton("Player", function()
			panel:Toggle()
		end, frame.Visible)

		table.insert(Library.BindableWindows, {
			Name = "Player",
			Toggle = function()
				panel:Toggle()
			end,
		})
		Library:RefreshBindList()
	end

	task.spawn(function()
		while not Library.Unloaded and frame.Parent do
			panel:Refresh()
			task.wait(0.5)
		end
	end)

	Library.PlayerPanelRef = panel
	return panel
end

--// Lua editor ////////////////////////////////////////////////////////////////

--[[
	Multi-line editor with a line number gutter and Execute / Clear /
	Save to file along the bottom. Execution goes through the executor's own
	loadstring so syntax errors surface as notifications.
]]
function Library:LuaWindow(options)
	options = options or {}

	if Library.LuaWindowRef then
		return Library.LuaWindowRef
	end

	local window = Library:Window({
		Name = Field(options, "Name", "Lua"),
		Size = Vector2.new(357, 282),
		Position = Field(options, "Position", nil),
		Visible = Field(options, "Visible", false),
	})

	-- Inner panel: header strip, rule, then the editor surface.
	local _, panelBody = Utils.Panel({
		Position = UDim2.fromOffset(5, 0),
		Size = UDim2.new(1, -10, 1, -30),
		Parent = window.Content,
	})

	local header = New("Frame", {
		BackgroundColor3 = Color3.new(1, 1, 1),
		BorderSizePixel = 0,
		Size = UDim2.new(1, 0, 0, Metrics.SectionHeaderHeight),
		Parent = panelBody,
	})
	local headerGradient =
		Utils.Gradient(header, Themes.Current.SectionHeaderTop, Themes.Current.SectionHeaderBottom)
	Library:Bind(headerGradient, "Color", "SectionHeaderTop", function(top)
		return ColorSequence.new(top, Themes.Current.SectionHeaderBottom)
	end)

	Utils.Text({
		Position = UDim2.fromOffset(3, 0),
		Size = UDim2.new(1, -6, 1, 0),
		Text = "Editor",
		ThemeKey = "SectionNameText",
		Parent = header,
	})

	local rule = New("Frame", {
		BorderSizePixel = 0,
		Position = UDim2.fromOffset(0, Metrics.SectionHeaderHeight),
		Size = UDim2.new(1, 0, 0, 1),
		Parent = panelBody,
	})
	Library:Bind(rule, "BackgroundColor3", "Border")

	local editorArea = New("Frame", {
		BackgroundTransparency = 1,
		Position = UDim2.fromOffset(2, Metrics.SectionHeaderHeight + 3),
		Size = UDim2.new(1, -4, 1, -(Metrics.SectionHeaderHeight + 5)),
		Parent = panelBody,
	})

	local _, editorBody = Utils.Panel({
		Size = UDim2.fromScale(1, 1),
		Parent = editorArea,
	})
	Library:Bind(editorBody, "BackgroundColor3", "ToggleInactive")

	--[[
		Clipping is what keeps the editor inside its window. A MultiLine TextBox
		scrolls its own text to follow the caret, and without clipping that
		overflow is drawn straight over the game world.
	]]
	editorBody.ClipsDescendants = true

	-- Static gutter backdrop, always covering the visible height.
	local gutterBack = New("Frame", {
		Name = "GutterBack",
		BorderSizePixel = 0,
		Size = UDim2.new(0, Metrics.GutterWidth, 1, 0),
		ZIndex = 2,
		Parent = editorBody,
	})
	Library:Bind(gutterBack, "BackgroundColor3", "SectionBottom")

	local gutterRule = New("Frame", {
		Name = "GutterRule",
		BorderSizePixel = 0,
		Position = UDim2.fromOffset(Metrics.GutterWidth, 0),
		Size = UDim2.new(0, 1, 1, 0),
		ZIndex = 3,
		Parent = editorBody,
	})
	Library:Bind(gutterRule, "BackgroundColor3", "Border")

	--[[
		Line numbers and source live inside one scrolling canvas, so they cannot
		drift apart. The canvas grows with its contents because both the numbers
		and the TextBox size themselves vertically.
	]]
	local scroll = New("ScrollingFrame", {
		Name = "Scroll",
		Active = false,
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		ClipsDescendants = true,
		Size = UDim2.fromScale(1, 1),
		CanvasSize = UDim2.new(),
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
		ScrollingDirection = Enum.ScrollingDirection.Y,
		ScrollBarThickness = 2,
		ZIndex = 4,
		Parent = editorBody,
	})
	Library:Bind(scroll, "ScrollBarImageColor3", "Border")

	local canvas = New("Frame", {
		Name = "Canvas",
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		Parent = scroll,
	})

	local gutterText = Utils.Text({
		Name = "Numbers",
		Position = UDim2.fromOffset(2, 1),
		Size = UDim2.new(0, Metrics.GutterWidth - 5, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		TextSize = Metrics.TextTiny,
		TextXAlignment = Enum.TextXAlignment.Right,
		TextYAlignment = Enum.TextYAlignment.Top,
		ThemeKey = "InactiveButtonText",
		RichText = false,
		Text = "1",
		Parent = canvas,
	})

	--[[
		Highlight layer beneath a transparent TextBox: the label paints coloured
		source, the TextBox keeps the caret, selection and editing. Identical
		geometry and font on both means the glyphs line up exactly.
	]]
	local highlight = Utils.Text({
		Name = "Highlight",
		Position = UDim2.fromOffset(Metrics.GutterWidth + 3, 1),
		Size = UDim2.new(1, -(Metrics.GutterWidth + 5), 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		TextSize = Metrics.TextTiny,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextYAlignment = Enum.TextYAlignment.Top,
		Text = "",
		Parent = canvas,
	})

	local input = New("TextBox", {
		Name = "Input",
		BackgroundTransparency = 1,
		ClearTextOnFocus = false,
		MultiLine = true,
		Position = UDim2.fromOffset(Metrics.GutterWidth + 3, 1),
		Size = UDim2.new(1, -(Metrics.GutterWidth + 5), 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		Text = tostring(Field(options, "Default", "-- luau")),
		PlaceholderText = "",
		TextSize = Metrics.TextTiny,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextYAlignment = Enum.TextYAlignment.Top,
		TextWrapped = false,
		-- Glyphs come from the highlight layer underneath.
		TextTransparency = 1,
		ZIndex = 2,
		Parent = canvas,
	})
	ApplyFont(input)

	-- Numbering follows the real line count of the source.
	local function refreshGutter()
		local lines = 1
		for _ in tostring(input.Text):gmatch("\n") do
			lines += 1
		end

		local numbers = table.create(lines)
		for index = 1, lines do
			numbers[index] = tostring(index)
		end
		gutterText.Text = table.concat(numbers, "\n")
	end

	--[[
		Text measurement.

		A hidden label with the same face and size is used as a ruler: its text is
		set to a line prefix and TextBounds then gives that prefix's pixel width.
		This is what places the caret and the selection boxes, and it works with
		the bitmap font, which the legacy GetTextSize call does not.
	]]
	local ruler = Utils.Text({
		Name = "Ruler",
		AutomaticSize = Enum.AutomaticSize.XY,
		Size = UDim2.fromOffset(0, 0),
		TextSize = Metrics.TextTiny,
		TextTransparency = 1,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextYAlignment = Enum.TextYAlignment.Top,
		RichText = false,
		Text = "",
		Visible = false,
		Parent = canvas,
	})

	--[[
		Roblox lays out text lines exactly TextSize apart when LineHeight is 1,
		so anything else here makes the caret, the selection boxes and the line
		numbers drift further from the text with every line down the file.
	]]
	local lineHeight = Metrics.TextTiny

	local function measure(text)
		if text == "" then
			return 0
		end
		ruler.Text = text
		return ruler.TextBounds.X
	end

	-- Splits the source into lines and finds the line and column of an offset.
	local function locate(offset)
		local line = 1
		local lineStart = 1
		local index = 1

		while index <= offset do
			if input.Text:sub(index, index) == "\n" then
				line += 1
				lineStart = index + 1
			end
			index += 1
		end

		return line, input.Text:sub(lineStart, offset)
	end

	-- Selection boxes, one per covered line.
	local selectionLayer = New("Frame", {
		Name = "Selection",
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 1),
		ZIndex = 0,
		Parent = canvas,
	})

	local selectionBoxes = {}

	local function clearSelection()
		for _, box in selectionBoxes do
			box.Visible = false
		end
	end

	local function selectionBox(index)
		local box = selectionBoxes[index]
		if not box then
			box = New("Frame", {
				Name = "SelectionBox",
				BackgroundTransparency = 0.72,
				BorderSizePixel = 0,
				Parent = selectionLayer,
			})
			Library:Bind(box, "BackgroundColor3", "Accent")
			selectionBoxes[index] = box
		end
		box.Visible = true
		return box
	end

	--[[
		Caret. A one pixel bar at the cursor, its transparency easing in and out
		so it breathes instead of the hard blink Roblox draws by default.
	]]
	local caret = New("Frame", {
		Name = "Caret",
		BorderSizePixel = 0,
		Size = UDim2.fromOffset(1, lineHeight - 1),
		ZIndex = 6,
		Visible = false,
		Parent = canvas,
	})
	Library:Bind(caret, "BackgroundColor3", "Accent")

	-- Highlight of the line the caret sits on.
	local activeLine = New("Frame", {
		Name = "ActiveLine",
		BackgroundTransparency = 0.94,
		BorderSizePixel = 0,
		Size = UDim2.new(1, 0, 0, lineHeight),
		ZIndex = 0,
		Visible = false,
		Parent = canvas,
	})
	Library:Bind(activeLine, "BackgroundColor3", "Accent")

	-- Line reported by the last failed execution.
	local errorLine = New("Frame", {
		Name = "ErrorLine",
		BackgroundColor3 = Color3.fromRGB(255, 0, 4),
		BackgroundTransparency = 0.85,
		BorderSizePixel = 0,
		Size = UDim2.new(1, 0, 0, lineHeight),
		ZIndex = 0,
		Visible = false,
		Parent = canvas,
	})
	Library:Bind(errorLine, "BackgroundColor3", "TextColorUnsafe")

	local textLeft = Metrics.GutterWidth + 3

	local function refreshCaret()
		local focused = input:IsFocused()
		caret.Visible = focused
		activeLine.Visible = focused and Library.Settings.LuaHighlightLine ~= false

		if not focused then
			clearSelection()
			return
		end

		local highlightLine = Library.Settings.LuaHighlightLine ~= false

		local cursor = input.CursorPosition
		if cursor < 1 then
			caret.Visible = false
			activeLine.Visible = false
			return
		end

		local line, prefix = locate(cursor - 1)
		local x = textLeft + measure(prefix)
		local y = 1 + (line - 1) * lineHeight

		caret.Position = UDim2.fromOffset(math.floor(x), y)
		activeLine.Position = UDim2.fromOffset(0, y)
		activeLine.Visible = highlightLine

		-- Selection: SelectionStart is -1 when nothing is selected.
		local selectionStart = input.SelectionStart
		clearSelection()

		if selectionStart and selectionStart > 0 and selectionStart ~= cursor then
			local from = math.min(selectionStart, cursor)
			local to = math.max(selectionStart, cursor)

			local fromLine, fromPrefix = locate(from - 1)
			local toLine, toPrefix = locate(to - 1)

			if fromLine == toLine then
				local box = selectionBox(1)
				local left = textLeft + measure(fromPrefix)
				box.Position = UDim2.fromOffset(math.floor(left), 1 + (fromLine - 1) * lineHeight)
				box.Size = UDim2.fromOffset(
					math.max(1, math.floor(measure(toPrefix) - measure(fromPrefix))),
					lineHeight
				)
			else
				-- First line from the anchor to its end, whole lines in the
				-- middle, then the last line up to the caret.
				local slot = 0
				local lines = string.split(input.Text, "\n")

				for lineIndex = fromLine, toLine do
					slot += 1
					local box = selectionBox(slot)
					local content = lines[lineIndex] or ""
					local startX = lineIndex == fromLine and measure(fromPrefix) or 0
					local endX = lineIndex == toLine and measure(toPrefix) or measure(content)

					box.Position = UDim2.fromOffset(
						math.floor(textLeft + startX),
						1 + (lineIndex - 1) * lineHeight
					)
					box.Size = UDim2.fromOffset(math.max(1, math.floor(endX - startX)), lineHeight)
				end
			end
		end
	end

	--[[
		Highlighting is debounced. Retokenising on every keystroke stalls on a
		long script, so edits raise a flag and the repaint runs at most every
		50ms. The caret follows the cursor every frame, which is cheap.
	]]
	local dirty = true

	Library:Connect(input:GetPropertyChangedSignal("Text"), function()
		refreshGutter()
		dirty = true
		-- The reported error no longer matches the edited source.
		errorLine.Visible = false
	end)

	--[[
		Settings from the Theme window. Everything here is behaviour rather than
		colour, and is reapplied whenever one of them changes.
	]]
	local function applySettings()
		local settings = Library.Settings

		local size = tonumber(settings.LuaFontSize) or Metrics.TextTiny
		lineHeight = size

		for _, object in { gutterText, highlight, input, ruler } do
			object.TextSize = size
		end

		caret.Size = UDim2.fromOffset(1, size - 1)
		activeLine.Size = UDim2.new(1, 0, 0, size)
		errorLine.Size = UDim2.new(1, 0, 0, size)

		local numbers = settings.LuaLineNumbers ~= false
		gutterText.Visible = numbers
		gutterBack.Visible = numbers
		gutterRule.Visible = numbers

		local left = numbers and (Metrics.GutterWidth + 3) or 3
		textLeft = left
		highlight.Position = UDim2.fromOffset(left, 1)
		highlight.Size = UDim2.new(1, -(left + 2), 0, 0)
		input.Position = UDim2.fromOffset(left, 1)
		input.Size = UDim2.new(1, -(left + 2), 0, 0)

		if settings.LuaHighlightLine == false then
			activeLine.Visible = false
		end
		if settings.LuaCaretBlink == false then
			caret.BackgroundTransparency = 0
		end

		refreshCaret()
	end

	--[[
		Auto scroll keeps the caret in view: the canvas is nudged only when the
		caret has moved outside the visible band, so typing in the middle of a
		file does not yank the view around.
	]]
	local function scrollToCaret()
		if Library.Settings.LuaAutoScroll == false then
			return
		end

		local caretY = caret.Position.Y.Offset
		local viewTop = scroll.CanvasPosition.Y
		local viewHeight = scroll.AbsoluteSize.Y

		if caretY < viewTop then
			scroll.CanvasPosition = Vector2.new(0, math.max(0, caretY - lineHeight))
		elseif caretY + lineHeight > viewTop + viewHeight then
			scroll.CanvasPosition = Vector2.new(0, caretY + lineHeight * 2 - viewHeight)
		end
	end

	Library:Connect(input:GetPropertyChangedSignal("CursorPosition"), function()
		refreshCaret()
		scrollToCaret()
	end)
	Library:Connect(input:GetPropertyChangedSignal("SelectionStart"), refreshCaret)
	Library:Connect(input.Focused, refreshCaret)
	Library:Connect(input.FocusLost, refreshCaret)

	--[[
		Auto indent copies the leading whitespace of the previous line onto a new
		one. Roblox gives no key event for Enter inside a TextBox, so the newline
		is detected from the text change itself.
	]]
	local previousText = input.Text

	Library:Connect(input:GetPropertyChangedSignal("Text"), function()
		local current = input.Text

		if Library.Settings.LuaAutoIndent ~= false and #current == #previousText + 1 then
			local cursor = input.CursorPosition
			if cursor > 1 and current:sub(cursor - 1, cursor - 1) == "\n" then
				-- Indentation of the line the newline came from.
				local head = current:sub(1, cursor - 2)
				local lineStart = (head:find("\n[^\n]*$") or 0) + 1
				local indent = head:sub(lineStart):match("^[ \t]*") or ""

				if indent ~= "" then
					input.Text = current:sub(1, cursor - 1) .. indent .. current:sub(cursor)
					input.CursorPosition = cursor + #indent
				end
			end
		end

		previousText = input.Text
	end)

	task.spawn(function()
		while not Library.Unloaded and input.Parent do
			if dirty then
				dirty = false
				local ok, painted = pcall(Utils.Highlight, input.Text)
				highlight.Text = ok and painted or ""
			end
			task.wait(0.05)
		end
	end)

	-- Smooth caret breathing, tweened rather than toggled.
	task.spawn(function()
		local faded = false
		while not Library.Unloaded and caret.Parent do
			if caret.Visible and Library.Settings.LuaCaretBlink ~= false then
				faded = not faded
				Library:Tween(caret, { BackgroundTransparency = faded and 0.85 or 0 }, 0.45, "Sine")
			end
			task.wait(0.45)
		end
	end)

	applySettings()

	local editor: any = {
		Window = window,
		Input = input,
		-- Called by the Theme window when an editor setting changes.
		ApplySettings = applySettings,
	}

	function editor:Get()
		return input.Text
	end

	function editor:Set(text)
		input.Text = tostring(text)
		return editor
	end

	function editor:Execute()
		local source = input.Text
		if source == "" then
			return false
		end

		local loader = loadstring
		if not loader then
			Library:Notify("executor has no loadstring")
			return false
		end

		--[[
			Both loadstring and runtime errors carry a line number in their
			message. Pulling it out lets the offending line be marked in the
			gutter area instead of only being mentioned in a notification.
		]]
		local function markError(message)
			local line = tonumber(tostring(message):match(":(%d+):"))
			if not line then
				errorLine.Visible = false
				return
			end

			errorLine.Position = UDim2.fromOffset(0, 1 + (line - 1) * lineHeight)
			errorLine.Visible = true
		end

		errorLine.Visible = false

		local chunk, syntaxError = loader(source)
		if not chunk then
			markError(syntaxError)
			Library:Notify(string.format("syntax error: %s", tostring(syntaxError)))
			return false
		end

		local ok, runtimeError = pcall(chunk)
		if not ok then
			markError(runtimeError)
			Library:Notify(string.format("runtime error: %s", tostring(runtimeError)))
			return false
		end

		return true
	end

	-- Bottom button row: three equal buttons, as in the design.
	local buttonRow = New("Frame", {
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(0, 1),
		Position = UDim2.new(0, 5, 1, -4),
		Size = UDim2.new(1, -10, 0, 21),
		Parent = window.Content,
	})

	local buttonSpecs = {
		{ Name = "Execute", Callback = function()
			editor:Execute()
		end },
		{ Name = "Clear", Callback = function()
			input.Text = ""
		end },
		{ Name = "Save to file", Callback = function()
			local name = string.format("tallin/scripts/%s.txt", os.date("%d%m%y_%H%M%S"))
			FS.EnsureFolder("tallin")
			FS.EnsureFolder("tallin/scripts")
			if FS.WriteFile(name, input.Text) then
				Library:Notify(string.format("saved to %s", name))
			else
				Library:Notify("failed to save script")
			end
		end },
	}

	for index, spec in buttonSpecs do
		local element = BuildButton(buttonRow, spec, UDim2.new(1 / 3, -3, 1, 0))
		element.Frame.Position = UDim2.new((index - 1) / 3, ((index - 1) * 4) / 3, 0, 0)
		element.Label.TextSize = Metrics.TextMedium
	end

	refreshGutter()

	Library.LuaWindowRef = editor
	return editor
end

--// Config window /////////////////////////////////////////////////////////////

--[[
	Library:Configs(window)

	Config list with a name field and the Create / Delete, Save / Load, Unload
	rows from the design. Selecting a row highlights it in the accent colour.
]]
function Library:ConfigWindow(options)
	options = options or {}

	if Library.ConfigWindowRef then
		return Library.ConfigWindowRef
	end

	local window = Library:Window({
		Name = Field(options, "Name", "Configuration"),
		Size = Vector2.new(345, 345),
		Position = Field(options, "Position", nil),
		Visible = Field(options, "Visible", false),
	})

	local selected

	-- List panel.
	local _, listBody = Utils.Panel({
		Position = UDim2.fromOffset(6, 0),
		Size = UDim2.new(1, -12, 1, -90),
		Parent = window.Content,
	})

	local listGradient = Utils.Gradient(listBody, Color3.fromRGB(41, 40, 58), Color3.fromRGB(20, 20, 20))
	Utils.ClearBase(listBody)
	Library:Bind(listGradient, "Color", "Accent", function(accentColor)
		-- The design tints the top of the list towards the accent.
		local top = Utils.Multiply(accentColor, 0.24)
		return ColorSequence.new(top, Color3.fromRGB(20, 20, 20))
	end)

	listBody.ClipsDescendants = true

	local list = New("ScrollingFrame", {
		Active = false,
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Size = UDim2.fromScale(1, 1),
		CanvasSize = UDim2.new(),
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
		ScrollBarThickness = 0,
		Parent = listBody,
	}, {
		New("UIListLayout", {
			FillDirection = Enum.FillDirection.Vertical,
			SortOrder = Enum.SortOrder.LayoutOrder,
			Padding = UDim.new(0, 0),
		}),
	})

	-- Name field plus the three button rows.
	local footer = New("Frame", {
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(0, 1),
		Position = UDim2.new(0, 6, 1, -4),
		Size = UDim2.new(1, -12, 0, 84),
		Parent = window.Content,
	}, {
		New("UIListLayout", {
			FillDirection = Enum.FillDirection.Vertical,
			SortOrder = Enum.SortOrder.LayoutOrder,
			Padding = UDim.new(0, 4),
		}),
	})

	local nameRow = New("Frame", {
		BackgroundTransparency = 1,
		LayoutOrder = 1,
		Size = UDim2.new(1, 0, 0, Metrics.TextboxHeight),
		Parent = footer,
	})

	local _, nameBody = Utils.Raised({
		Size = UDim2.fromScale(1, 1),
		Parent = nameRow,
	})

	local nameInput = Utils.Input({
		Position = UDim2.fromOffset(2, 0),
		Size = UDim2.new(1, -4, 1, 0),
		Text = "",
		PlaceholderText = "config name",
		TextXAlignment = Enum.TextXAlignment.Center,
		ThemeKey = "InactiveButtonText",
		Parent = nameBody,
	})
	Library:Bind(nameInput, "PlaceholderColor3", "InactiveButtonText", function(color)
		return Utils.Multiply(color, 0.68)
	end)

	local function chosenName()
		local typed = nameInput.Text:gsub("^%s+", ""):gsub("%s+$", "")
		if typed ~= "" then
			return typed
		end
		return selected
	end

	-- Rebuilds the list and reapplies the highlight.
	function Library:RefreshConfigList()
		if not list.Parent then
			return
		end

		for _, child in list:GetChildren() do
			if child:IsA("TextButton") then
				child:Destroy()
			end
		end

		--[[
			Exactly one row can be current. The selected row carries the tinted
			strip and prints in the text colour, everything else stays dim, so
			which config is being looked at reads at a glance.
		]]
		for index, name in Library:GetConfigs() do
			local button = New("TextButton", {
				Name = name,
				AutoButtonColor = false,
				BackgroundColor3 = Themes.Current.Accent,
				BackgroundTransparency = 1,
				BorderSizePixel = 0,
				LayoutOrder = index,
				Size = UDim2.new(1, 0, 0, Metrics.RowHeight),
				Position = UDim2.fromOffset(0, Metrics.TextInkOffset or 0),
				Text = name,
				TextSize = Metrics.TextBase,
				TextXAlignment = Enum.TextXAlignment.Center,
				TextYAlignment = Enum.TextYAlignment.Center,
				Parent = list,
			})
			ApplyFont(button)
			Utils.Outline(button)

			Library:Paint(button, "BackgroundColor3", function()
				return Themes.Current.Accent
			end)
			--[[
				The selection tint fades in rather than snapping, the same idea as
				the toggle but quicker: rows are rebuilt on every refresh, so the
				fade doubles as the appearance of the newly selected row.
			]]
			button.BackgroundTransparency = 1
			if name == selected then
				Library:Tween(button, { BackgroundTransparency = 0.9 }, 0.1, "Quad")
			end
			Library:Paint(button, "TextColor3", function()
				if name == selected then
					return Themes.Current.TextColor
				end
				return Themes.Current.InactiveButtonText
			end)

			Library:Connect(button.MouseButton1Click, function()
				selected = name
				nameInput.Text = name
				Library:RefreshConfigList()
			end)
		end
	end

	local rows = {
		{
			{ Name = "Create", Callback = function()
				local name = chosenName()
				if not name then
					Library:Notify("enter a config name")
					return
				end
				Library:SaveConfig(name)
				selected = name
				Library:RefreshConfigList()
			end },
			{ Name = "Delete", Callback = function()
				local name = chosenName()
				if not name then
					Library:Notify("select a config first")
					return
				end
				Library:DeleteConfig(name)
				if selected == name then
					selected = nil
					nameInput.Text = ""
				end
				Library:RefreshConfigList()
			end },
		},
		{
			{ Name = "Save", Callback = function()
				local name = chosenName()
				if not name then
					Library:Notify("select a config first")
					return
				end
				Library:SaveConfig(name)
			end },
			{ Name = "Load", Callback = function()
				local name = chosenName()
				if not name then
					Library:Notify("select a config first")
					return
				end
				Library:LoadConfig(name)
			end },
		},
	}

	for rowIndex, pair in rows do
		local row = New("Frame", {
			BackgroundTransparency = 1,
			LayoutOrder = rowIndex + 1,
			Size = UDim2.new(1, 0, 0, Metrics.ButtonHeight),
			Parent = footer,
		})

		for index, spec in pair do
			local element = BuildButton(row, spec, UDim2.new(0.5, -2, 1, 0))
			element.Frame.Position = UDim2.new((index - 1) * 0.5, (index - 1) * 4, 0, 0)
		end
	end

	local unloadRow = New("Frame", {
		BackgroundTransparency = 1,
		LayoutOrder = 10,
		Size = UDim2.new(1, 0, 0, Metrics.ButtonHeight),
		Parent = footer,
	})
	BuildButton(unloadRow, {
		Name = "Unload",
		Callback = function()
			Library:Unload()
		end,
	})

	Library.ConfigWindowRef = window
	Library:RefreshConfigList()

	return window
end

-- Bbot compatible entry point.
function Library:Configs()
	return Library:ConfigWindow()
end

Library.init_config = Library.Configs

--// Startup ///////////////////////////////////////////////////////////////////

--[[
	Convenience entry point that assembles the layout from the design in one
	call: taskbar, main window, and the built-in Theme, Lua, Keybinds, Watermark
	and Configuration windows, each wired to its taskbar button.
]]
function Library:Setup(options)
	options = options or {}

	local window = Library:Window({
		Name = Field(options, "Name", "Home"),
		Size = Field(options, "Size", Vector2.new(516, 610)),
	})

	Library.Name = tostring(Field(options, "Title", Library.Name))

	local built = { Window = window }

	if Field(options, "Theme", true) then
		built.Theme = Library:ThemeWindow()
	end
	if Field(options, "Lua", true) then
		built.Lua = Library:LuaWindow()
	end
	if Field(options, "Keybinds", true) then
		built.Keybinds = Library:KeybindWindow()
	end
	if Field(options, "Configs", true) then
		built.Configs = Library:ConfigWindow()
	end
	if Field(options, "Watermark", true) then
		built.Watermark = Library:Watermark()
	end
	if Field(options, "PlayerPanel", false) then
		built.PlayerPanel = Library:PlayerPanel()
	end

	-- Now that every window exists, the bind list can be filled in.
	Library:RefreshBindList()

	-- Pull the rest of the fonts down in the background.
	pcall(function()
		Library:PreloadFonts()
	end)

	-- Restore the saved palette and settings, if there are any.
	pcall(function()
		Library:LoadTheme()
	end)
	pcall(function()
		Library:LoadSettings()
	end)

	return window, built
end

-- Preset palette, exposed the way the reference libraries do it.
Themes.preset = Themes.Default
Themes.Preset = Themes.Default

-- Guard against the script being executed twice.
do
	local cache = Compat.getgenv()
	if cache.TallinLibrary and cache.TallinLibrary ~= Library then
		pcall(function()
			cache.TallinLibrary:Unload()
		end)
	end
	cache.TallinLibrary = Library
end

return Library, Notifications, Themes
