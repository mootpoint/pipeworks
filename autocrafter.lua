local autocrafterCache = {}  -- caches some recipe data to avoid to call the slow function minetest.get_craft_result() every second

local craft_time = 1

local function count_index(invlist)
	local index = {}
	for _, stack in pairs(invlist) do
		if not stack:is_empty() then
			local stack_name = stack:get_name()
			index[stack_name] = (index[stack_name] or 0) + stack:get_count()
		end
	end
	return index
end

local function set_infotext(pos, text)
	local meta = minetest.get_meta(pos)
	meta:set_string("infotext", text or "unconfigured Autocrafter")
end

local function get_craft(pos, inventory, hash)
	local hash = hash or minetest.hash_node_position(pos)
	local craft = autocrafterCache[hash]
	if not craft then
		if inventory:is_empty("recipe") then
			set_infotext(pos, nil)
			return
		end
		local recipe = inventory:get_list("recipe")
		local output, decremented_input = minetest.get_craft_result({method = "normal", width = 3, items = recipe})
		craft = {recipe = recipe, consumption=count_index(recipe), output = output, decremented_input = decremented_input}
		autocrafterCache[hash] = craft
		set_infotext(pos, "Autocrafter: " .. output.item:get_name())
	end
	-- only return crafts that have an actual result
	if not craft.output.item:is_empty() then
		return craft
	else
		set_infotext(pos, "Autocrafter: unknown recipe")
	end
end

local function start_crafter(pos)
	local meta = minetest.get_meta(pos)
	if meta:get_int("enabled") == 1 then
		local timer = minetest.get_node_timer(pos)
		if not timer:is_started() then
			timer:start(craft_time)
		end
	end
end

-- note, that this function assumes allready being updated to virtual items
-- and doesn't handle recipes with stacksizes > 1
local function after_recipe_change(pos, inventory)
	-- if we emptied the grid, there's no point in keeping it running or cached
	if inventory:is_empty("recipe") then
		minetest.get_node_timer(pos):stop()
		autocrafterCache[minetest.hash_node_position(pos)] = nil
		set_infotext(pos, nil)
		return
	end
	local recipe_changed = false
	local recipe = inventory:get_list("recipe")

	local hash = minetest.hash_node_position(pos)
	local craft = autocrafterCache[hash]

	if craft then
		-- check if it changed
		local cached_recipe = craft.recipe
		for i = 1, 9 do
			if recipe[i]:get_name() ~= cached_recipe[i]:get_name() then
				autocrafterCache[hash] = nil -- invalidate recipe
				craft = nil
				break
			end
		end
	end

	start_crafter(pos)
end

local function after_inventory_change(pos, inventory)
	start_crafter(pos)
end

local function autocraft(inventory, craft)
	if not craft then return false end
	local output_item = craft.output.item

	-- check if we have enough room in dst
	if not inventory:room_for_item("dst", output_item) then return false end
	local consumption = craft.consumption
	local inv_index = count_index(inventory:get_list("src"))
	-- check if we have enough material available
	for itemname, number in pairs(consumption) do
		if (not inv_index[itemname]) or inv_index[itemname] < number then return false end
	end
	-- consume material
	for itemname, number in pairs(consumption) do
		for i = 1, number do -- We have to do that since remove_item does not work if count > stack_max
			inventory:remove_item("src", ItemStack(itemname))
		end
	end

	-- craft the result into the dst inventory and add any "replacements" as well
	inventory:add_item("dst", output_item)
	for i = 1, 9 do
		inventory:add_item("dst", craft.decremented_input.items[i])
	end
	return true
end

-- returns false to stop the timer, true to continue running
-- is started only from start_autocrafter(pos) after sanity checks and cached recipe
local function run_autocrafter(pos, elapsed)
	local meta = minetest.get_meta(pos)
	local inventory = meta:get_inventory()
	local craft = get_craft(pos, inventory)

	for step = 1, math.floor(elapsed/craft_time) do
		local continue = autocraft(inventory, craft)
		if not continue then return false end
	end
	return true
end

local function update_autocrafter(pos)
	local meta = minetest.get_meta(pos)
	if meta:get_string("virtual_items") == "" then
		meta:set_string("virtual_items", "1")
		local inv = meta:get_inventory()
		for idx, stack in ipairs(inv:get_list("recipe")) do
			minetest.item_drop(stack, "", pos)
			stack:set_count(1)
			stack:set_wear(0)
			inv:set_stack("recipe", idx, stack)
		end
		after_recipe_change(pos, inv)
	end
end

local function set_formspec(meta, enabled)
	local state = enabled and "on" or "off"
	meta:set_string("formspec",
			"size[8,11]"..
			"list[context;recipe;0,0;3,3;]"..
			"image_button[3,2;1,1;pipeworks_button_" .. state .. ".png;" .. state .. ";;;false;pipeworks_button_interm.png]" ..
			"list[context;src;0,3.5;8,3;]"..
			"list[context;dst;4,0;4,3;]"..
			"list[current_player;main;0,7;8,4;]")
end

minetest.register_node("pipeworks:autocrafter", {
	description = "Autocrafter", 
	drawtype = "normal", 
	tiles = {"pipeworks_autocrafter.png"}, 
	groups = {snappy = 3, tubedevice = 1, tubedevice_receiver = 1}, 
	tube = {insert_object = function(pos, node, stack, direction)
			local meta = minetest.get_meta(pos)
			local inv = meta:get_inventory()
			local added = inv:add_item("src", stack)
			after_inventory_change(pos, inv)
			return added
		end, 
		can_insert = function(pos, node, stack, direction)
			local meta = minetest.get_meta(pos)
			local inv = meta:get_inventory()
			return inv:room_for_item("src", stack)
		end, 
		input_inventory = "dst", 
		connect_sides = {left = 1, right = 1, front = 1, back = 1, top = 1, bottom = 1}}, 
	on_construct = function(pos)
		local meta = minetest.get_meta(pos)
		set_formspec(meta)
		meta:set_string("infotext", "unconfigured Autocrafter")
		meta:set_string("virtual_items", "1")
		local inv = meta:get_inventory()
		inv:set_size("src", 3*8)
		inv:set_size("recipe", 3*3)
		inv:set_size("dst", 4*3)
	end,
	on_receive_fields = function(pos, formname, fields, sender)
		local meta = minetest.get_meta(pos)
		if fields.on then
			meta:set_int("enabled", 0)
			set_formspec(meta, false)
			minetest.get_node_timer(pos):stop()
			meta:set_string("infotext", text or "paused Autocrafter")
		elseif fields.off then
			meta:set_int("enabled", 1)
			set_formspec(meta, true)
			start_crafter(pos)
		else -- update formspec on esc for now
			set_formspec(meta, meta:get_int("enabled") == 1)
		end
	end,
	on_punch = update_autocrafter,
	can_dig = function(pos, player)
		update_autocrafter(pos)
		local meta = minetest.get_meta(pos)
		local inv = meta:get_inventory()
		return (inv:is_empty("src") and inv:is_empty("dst"))
	end, 
	after_place_node = function(pos)
		pipeworks.scan_for_tube_objects(pos)
	end,
	after_dig_node = function(pos)
		pipeworks.scan_for_tube_objects(pos)
		autocrafterCache[minetest.hash_node_position(pos)] = nil
	end,
	allow_metadata_inventory_put = function(pos, listname, index, stack, player)
		update_autocrafter(pos)
		local inv = minetest.get_meta(pos):get_inventory()
		if listname == "recipe" then
			local stack_copy = ItemStack(stack)
			stack_copy:set_count(1)
			inv:set_stack(listname, index, stack_copy)
			after_recipe_change(pos, inv)
			return 0
		else
			after_inventory_change(pos, inv)
			return stack:get_count()
		end
	end,
	allow_metadata_inventory_take = function(pos, listname, index, stack, player)
		update_autocrafter(pos)
		local inv = minetest.get_meta(pos):get_inventory()
		if listname == "recipe" then
			inv:set_stack(listname, index, ItemStack(""))
			after_recipe_change(pos, inv)
			return 0
		else
			after_inventory_change(pos, inv)
			return stack:get_count()
		end
	end,
	allow_metadata_inventory_move = function(pos, from_list, from_index, to_list, to_index, count, player)
		update_autocrafter(pos)
		local inv = minetest.get_meta(pos):get_inventory()
		local stack = inv:get_stack(from_list, from_index)
		stack:set_count(count)
		if from_list == "recipe" then
			inv:set_stack(from_list, from_index, ItemStack(""))
			after_recipe_change(pos, inv)
			return 0
		elseif to_list == "recipe" then
			local stack_copy = ItemStack(stack)
			stack_copy:set_count(1)
			inv:set_stack(to_list, to_index, stack_copy)
			after_recipe_change(pos, inv)
			return 0
		else
			after_inventory_change(pos, inv)
			return stack:get_count()
		end
	end,
	on_timer = run_autocrafter
})
