if reframework:get_game_name() ~= "mhwilds" then
	return
end

local MOD_NAME = "Monster HP Overlay"
local CONFIG_PATH = "monster_hp_overlay.json"

local DEFAULT_CONFIG = {
	enabled = true,
	show_all = false,
	x = 600,
	y = 12,
	font_size = 16,
	bar_width = 320,
	bar_height = 12,
	row_spacing = 12,
}

local config = {}
local monsters = {}
local diagnostics = {
	update_calls = 0,
	boss_candidates = 0,
	last_error = nil,
}
local diagnostic_frame = 0
local quest_target_keys = {}

local quest_util_type = sdk.find_type_definition("app.QuestUtil")
local get_active_quest_target_bosses = quest_util_type and quest_util_type:get_method("getActiveQuestTargetBossList()")
local target_access_key_util_type = sdk.find_type_definition("app.TargetAccessKeyUtil")
local get_enemy_character = target_access_key_util_type
	and target_access_key_util_type:get_method("getEnemyCharacter(app.TARGET_ACCESS_KEY, System.Boolean)")

local function copy_defaults()
	local result = {}
	for key, value in pairs(DEFAULT_CONFIG) do
		result[key] = value
	end
	return result
end

local function load_config()
	config = copy_defaults()
	local raw = fs.read(CONFIG_PATH)
	local loaded = raw ~= "" and json.load_string(raw) or nil

	if type(loaded) == "table" then
		for key, value in pairs(config) do
			if loaded[key] ~= nil and type(loaded[key]) == type(value) then
				config[key] = loaded[key]
			end
		end
	else
		json.dump_file(CONFIG_PATH, config)
	end
end

local function save_config()
	json.dump_file(CONFIG_PATH, config)
end

local function try_call(object, method_name, ...)
	if object == nil then
		return nil
	end

	local ok, result = pcall(function(...)
		return object:call(method_name, ...)
	end, ...)

	if ok then
		return result
	end

	return nil
end

local function read_member(object, name)
	if object == nil then
		return nil
	end

	local ok, value = pcall(function()
		return object:get_field(name)
	end)

	if ok and value ~= nil then
		return value
	end

	return try_call(object, "get_" .. name)
end

local function as_number(value)
	if type(value) == "number" then
		return value
	end

	local ok, number = pcall(tonumber, value)
	if ok then
		return number
	end

	return nil
end

local function get_enemy_key(enemy)
	local ok, address = pcall(function()
		return enemy:get_address()
	end)

	if ok and address ~= nil then
		return tostring(address)
	end

	return tostring(enemy)
end

local function refresh_quest_targets()
	quest_target_keys = {}
	if get_active_quest_target_bosses == nil or get_enemy_character == nil then
		return
	end

	local ok, access_keys = pcall(function()
		return get_active_quest_target_bosses:call(nil)
	end)
	if not ok or access_keys == nil then
		return
	end

	local count_ok, count = pcall(function()
		return access_keys:get_Count()
	end)
	if not count_ok or count == nil then
		return
	end

	for index = 0, count - 1 do
		local item_ok, access_key = pcall(function()
			return access_keys:get_Item(index)
		end)
		if item_ok and access_key ~= nil then
			local enemy_ok, enemy = pcall(function()
				return get_enemy_character:call(nil, access_key, true)
			end)
			if enemy_ok and enemy ~= nil then
				quest_target_keys[get_enemy_key(enemy)] = true
			end
		end
	end
end

local function normalize_enemy_name(name)
	local base_name = name:match("^(.*)（歴戦王）$")
	if base_name ~= nil then
		return "歴戦王" .. base_name
	end

	base_name = name:match("^(.*)%(歴戦王%)$")
	if base_name ~= nil then
		return "歴戦王" .. base_name
	end

	base_name = name:match("^(.*)（歴戦の個体）$")
	if base_name ~= nil then
		return "歴戦" .. base_name
	end

	base_name = name:match("^(.*)%(歴戦の個体%)$")
	if base_name ~= nil then
		return "歴戦" .. base_name
	end

	return name
end

local function get_enemy_name(ids)
	if ids == nil or ids.id == nil then
		return "Large Monster"
	end

	local enemy_def = sdk.find_type_definition("app.EnemyDef")
	local name_method = enemy_def and enemy_def:get_method("NameString")
	if name_method == nil then
		return "Large Monster " .. tostring(ids.id)
	end

	local ok, name = pcall(function()
		return name_method:call(nil, ids.id, ids.role_id or 0, ids.legendary_id or 0)
	end)

	if ok and type(name) == "string" and name ~= "" then
		return normalize_enemy_name(name)
	end

	return "Large Monster " .. tostring(ids.id)
end

local function read_monster(enemy)
	if enemy == nil then
		return nil
	end

	local context = read_member(enemy, "_Context")
	local em = read_member(context, "_Em")
	local basic = read_member(em, "Basic")
	if basic == nil then
		return nil
	end

	local is_boss = read_member(basic, "IsBoss")
	if is_boss ~= true then
		return nil
	end

	local browser = read_member(em, "Browser")
	local is_quest_target = quest_target_keys[get_enemy_key(enemy)] == true
	local is_combat = try_call(browser, "get_IsCombatPl") == true
	if not config.show_all and not is_quest_target and not is_combat then
		return nil
	end

	local health_manager = read_member(enemy, "HealthMgr")

	local health = as_number(read_member(health_manager, "Health"))
	local max_health = as_number(read_member(health_manager, "MaxHealth"))
	if health == nil or max_health == nil or max_health <= 0 then
		return nil
	end

	local ids = {
		id = read_member(basic, "EmID"),
		role_id = read_member(basic, "RoleID"),
		legendary_id = read_member(basic, "LegendaryID"),
	}

	return {
		name = get_enemy_name(ids),
		health = math.max(0, health),
		max_health = max_health,
		ratio = math.max(0, math.min(1, health / max_health)),
	}
end

local function draw_bar(draw_list, x, y, ratio)
	local background_color = 0xAA222222
	local border_color = 0xFF000000
	local threshold_color = 0xFF000000
	local fill_color = 0xFF38B764

	if ratio <= 0.25 then
		fill_color = 0xFF3C55D9
	elseif ratio <= 0.5 then
		fill_color = 0xFF32A8E0
	end

	local right = x + config.bar_width
	local bottom = y + config.bar_height
	draw_list:add_rect_filled({ x, y }, { right, bottom }, background_color, 0, 0)
	draw_list:add_rect_filled({ x, y }, { x + config.bar_width * ratio, bottom }, fill_color, 0, 0)
	for _, threshold in ipairs({ 0.25, 0.5 }) do
		local marker_x = x + config.bar_width * threshold
		draw_list:add_rect_filled({ marker_x, y + 1 }, { marker_x + 1, bottom - 1 }, threshold_color, 0, 0)
	end
	draw_list:add_rect({ x, y }, { right, bottom }, border_color, 0, 0, 1)
end

local function draw_outlined_text(draw_list, x, y, color, text)
	local outline_color = 0xFF000000
	for offset_y = -1, 1 do
		for offset_x = -1, 1 do
			if offset_x ~= 0 or offset_y ~= 0 then
				draw_list:add_text({ x + offset_x, y + offset_y }, outline_color, text)
			end
		end
	end
	draw_list:add_text({ x, y }, color, text)
end

local function get_text_width(text)
	local size = imgui.calc_text_size(text)
	return size and size.x or 0
end

local function get_digit_width()
	local width = 0
	for digit = 0, 9 do
		width = math.max(width, get_text_width(tostring(digit)))
	end
	return width
end

local function get_fixed_percent_width()
	local digit_width = get_digit_width()
	return digit_width * 4 + get_text_width(".") + get_text_width("%")
end

local function draw_fixed_percent(draw_list, x, y, color, ratio)
	local text = string.format("%5.1f", ratio * 100)
	local digit_width = get_digit_width()
	local decimal_width = get_text_width(".")
	local integer_text = text:sub(1, 3)

	for index = 1, 3 do
		local character = integer_text:sub(index, index)
		if character ~= " " then
			draw_outlined_text(draw_list, x + digit_width * (index - 1), y, color, character)
		end
	end

	draw_outlined_text(draw_list, x + digit_width * 3, y, color, ".")
	draw_outlined_text(draw_list, x + digit_width * 3 + decimal_width, y, color, text:sub(5, 5))
	draw_outlined_text(
		draw_list,
		x + digit_width * 3 + decimal_width + digit_width,
		y,
		color,
		"%"
	)
end

local function get_monster_rows()
	local rows = {}
	for _, monster in pairs(monsters) do
		table.insert(rows, monster)
	end

	table.sort(rows, function(left, right)
		return left.name < right.name
	end)

	return rows
end

local function draw_overlay()
	local rows = get_monster_rows()
	if not config.enabled or #rows == 0 then
		return
	end

	local draw_list = imgui.get_background_draw_list()
	if draw_list == nil then
		return
	end

	imgui.push_font_size(config.font_size)

	local y = config.y
	for _, monster in ipairs(rows) do
		local text_x = config.x
		local hp_x = text_x + config.font_size * 9
		local current_text = string.format("%5.0f", monster.health)
		local max_text = string.format("%5.0f", monster.max_health)
		local percent_width = get_fixed_percent_width()
		local percent_right = text_x + config.bar_width
		local percent_x = percent_right - percent_width
		local spacing = get_text_width("  ")
		local max_right = percent_right - percent_width - spacing
		local max_x = max_right - get_text_width(max_text)
		local slash_width = get_text_width("/")
		local slash_x = max_x - spacing - slash_width
		local current_right = slash_x - spacing
		local current_x = current_right - get_text_width(current_text)

		draw_outlined_text(draw_list, text_x, y, 0xFFFFFFFF, monster.name)
		draw_outlined_text(draw_list, hp_x, y, 0xFFE8E8E8, "HP")
		draw_outlined_text(draw_list, current_x, y, 0xFFE8E8E8, current_text)
		draw_outlined_text(draw_list, slash_x, y, 0xFFE8E8E8, "/")
		draw_outlined_text(draw_list, max_x, y, 0xFFE8E8E8, max_text)
		draw_fixed_percent(draw_list, percent_x, y, 0xFFE8E8E8, monster.ratio)
		draw_bar(draw_list, config.x, y + config.font_size + 4, monster.ratio)
		y = y + config.font_size + 4 + config.bar_height + config.row_spacing
	end

	imgui.pop_font_size()
end

re.on_draw_ui(function()
	local changed = false
	local value_changed

	if imgui.tree_node(MOD_NAME) then
		value_changed, config.enabled = imgui.checkbox("Enabled", config.enabled)
		changed = changed or value_changed
		value_changed, config.show_all = imgui.checkbox("Show all large monsters", config.show_all)
		changed = changed or value_changed
		value_changed, config.x = imgui.slider_int("X", config.x, 0, 4000)
		changed = changed or value_changed
		value_changed, config.y = imgui.slider_int("Y", config.y, 0, 4000)
		changed = changed or value_changed
		value_changed, config.font_size = imgui.slider_int("Font size", config.font_size, 16, 64)
		changed = changed or value_changed
		value_changed, config.bar_width = imgui.slider_int("Bar width", config.bar_width, 120, 1000)
		changed = changed or value_changed
		value_changed, config.bar_height = imgui.slider_int("Bar height", config.bar_height, 8, 48)
		changed = changed or value_changed
		value_changed, config.row_spacing = imgui.slider_int("Row spacing", config.row_spacing, 0, 64)
		changed = changed or value_changed
		imgui.separator()
		imgui.text("Update callbacks: " .. tostring(diagnostics.update_calls))
		imgui.text("Large monster candidates: " .. tostring(diagnostics.boss_candidates))
		imgui.text("Tracked monsters: " .. tostring(#get_monster_rows()))
		if diagnostics.last_error ~= nil then
			imgui.text("Last error: " .. diagnostics.last_error)
		end

		if changed then
			config.font_size = math.max(16, config.font_size)
		end

		imgui.tree_pop()
	end
end)

re.on_frame(function()
	refresh_quest_targets()
	diagnostic_frame = diagnostic_frame + 1
	if diagnostic_frame >= 300 then
		diagnostic_frame = 0
		log.info(
			string.format(
				"[%s] update_calls=%d boss_candidates=%d tracked=%d last_error=%s",
				MOD_NAME,
				diagnostics.update_calls,
				diagnostics.boss_candidates,
				#get_monster_rows(),
				diagnostics.last_error or "none"
			)
		)
	end
	draw_overlay()
end)

re.on_config_save(function()
	save_config()
end)

local function update_monster(enemy)
	diagnostics.update_calls = diagnostics.update_calls + 1
	local ok, monster = pcall(read_monster, enemy)
	if not ok then
		diagnostics.last_error = tostring(monster)
		return
	end

	local key = get_enemy_key(enemy)

	if monster == nil then
		monsters[key] = nil
		return
	end

	diagnostics.boss_candidates = diagnostics.boss_candidates + 1
	monsters[key] = monster
end

local function remove_monster(enemy)
	monsters[get_enemy_key(enemy)] = nil
end

local enemy_character_type = sdk.find_type_definition("app.EnemyCharacter")
if enemy_character_type ~= nil then
	local update_method = enemy_character_type:get_method("doUpdateEnd")
	if update_method ~= nil then
		sdk.hook(update_method, function(args)
			local ok, error_message = pcall(function()
				local enemy = sdk.to_managed_object(args[2])
				if enemy ~= nil then
					update_monster(enemy)
				end
			end)
			if not ok then
				diagnostics.last_error = tostring(error_message)
			end
		end)
	end

	local destroy_method = enemy_character_type:get_method("doOnDestroy")
	if destroy_method ~= nil then
		sdk.hook(destroy_method, function(args)
			local ok, error_message = pcall(function()
				local enemy = sdk.to_managed_object(args[2])
				if enemy ~= nil then
					remove_monster(enemy)
				end
			end)
			if not ok then
				diagnostics.last_error = tostring(error_message)
			end
		end)
	end
end

load_config()
log.info(MOD_NAME .. " loaded")
