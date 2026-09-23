if reframework:get_game_name() ~= "mhwilds" then
	return
end

local MOD_NAME = "Monster HP Overlay"
local CONFIG_PATH = "monster_hp_overlay.json"
local ENEMY_ICON_PATH = "monster_hp_overlay/enemy"
local ELEMENT_ICON_PATH = "monster_hp_overlay/icons"
local ENEMY_ICON_PADDING = 5
local ENEMY_ICON_BAR_SPACING = 8
local ENEMY_ICON_BORDER_WIDTH = 2
local ELEMENT_WEAKNESS_THRESHOLD = 20
local ENEMY_ICON_BACKGROUND_COLOR = 0xFF2D2819
local ENEMY_ICON_BORDER_COLOR = 0xFFB8B8A8
local ENEMY_ICON_CORNER_RADIUS = 4

local DEFAULT_CONFIG = {
	enabled = true,
	show_all = false,
	show_severable_parts = true,
	x = 600,
	y = 12,
	font_size = 18,
	bar_width = 280,
	bar_height = 8,
	status_bar_height = 6,
	row_spacing = 12,
	column_spacing = 12,
	weakness_icon_size = 24,
	weakness_icon_spacing = 10,
	weakness_icon_offset_x = -1,
	weakness_icon_offset_y = -1,
}

local config = {}
local monsters = {}
local font_cache = {}
local enemy_icon_cache = {}
local enemy_icon_unknown = nil
local element_icons = {}
local elemental_weakness_cache = {}
local diagnostics = {
	update_calls = 0,
	boss_candidates = 0,
	ailment_count = 0,
	last_error = nil,
}
local diagnostic_frame = 0
local quest_target_keys = {}

local function get_enum_map(type_name)
	local result = {}
	local type_definition = sdk.find_type_definition(type_name)
	if type_definition == nil then
		return result
	end

	for _, field in ipairs(type_definition:get_fields()) do
		if field:is_static() then
			result[field:get_data(nil)] = field:get_name()
		end
	end

	return result
end

local enemy_id_names = get_enum_map("app.EnemyDef.ID")
local part_type_fixed_names = get_enum_map("app.EnemyDef.PARTS_TYPE_Fixed")

local PART_TYPE_LABELS = {
	FULL_BODY = "全身",
	HEAD = "頭",
	UPPER_BODY = "上半身",
	BODY = "胴",
	TAIL = "尻尾",
	TAIL_TIP = "尻尾先端",
	NECK = "首",
	TORSO = "胴体",
	STOMACH = "腹",
	BACK = "背中",
	FRONT_LEGS = "前脚",
	LEFT_FRONT_LEG = "左前脚",
	RIGHT_FRONT_LEG = "右前脚",
	HIND_LEGS = "後脚",
	LEFT_HIND_LEG = "左後脚",
	RIGHT_HIND_LEG = "右後脚",
	LEFT_WING = "左翼",
	RIGHT_WING = "右翼",
	TONGUE = "舌",
	TENTACLE = "触手",
}

local AILMENT_DEFINITIONS = {
	[3] = { name = "毒", order = 2, color = 0xFFF755A8, background_color = 0xAA54243D },
	[5] = { name = "麻痺", order = 1, color = 0xFF00D9FF, background_color = 0xAA105560 },
	[7] = { name = "睡眠", order = 3, color = 0xFFE1CF56, background_color = 0xAA4D4630 },
	[9] = { name = "爆破", order = 4, color = 0xFF428CFF, background_color = 0xAA1E3754 },
}

local ELEMENT_DEFINITIONS = {
	{ type = "Fire", field = "_Fire", icon = "fire.png" },
	{ type = "Water", field = "_Water", icon = "water.png" },
	{ type = "Thunder", field = "_Thunder", icon = "thunder.png" },
	{ type = "Ice", field = "_Ice", icon = "ice.png" },
	{ type = "Dragon", field = "_Dragon", icon = "dragon.png" },
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

local function is_severable_part_value_available()
	local network_manager = sdk.get_managed_singleton("app.NetworkManager")
	if network_manager == nil then
		return true
	end

	local user_info_manager = read_member(network_manager, "UserInfoManager")
	local host_user_info = try_call(user_info_manager, "getHostUserInfo(app.net_session_manager.SESSION_TYPE)", 2)
	if host_user_info == nil then
		return true
	end

	local is_self = read_member(host_user_info, "IsSelf")
	return is_self ~= false
end

local function read_ailments(enemy_context)
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

local function read_elemental_weaknesses(enemy_context, em_id)
	if elemental_weakness_cache[em_id] ~= nil then
		return elemental_weakness_cache[em_id]
	end

	local parts_module = read_member(enemy_context, "Parts")
	local parameters = read_member(parts_module, "_ParamParts")
	local parts_array = read_member(read_member(parameters, "_PartsArray"), "_DataArray")
	local meat_array = read_member(read_member(parameters, "_MeatArray"), "_DataArray")
	if parameters == nil or parts_array == nil or meat_array == nil then
		return {}
	end

	local part_count = try_call(parts_array, "get_Count") or 0
	local meat_count = try_call(meat_array, "get_Count") or 0
	local maximums = {}
	for _, definition in ipairs(ELEMENT_DEFINITIONS) do
		maximums[definition.type] = 0
	end

	for index = 0, part_count - 1 do
		local part = try_call(parts_array, "get_Item", index)
		local meat = index < meat_count and try_call(meat_array, "get_Item", index) or nil
		local meat_guid = read_member(part, "_MeatGuidNormal")
		local nullable_meat_index = try_call(parameters, "getMeatIndex(System.Guid)", meat_guid)
		local has_meat_index = read_member(nullable_meat_index, "_HasValue") == true
		local meat_index = has_meat_index and read_member(nullable_meat_index, "_Value") or nil
		if meat_index ~= nil and meat_index >= 0 and meat_index < meat_count then
			meat = try_call(meat_array, "get_Item", meat_index)
		end

		if meat ~= nil then
			for _, definition in ipairs(ELEMENT_DEFINITIONS) do
				local value = as_number(read_member(meat, definition.field)) or 0
				maximums[definition.type] = math.max(maximums[definition.type], value)
			end
		end
	end

	local weaknesses = {}
	for _, definition in ipairs(ELEMENT_DEFINITIONS) do
		local value = maximums[definition.type]
		if value >= ELEMENT_WEAKNESS_THRESHOLD then
			table.insert(weaknesses, { type = definition.type, value = value })
		end
	end

	table.sort(weaknesses, function(left, right)
		return left.value > right.value
	end)
	elemental_weakness_cache[em_id] = weaknesses
	return weaknesses
end

local function try_read_elemental_weaknesses(enemy_context, em_id)
	local ok, weaknesses = pcall(read_elemental_weaknesses, enemy_context, em_id)
	if not ok then
		diagnostics.last_error = "Elemental weakness read failed: " .. tostring(weaknesses)
		return {}
	end

	return weaknesses
end

local function read_severable_parts(enemy_context)
	local parts_module = read_member(enemy_context, "Parts")
	local damage_parts = read_member(parts_module, "_DmgParts")
	local break_parts = read_member(parts_module, "_BreakParts")
	local parameters = read_member(parts_module, "_ParamParts")
	local link_parts = read_member(parameters, "_LinkPartsIndexByBreakParts")
	local part_parameters = read_member(read_member(parameters, "_PartsArray"), "_DataArray")
	if damage_parts == nil or break_parts == nil or link_parts == nil or part_parameters == nil then
		return {}
	end

	local severable_parts = {}
	local seen_indices = {}
	local value_available = is_severable_part_value_available()
	local break_count = try_call(break_parts, "get_Count") or 0
	for break_index = 0, break_count - 1 do
		local break_part = try_call(break_parts, "get_Item", break_index)
		if break_part ~= nil and try_call(break_part, "get_IsLostParts") == true then
			local linked_indices = try_call(link_parts, "get_Item", break_index)
			local linked_count = try_call(linked_indices, "get_Count") or 0
			for linked_index = 0, linked_count - 1 do
				local part_index = as_number(try_call(linked_indices, "get_Item", linked_index))
				if part_index ~= nil and not seen_indices[part_index] then
					seen_indices[part_index] = true
					local damage_part = try_call(damage_parts, "get_Item", part_index)
					local current = as_number(try_call(damage_part, "get_Value()"))
					local maximum = as_number(try_call(damage_part, "get_DefaultValue()"))
					local has_value = current ~= nil and maximum ~= nil and maximum > 0
					local is_broken = try_call(break_part, "get_IsBreak") == true
					local part_parameter = try_call(part_parameters, "get_Item", part_index)
					local fixed_type = as_number(read_member(read_member(part_parameter, "_PartsType"), "_Value"))
					local type_name = fixed_type ~= nil and part_type_fixed_names[fixed_type] or nil
					table.insert(severable_parts, {
						index = part_index,
						name = PART_TYPE_LABELS[type_name] or type_name,
						ratio = is_broken and 0 or (has_value and math.max(0, math.min(1, current / maximum)) or 1),
						value_available = value_available and has_value,
					})
				end
			end
		end
	end

	table.sort(severable_parts, function(left, right)
		return left.index < right.index
	end)
	for index, part in ipairs(severable_parts) do
		part.name = part.name or "切断 " .. tostring(index)
	end
	return severable_parts
end

local function try_read_severable_parts(enemy_context)
	local ok, severable_parts = pcall(read_severable_parts, enemy_context)
	if not ok then
		diagnostics.last_error = "Severable part read failed: " .. tostring(severable_parts)
		return {}
	end

	return severable_parts
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
		em_id = ids.id,
		name = get_enemy_name(ids),
		health = math.max(0, health),
		max_health = max_health,
		ratio = math.max(0, math.min(1, health / max_health)),
		is_weakened = is_weakened,
		capture_rate = capture_rate,
		is_finished = is_finished,
		ailments = try_read_ailments(em),
		severable_parts = try_read_severable_parts(em),
		elemental_weaknesses = try_read_elemental_weaknesses(em, ids.id),
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

local function get_status_bar_height()
	return config.status_bar_height
end

local function get_ailment_height()
	return 2 * get_status_bar_height() + 3
end

local function get_severable_part_height()
	if not config.show_severable_parts then
		return 0
	end

	local row_height = math.max(10, math.floor(config.font_size * 0.65), get_status_bar_height())
	return 4 + row_height
end

local function get_monster_height()
	return config.font_size + 4 + config.bar_height + 4 + get_ailment_height() + get_severable_part_height()
end

local function draw_ailments(draw_list, x, y, ailments)
	local ailments_by_order = {}
	for _, ailment in ipairs(ailments or {}) do
		ailments_by_order[ailment.order] = ailment
	end

	local bar_height = get_status_bar_height()
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

local get_japanese_font

local function draw_severable_parts(draw_list, x, y, severable_parts)
	if not config.show_severable_parts then
		return 0
	end

	local font_size = math.max(10, math.floor(config.font_size * 0.65))
	local bar_height = get_status_bar_height()
	local row_height = math.max(font_size, bar_height)
	if #severable_parts == 0 then
		return row_height
	end

	local font = get_japanese_font(font_size)
	if font ~= nil then
		imgui.push_font(font)
	else
		imgui.push_font_size(font_size)
	end

	local column_spacing = 6
	local column_width = (config.bar_width - (#severable_parts - 1) * column_spacing) / #severable_parts
	for index, part in ipairs(severable_parts) do
		local column_x = x + (index - 1) * (column_width + column_spacing)
		local label_width = get_text_width(part.name)
		local bar_x = column_x + label_width + 5
		local bar_width = math.max(1, column_width - label_width - 5)
		local label_color = part.value_available and 0xFFE8E8E8 or 0xFF888888
		local fill_color = part.value_available and 0xFF3C8DFF or 0xFF777777
		draw_outlined_text(draw_list, column_x, y, label_color, part.name)
		draw_capsule_bar(
			draw_list,
			bar_x,
			y + (row_height - bar_height) / 2,
			bar_width,
			bar_height,
			part.ratio,
			0xAA2B2926,
			fill_color
		)
	end

	if font ~= nil then
		imgui.pop_font()
	else
		imgui.pop_font_size()
	end
	return row_height
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

local function load_d2d_image(path)
	if d2d == nil or d2d.Image == nil then
		return nil
	end

	local ok, image = pcall(d2d.Image.new, path)
	return ok and image or nil
end

local function get_enemy_icon(em_id)
	local name = enemy_id_names[em_id]
	if name == nil then
		return enemy_icon_unknown
	end

	if enemy_icon_cache[name] == nil then
		local path = string.format("%s/tex_EmIcon_%s_IMLM4.tex.241106027.png", ENEMY_ICON_PATH, string.upper(name))
		enemy_icon_cache[name] = load_d2d_image(path) or false
	end

	return enemy_icon_cache[name] or enemy_icon_unknown
end

local function draw_rounded_rect(x, y, width, height, radius, color)
	d2d.fill_rect(x + radius, y, width - radius * 2, height, color)
	d2d.fill_rect(x, y + radius, width, height - radius * 2, color)
	d2d.fill_circle(x + radius, y + radius, radius, color)
	d2d.fill_circle(x + width - radius, y + radius, radius, color)
	d2d.fill_circle(x + radius, y + height - radius, radius, color)
	d2d.fill_circle(x + width - radius, y + height - radius, radius, color)
end

local function draw_enemy_icons()
	if not config.enabled or d2d == nil then
		return
	end

	local rows = get_monster_rows()
	if #rows == 0 then
		return
	end

	local row_y = config.y
	local row_height = 0
	local monster_height = get_monster_height()
	local icon_plate_size = monster_height
	local enemy_icon_size = icon_plate_size - ENEMY_ICON_PADDING * 2

	for index, monster in ipairs(rows) do
		local column = (index - 1) % 2
		local x = config.x
			+ column * (icon_plate_size + ENEMY_ICON_BAR_SPACING + config.bar_width + config.column_spacing)
		local icon = get_enemy_icon(monster.em_id)

		draw_rounded_rect(x, row_y, icon_plate_size, icon_plate_size, ENEMY_ICON_CORNER_RADIUS, ENEMY_ICON_BORDER_COLOR)
		draw_rounded_rect(
			x + ENEMY_ICON_BORDER_WIDTH,
			row_y + ENEMY_ICON_BORDER_WIDTH,
			icon_plate_size - ENEMY_ICON_BORDER_WIDTH * 2,
			icon_plate_size - ENEMY_ICON_BORDER_WIDTH * 2,
			ENEMY_ICON_CORNER_RADIUS - ENEMY_ICON_BORDER_WIDTH,
			ENEMY_ICON_BACKGROUND_COLOR
		)
		if icon ~= nil then
			d2d.image(icon, x + ENEMY_ICON_PADDING, row_y + ENEMY_ICON_PADDING, enemy_icon_size, enemy_icon_size)
		end

		local weaknesses = monster.elemental_weaknesses or {}
		local weakness_y = row_y
			+ icon_plate_size
			- ENEMY_ICON_BORDER_WIDTH
			- config.weakness_icon_size
			+ config.weakness_icon_offset_y
		local maximum_weakness = weaknesses[1] and weaknesses[1].value or 0
		local strongest_weaknesses = {}
		local other_weaknesses = {}
		for _, weakness in ipairs(weaknesses) do
			if weakness.value == maximum_weakness then
				table.insert(strongest_weaknesses, weakness)
			else
				table.insert(other_weaknesses, weakness)
			end
		end

		local strongest_x = x + ENEMY_ICON_BORDER_WIDTH + config.weakness_icon_offset_x
		for weakness_index = #strongest_weaknesses, 1, -1 do
			local weakness = strongest_weaknesses[weakness_index]
			local element_icon = element_icons[weakness.type]
			if element_icon ~= nil then
				d2d.image(
					element_icon,
					strongest_x + (weakness_index - 1) * config.weakness_icon_spacing,
					weakness_y,
					config.weakness_icon_size,
					config.weakness_icon_size
				)
			end
		end

		local other_width = #other_weaknesses > 0
				and config.weakness_icon_size + (#other_weaknesses - 1) * config.weakness_icon_spacing
			or 0
		local other_x = x + icon_plate_size - ENEMY_ICON_BORDER_WIDTH - other_width + config.weakness_icon_offset_x
		for weakness_index = #other_weaknesses, 1, -1 do
			local weakness = other_weaknesses[weakness_index]
			local element_icon = element_icons[weakness.type]
			if element_icon ~= nil then
				d2d.image(
					element_icon,
					other_x + (weakness_index - 1) * config.weakness_icon_spacing,
					weakness_y,
					config.weakness_icon_size,
					config.weakness_icon_size
				)
			end
		end

		row_height = math.max(row_height, monster_height)
		if column == 1 or index == #rows then
			row_y = row_y + row_height + config.row_spacing
			row_height = 0
		end
	end
end

get_japanese_font = function(size)
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
	local icon_plate_size = get_monster_height()
	for index, monster in ipairs(rows) do
		local column = (index - 1) % 2
		local item_x = config.x
			+ column * (icon_plate_size + ENEMY_ICON_BAR_SPACING + config.bar_width + config.column_spacing)
		local x = item_x + icon_plate_size + ENEMY_ICON_BAR_SPACING
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
		local severable_height = draw_severable_parts(
			draw_list,
			x,
			y + config.font_size + 4 + config.bar_height + 4 + ailment_height + 4,
			monster.severable_parts or {}
		)
		local monster_height = math.max(
			icon_plate_size,
			config.font_size
				+ 4
				+ config.bar_height
				+ 4
				+ ailment_height
				+ (config.show_severable_parts and 4 or 0)
				+ severable_height
		)
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
		value_changed, config.show_all = imgui.checkbox("Show all", config.show_all)
		changed = changed or value_changed
		value_changed, config.show_severable_parts = imgui.checkbox("Show severable parts", config.show_severable_parts)
		changed = changed or value_changed
		value_changed, config.x = imgui.slider_int("X", config.x, 0, 1920)
		changed = changed or value_changed
		value_changed, config.y = imgui.slider_int("Y", config.y, 0, 1080)
		changed = changed or value_changed
		value_changed, config.font_size = imgui.slider_int("Font size", config.font_size, 10, 40)
		changed = changed or value_changed
		value_changed, config.bar_width = imgui.slider_int("Bar width", config.bar_width, 160, 640)
		changed = changed or value_changed
		value_changed, config.bar_height = imgui.slider_int("Bar height", config.bar_height, 6, 24)
		changed = changed or value_changed
		value_changed, config.status_bar_height =
			imgui.slider_int("Status/sever bar height", config.status_bar_height, 4, 20)
		changed = changed or value_changed
		value_changed, config.row_spacing = imgui.slider_int("Row spacing", config.row_spacing, 6, 24)
		changed = changed or value_changed
		value_changed, config.column_spacing = imgui.slider_int("Column spacing", config.column_spacing, 6, 24)
		changed = changed or value_changed
		value_changed, config.weakness_icon_size =
			imgui.slider_int("Weakness icon size", config.weakness_icon_size, 8, 32)
		changed = changed or value_changed
		value_changed, config.weakness_icon_spacing =
			imgui.slider_int("Weakness icon spacing", config.weakness_icon_spacing, 6, 20)
		changed = changed or value_changed
		value_changed, config.weakness_icon_offset_x =
			imgui.slider_int("Weakness icon X offset", config.weakness_icon_offset_x, -64, 64)
		changed = changed or value_changed
		value_changed, config.weakness_icon_offset_y =
			imgui.slider_int("Weakness icon Y offset", config.weakness_icon_offset_y, -64, 64)
		changed = changed or value_changed
		if imgui.button("Reset values") then
			config.x = DEFAULT_CONFIG.x
			config.y = DEFAULT_CONFIG.y
			config.font_size = DEFAULT_CONFIG.font_size
			config.bar_width = DEFAULT_CONFIG.bar_width
			config.bar_height = DEFAULT_CONFIG.bar_height
			config.status_bar_height = DEFAULT_CONFIG.status_bar_height
			config.row_spacing = DEFAULT_CONFIG.row_spacing
			config.column_spacing = DEFAULT_CONFIG.column_spacing
			config.weakness_icon_size = DEFAULT_CONFIG.weakness_icon_size
			config.weakness_icon_spacing = DEFAULT_CONFIG.weakness_icon_spacing
			config.weakness_icon_offset_x = DEFAULT_CONFIG.weakness_icon_offset_x
			config.weakness_icon_offset_y = DEFAULT_CONFIG.weakness_icon_offset_y
			changed = true
		end
		imgui.separator()
		imgui.text("Update callbacks: " .. tostring(diagnostics.update_calls))
		imgui.text("Large monster candidates: " .. tostring(diagnostics.boss_candidates))
		imgui.text("Tracked monsters: " .. tostring(#get_monster_rows()))
		imgui.text("Ailment entries: " .. tostring(diagnostics.ailment_count))
		if diagnostics.last_error ~= nil then
			imgui.text("Last error: " .. diagnostics.last_error)
		end

		if changed then
			config.font_size = math.max(10, config.font_size)
			config.status_bar_height = math.max(4, math.min(20, config.status_bar_height))
			config.weakness_icon_size = math.max(8, math.min(32, config.weakness_icon_size))
			config.weakness_icon_spacing = math.max(6, math.min(20, config.weakness_icon_spacing))
			config.weakness_icon_offset_x = math.max(-64, math.min(64, config.weakness_icon_offset_x))
			config.weakness_icon_offset_y = math.max(-64, math.min(64, config.weakness_icon_offset_y))
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

if d2d ~= nil then
	d2d.register(function()
		enemy_icon_unknown = load_d2d_image(ENEMY_ICON_PATH .. "/tex_EmIcon_EM0000_00_0_IMLM4.tex.241106027.png")
		for _, definition in ipairs(ELEMENT_DEFINITIONS) do
			element_icons[definition.type] = load_d2d_image(ELEMENT_ICON_PATH .. "/" .. definition.icon)
		end
	end, draw_enemy_icons)
end

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
