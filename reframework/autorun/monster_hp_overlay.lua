if reframework:get_game_name() ~= "mhwilds" then
	return
end

local MOD_NAME = "Monster HP Overlay"
local CONFIG_PATH = "monster_hp_overlay.json"

local DEFAULT_CONFIG = {
	enabled = true,
	show_all = true,
	show_ailments = true,
	x = 600,
	y = 12,
	font_size = 20,
	bar_width = 320,
	bar_height = 12,
	row_spacing = 12,
	column_spacing = 12,
}

local config = {}
local monsters = {}
local font_cache = {}
local diagnostics = {
	update_calls = 0,
	boss_candidates = 0,
	ailment_count = 0,
	last_error = nil,
}
local diagnostic_frame = 0
local quest_target_keys = {}

local AILMENT_DEFINITIONS = {
	[3] = { name = "毒", order = 2, color = 0xFFF755A8, background_color = 0xAA54243D },
	[5] = { name = "麻痺", order = 1, color = 0xFF00D9FF, background_color = 0xAA105560 },
	[7] = { name = "睡眠", order = 3, color = 0xFFE1CF56, background_color = 0xAA4D4630 },
	[9] = { name = "爆破", order = 4, color = 0xFF428CFF, background_color = 0xAA1E3754 },
}

local quest_util_type = sdk.find_type_definition("app.QuestUtil")
local get_active_quest_target_bosses = quest_util_type and quest_util_type:get_method("getActiveQuestTargetBossList()")
local target_access_key_util_type = sdk.find_type_definition("app.TargetAccessKeyUtil")
local get_enemy_character = target_access_key_util_type
	and target_access_key_util_type:get_method("getEnemyCharacter(app.TARGET_ACCESS_KEY, System.Boolean)")
local enemy_context_type = sdk.find_type_definition("app.cEnemyContext")
local enemy_context_conditions = enemy_context_type and enemy_context_type:get_field("Conditions")
local enemy_context_dying = enemy_context_type and enemy_context_type:get_field("Dying")
local conditions_module_type = sdk.find_type_definition("app.cEmModuleConditions")
local conditions_module_conditions = conditions_module_type and conditions_module_type:get_field("_Conditions")
local dying_module_type = sdk.find_type_definition("app.cEmModuleDying")
local dying_is_enable_capture = dying_module_type and dying_module_type:get_method("get_IsEnableCapture()")
local dying_get_capture_vital_rate = dying_module_type and dying_module_type:get_method("get_CaptureVitalRate()")
local bad_condition_type = sdk.find_type_definition("app.cEnemyBadCondition")
local bad_condition_condition_type = bad_condition_type and bad_condition_type:get_field("_ConditionType")
local activate_value_type = sdk.find_type_definition("app.cEnemyActivateValueBase")
local activate_value_is_active = activate_value_type and activate_value_type:get_method("get_IsActive()")
local activate_value_get_value = activate_value_type and activate_value_type:get_method("get_Value()")
local activate_value_get_limit = activate_value_type and activate_value_type:get_method("get_LimitValue()")
local activate_value_get_activate_time = activate_value_type and activate_value_type:get_method("get_ActivateTime()")
local activate_value_get_current_timer = activate_value_type and activate_value_type:get_method("get_CurrentTimer()")

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

local function read_ailments(enemy_context)
	if not config.show_ailments then
		return {}
	end

	if
		enemy_context_conditions == nil
		or conditions_module_conditions == nil
		or bad_condition_condition_type == nil
		or activate_value_is_active == nil
		or activate_value_get_value == nil
		or activate_value_get_limit == nil
		or activate_value_get_activate_time == nil
		or activate_value_get_current_timer == nil
	then
		diagnostics.last_error = "Ailment type definitions not found"
		return {}
	end

	local conditions_module = enemy_context_conditions:get_data(enemy_context)
	if conditions_module == nil then
		diagnostics.last_error = "Enemy Conditions module not found"
		return {}
	end

	local conditions = conditions_module_conditions:get_data(conditions_module)
	if conditions == nil then
		diagnostics.last_error = "Enemy Conditions array not found"
		return {}
	end

	local count = conditions:get_Count()
	diagnostics.ailment_count = count or 0

	local ailments = {}
	for index = 0, count - 1 do
		local condition = conditions:get_Item(index)
		if condition ~= nil and condition:get_type_definition():is_a("app.cEnemyBadCondition") then
			local condition_type = bad_condition_condition_type:get_data(condition)
			local definition = AILMENT_DEFINITIONS[condition_type]
			if definition ~= nil then
				local is_active = activate_value_is_active:call(condition) == true
				local buildup = activate_value_get_value:call(condition) or 0
				local max_buildup = activate_value_get_limit:call(condition) or 0
				local active_time = 0
				local remaining = 0
				if is_active then
					active_time = activate_value_get_activate_time:call(condition) or 0
					local current_timer = activate_value_get_current_timer:call(condition) or 0
					remaining = math.max(0, active_time - current_timer)
				end

				table.insert(ailments, {
					name = definition.name,
					order = definition.order,
					color = definition.color,
					buildup = math.max(0, buildup),
					max_buildup = math.max(0, max_buildup),
					is_active = is_active,
					active_time = math.max(0, active_time),
					remaining = remaining,
				})
			end
		end
	end

	table.sort(ailments, function(left, right)
		return left.order < right.order
	end)

	return ailments
end

local function try_read_ailments(enemy_context)
	local ok, ailments = pcall(read_ailments, enemy_context)
	if not ok then
		diagnostics.last_error = "Ailment read failed: " .. tostring(ailments)
		return {}
	end

	return ailments
end

local function read_enemy_dying(enemy_context)
	if enemy_context_dying == nil then
		return false, nil
	end

	local ok, is_weakened, capture_rate = pcall(function()
		local dying = enemy_context_dying:get_data(enemy_context)
		if dying == nil then
			return false, nil
		end

		local weakened = dying_is_enable_capture ~= nil and dying_is_enable_capture:call(dying) == true
		local rate = dying_get_capture_vital_rate ~= nil and as_number(dying_get_capture_vital_rate:call(dying)) or nil
		return weakened, rate
	end)

	if not ok then
		return false, nil
	end

	return is_weakened == true, capture_rate
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
	local is_finished = health <= 0
		or try_call(browser, "get_IsCapture") == true
		or try_call(browser, "get_IsDie") == true

	local ids = {
		id = read_member(basic, "EmID"),
		role_id = read_member(basic, "RoleID"),
		legendary_id = read_member(basic, "LegendaryID"),
	}
	local is_weakened, capture_rate = read_enemy_dying(em)

	return {
		name = get_enemy_name(ids),
		health = math.max(0, health),
		max_health = max_health,
		ratio = math.max(0, math.min(1, health / max_health)),
		is_weakened = is_weakened,
		capture_rate = capture_rate,
		is_finished = is_finished,
		ailments = try_read_ailments(em),
	}
end

local function draw_filled_capsule(draw_list, x, y, width, height, color)
	local radius = height / 2
	local center_y = y + radius
	if width <= height then
		draw_list:add_circle_filled({ x + width / 2, center_y }, width / 2, color, 16)
		return
	end

	draw_list:add_rect_filled({ x + radius, y }, { x + width - radius, y + height }, color, 0, 0)
	draw_list:add_circle_filled({ x + radius, center_y }, radius, color, 16)
	draw_list:add_circle_filled({ x + width - radius, center_y }, radius, color, 16)
end

local function draw_capsule_outline(draw_list, x, y, width, height, color)
	draw_list:add_rect({ x, y }, { x + width, y + height }, color, height / 2, 0, 1)
end

local function draw_capsule_bar(draw_list, x, y, width, height, ratio, background_color, fill_color, show_border)
	local border_color = 0x88000000
	draw_filled_capsule(draw_list, x, y, width, height, background_color)

	local fill_width = width * math.max(0, math.min(1, ratio))
	if fill_width > 0 then
		draw_filled_capsule(draw_list, x, y, fill_width, height, fill_color)
	end

	if show_border ~= false then
		draw_capsule_outline(draw_list, x, y, width, height, border_color)
	end
end

local function draw_bar(draw_list, x, y, ratio, is_weakened, capture_rate)
	local background_color = 0xAA222222
	local green_color = 0xFF38B764
	local yellow_color = 0xFF32A8E0
	local red_color = 0xFF3C55D9
	local fill_color = green_color

	if is_weakened then
		fill_color = red_color
	elseif ratio <= 0.5 then
		fill_color = yellow_color
	end

	draw_capsule_bar(draw_list, x, y, config.bar_width, config.bar_height, ratio, background_color, fill_color)
	local bottom = y + config.bar_height
	local half_marker_x = x + config.bar_width * 0.5
	draw_list:add_rect_filled({ half_marker_x, y + 1 }, { half_marker_x + 1, bottom - 1 }, yellow_color, 0, 0)

	if capture_rate ~= nil and capture_rate >= 0 and capture_rate <= 1 then
		local weakened_marker_x = x + config.bar_width * capture_rate
		draw_list:add_rect_filled({ weakened_marker_x, y + 1 }, { weakened_marker_x + 1, bottom - 1 }, red_color, 0, 0)
	end
end

local function draw_outlined_text(draw_list, x, y, color, text)
	local outline_color = 0x88000000
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
	draw_outlined_text(draw_list, x + digit_width * 3 + decimal_width + digit_width, y, color, "%")
end

local function draw_ailments(draw_list, x, y, ailments)
	if not config.show_ailments then
		return 0
	end

	local ailments_by_order = {}
	for _, ailment in ipairs(ailments or {}) do
		ailments_by_order[ailment.order] = ailment
	end

	local bar_height = math.max(8, math.floor(config.bar_height * 2 / 3))
	local bar_spacing = 3
	local column_width = (config.bar_width - bar_spacing) / 2
	for order, id in ipairs({ 5, 3, 7, 9 }) do
		local definition = AILMENT_DEFINITIONS[id]
		local ailment = ailments_by_order[order]
		local ratio = 0
		if ailment ~= nil and ailment.is_active and ailment.active_time > 0 then
			ratio = math.max(0, math.min(1, ailment.remaining / ailment.active_time))
		elseif ailment ~= nil and ailment.max_buildup > 0 then
			ratio = math.max(0, math.min(1, ailment.buildup / ailment.max_buildup))
		end

		local column = (order - 1) % 2
		local row = math.floor((order - 1) / 2)
		local bar_x = x + column * (column_width + bar_spacing)
		local bar_y = y + row * (bar_height + bar_spacing)
		draw_capsule_bar(
			draw_list,
			bar_x,
			bar_y,
			column_width,
			bar_height,
			ratio,
			definition.background_color,
			definition.color
		)
	end

	return 2 * bar_height + bar_spacing
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

local function get_japanese_font(size)
	if font_cache[size] == nil then
		local ok, font = pcall(imgui.load_font, "NotoSansJP-Medium.otf", size)
		font_cache[size] = ok and font or false
		if not ok then
			diagnostics.last_error = "Japanese font load failed: " .. tostring(font)
		end
	end

	return font_cache[size] or nil
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

	local font = get_japanese_font(config.font_size)
	if font ~= nil then
		imgui.push_font(font)
	else
		imgui.push_font_size(config.font_size)
	end

	local row_y = config.y
	local row_height = 0
	for index, monster in ipairs(rows) do
		local column = (index - 1) % 2
		local x = config.x + column * (config.bar_width + config.column_spacing)
		local y = row_y
		local text_x = x
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
		local hp_x = current_x - spacing - get_text_width("HP")
		local name_color = monster.is_finished and 0x88999999 or 0xFFFFFFFF
		local value_color = monster.is_finished and 0x88999999 or 0xFFE8E8E8

		draw_outlined_text(draw_list, text_x, y, name_color, monster.name)
		draw_outlined_text(draw_list, hp_x, y, value_color, "HP")
		draw_outlined_text(draw_list, current_x, y, value_color, current_text)
		draw_outlined_text(draw_list, slash_x, y, value_color, "/")
		draw_outlined_text(draw_list, max_x, y, value_color, max_text)
		draw_fixed_percent(draw_list, percent_x, y, value_color, monster.ratio)
		draw_bar(draw_list, x, y + config.font_size + 4, monster.ratio, monster.is_weakened, monster.capture_rate)
		local ailment_height =
			draw_ailments(draw_list, x, y + config.font_size + 4 + config.bar_height + 4, monster.ailments)
		local monster_height = config.font_size + 4 + config.bar_height + 4 + ailment_height
		row_height = math.max(row_height, monster_height)

		if column == 1 or index == #rows then
			row_y = row_y + row_height + config.row_spacing
			row_height = 0
		end
	end

	if font ~= nil then
		imgui.pop_font()
	else
		imgui.pop_font_size()
	end
end

re.on_draw_ui(function()
	local changed = false
	local value_changed

	if imgui.tree_node(MOD_NAME) then
		value_changed, config.enabled = imgui.checkbox("Enabled", config.enabled)
		changed = changed or value_changed
		value_changed, config.show_all = imgui.checkbox("Show all large monsters", config.show_all)
		changed = changed or value_changed
		value_changed, config.show_ailments = imgui.checkbox("Show ailments", config.show_ailments)
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
		value_changed, config.column_spacing = imgui.slider_int("Column spacing", config.column_spacing, 0, 128)
		changed = changed or value_changed
		imgui.separator()
		imgui.text("Update callbacks: " .. tostring(diagnostics.update_calls))
		imgui.text("Large monster candidates: " .. tostring(diagnostics.boss_candidates))
		imgui.text("Tracked monsters: " .. tostring(#get_monster_rows()))
		imgui.text("Ailment entries: " .. tostring(diagnostics.ailment_count))
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
