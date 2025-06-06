---------------------------
-- Speedrun.lua
-- TAS system for SMBX
---------------------------
-- Created by Sambo

local floor, ceil, max, huge = math.floor, math.ceil, math.max, math.huge

local LO, HI = 0, 1

-- SMWmap compatibility

local smwMap

-- done like this so that we don't load smwMap earlier than it normally would be
local function lazyLoadSmwMap()
	if (smwMap == nil) then
		smwMap = require("smwMap")
	end
end

local serializer = require("ext/serializer")
local clearpipe = require("blocks/ai/clearpipe")

local sr = {}

local keys = {"run", "altRun", "up", "down", "left", "right", "jump", "altJump", "dropItem", "pause"}
local charToKey = {
	j = "jump",
	a = "altJump",
	i = "dropItem",
	p = "pause",
	u = "up",
	d = "down",
	l = "left",
	r = "right",
	n = "run",
	t = "altRun",
}
local keyToChar = {}
for k,v in pairs(charToKey) do
	keyToChar[v] = k
end

local sectionInputs, currentInputs, currentSect, addr, runFunction, checkCondition
local showingMessageBox = false
local flags = {
	ignorePause = false,
	ignoreDeath = false,
}

local strToComparison = {
	["<"] = function(a, b) return a < b end,
	["<="] = function(a, b) return a <= b end,
	["=="] = function(a, b) return a == b end,
	["~="] = function(a, b) return a ~= b end,
	[">="] = function(a, b) return a >= b end,
	[">"] = function(a, b) return a > b end,
}
local function validateComparator(str)
	assert(type(str) == "string", "comparator must be in a string")
	assert(strToComparison[str], "Invalid comparator '"..str.."'")
end

local function copy(x)
	if type(x) == "table" then
		return table.deepclone(x)
	else
		return x
	end
end

-- args[1] is always the name of the function
-- args[#args] is generally the input codes
local builtins = {
	--- Repeat the given inputs n times. Example:
	-- {"dotimes",4,{
	--     "",{"tg"},  -- wait until on the ground (if starting on the ground, we IMMEDIATELY do the next input)
	--     "j",{"md"}, -- hold the jump key until beginning to move downward (this will occur at the apex of the jump)
	-- }}
	-- @tparam number n The number of times to repeat the sequence.
	-- @tparam table inputs The input sequence to repeat.
	-- Should probably be changed to call do() instead.
	dotimes = function(args)
		local reps = args[2]
		local inputSeq = args[3]
		for i = 1,reps do
			for k,v in ipairs(inputSeq) do
				table.insert(currentInputs, addr+k, copy(v))
			end
		end
		return -1
	end,
	--- Insert the given input instructions to the current position in the input list.
	-- @tparam table inputs The inputs to insert.
	["do"] = function(args)
		local inputSeq = args[2]
		for k,v in ipairs(inputSeq) do
			table.insert(currentInputs, addr+k, copy(v))
		end
		return -1  -- signal that inputs were not manipulated by this function so we will move on to the next instruction
	end,
	
	--- Check the first condition until it is met, then the second, and so on. This will be altered to be k-ary instead of taking a list of conditions as its input. Example:
	-- "rn",{"then",{{"tg"},{"4"}}}, -- run right until 4 frames after touching the ground.
	-- After the future change, the example would look like this:
	-- "rn",{"then",{"tg"},{4}},
	-- @tparam table conditions The conditions to check, in order.
	-- @return true if all the conditions have been met, in order.
	["then"] = function(args)
		if #args == 2 and type(args[2][1]) == "table" then
			-- old system - 1 arg containing all conditions {"then",{{c1},{c2}}},
			local conditions = args[2]
			if runFunction(conditions[1]) then
				table.remove(conditions, 1)
			end
			if #conditions == 0 then
				return true
			end
		else
			-- new system - k args, one for each condition {"then",{c1},{c2}},
			if runFunction(args[2]) then
				table.remove(args, 2)
			end
			if #args == 1 then
				return true
			end
		end
	end,
	
	--- k-ary or. Accepts any number of arguments. Example:
	-- {"or",{"tg"},{4}} -- evaluates to true when the player touches the ground OR after 4 ticks have passed, whichever happens first.
	-- @tparam Condition condition The first condition to check.
	-- @param ... Additional conditions.
	-- @return true if at least one of the conditions is true
	["or"] = function(args)
		for i=2,#args do
			if runFunction(args[i]) then
				return true
			end
		end
		return false
	end,
	
	-- Simple checks
	
	-- always true
	t = function() return true end,
	--- X Position Check. Examples:
	--	"rn",{"x",">=",512}, -- run to the right until x position is at least 512 pixels
	--	"ln",{"x","<",512}, -- run to the left until x position is less than 512 pixels
	-- @tparam string comparator The comparator to use. May be a string containing any Lua comparator ("<", "<=", "==", "~=", ">=", or ">").
	-- @tparam number position The x-position to check against.
	x = function(args)
		validateComparator(args[2])
		return strToComparison[args[2]](player.x, args[3])
	end,
	--- y position check
	y = function(args)
		validateComparator(args[2])
		return strToComparison[args[2]](player.y, args[3])
	end,
	--- x speed check
	sx = function(args)
		validateComparator(args[2])
		return strToComparison[args[2]](player.speedX, args[3])
	end,
	--- y speed check
	sy = function(args) 
		validateComparator(args[2])
		return strToComparison[args[2]](player.speedY, args[3])
	end,
	--- moving up
	mu = function() return player.speedY < 0 end,
	--- moving down
	md = function() return not player:isGroundTouching() and player.speedY >= 0 end,
	--- moving left
	ml = function() return player.speedX <= 0 end,
	--- moving right
	mr = function() return player.speedX >= 0 end,
	--- touching ground
	tg = function() return player:isGroundTouching() end,
	--- not touching ground
	ntg = function() return not player:isGroundTouching() end,
	--- showing message box
	mb = function() return showingMessageBox end,
	--- climbing
	cl = function() return player:isClimbing() end,
	-- forced state
	fs = function() return player.forcedState ~= FORCEDSTATE_NONE end,
	--- no forced state
	nfs = function() return player.forcedState == FORCEDSTATE_NONE end,
	--- in water
	iw = function() return player.IsInWater == -1 end,
	--- not in water
	niw = function() return player.IsInWater ~= -1 end,
	--- dead -- mainly used as a test for the optimize function
	dead = function() return player.deathTimer > 0 end,
	--- standing on NPC
	snpc = function() return player.standingNPC ~= nil end,
	--- holding an item
	hnpc = function() return player.holdingNPC ~= nil end,
	--- not holding an item
	nhnpc = function() return player.holdingNPC == nil end,
	
	--- smwMap functions
	-- if the episode does not contain smwMap, calling these will cause an error
	-- if the level that is being played does not load smwMap normally, these will try to load it, so don't call them if smwMap isn't running
	
	--- smwMap x position check
	-- same as x(), but for smwMap
	smwMapX = function(args)
		lazyLoadSmwMap()
		validateComparator(args[2])
		return strToComparison[args[2]](smwMap.mainPlayer.x, args[3])
	end,
	--- smwMap y position check
	-- same as y(), but for smwMap
	smwMapY = function(args)
		lazyLoadSmwMap()
		validateComparator(args[2])
		return strToComparison[args[2]](smwMap.mainPlayer.y, args[3])
	end,
	--- smwMap player state
	-- compare smwMap main player's state value to the given state value
	-- the values for each state can be found in utils.SMWMAP_PLAYER_STATE
	smwMapState = function(args)
		lazyLoadSmwMap()
		validateComparator(args[2])
		return strToComparison[args[2]](smwMap.mainPlayer.state, args[3])
	end,
}

--[[ while loop
{"while",{condition},{
	actions
}},
]]
builtins["while"] = function(args)
	-- Misc.dialog(currentInputs)
	if runFunction(args[2]) then
		builtins["do"]{args[1],{args}} -- insert a copy of this function
		builtins["do"]{args[1],args[3]} -- insert the actions
	end
	-- Misc.dialog(currentInputs)
	return -1
end

--[[ conditional branch
{"if",{condition},
		{actions if true},
	{actions if false},
},
]]
builtins["if"] = function(args)
	-- Misc.dialog(currentInputs)
	local condition = args[2]
	local trueActions = args[3]
	local falseActions = args[4]
	
	local result = runFunction(condition)
	if result and trueActions then
		builtins["do"]{args[1], trueActions}
	elseif not result and falseActions then
		builtins["do"]{args[1], falseActions}
	end
	-- Misc.dialog(currentInputs)
	return -1
end

--[[
{"when",{condition},{
	actions if true
}},
]]
builtins["when"] = function(args)
	return builtins["if"]{args[1], args[2], args[3], nil}
end

--[[
{"unless",{condition},{
	actions if false
}},
]]
builtins["unless"] = function(args)
	return builtins["if"]{args[1], args[2], nil, args[3]}
end

--- Generate a random input that lasts for a random number of frames (this isn't really that useful aside from silliness while waiting)
-- @tparam table inputs A list of inputs to randomly choose from.
-- @tparam number min The shortest input that can be randomly chosen.
-- @tparam[opt] number max The longest input that can be randomly chosen. Will be the same as min if not set.
builtins["randomInput"] = function(args)
	table.insert(currentInputs, addr+1, RNG.irandomEntry(args[2]))
	table.insert(currentInputs, addr+2, {RNG.randomInt(args[3], args[4] or args[3])})
	return -1
end

function checkCondition(instr)
	-- implicit 'then' if instr is of the form 'inputs,{{c1},{c2}}'
	if type(instr[1]) == "table" then
		return checkCondition{"then",instr}
	end
	
	-- Misc.dialog(instr)
	local func = instr[1]
	local typ = type(func)
	if typ == "number" then
		instr[1] = func - 1
		return func == 0
	elseif typ == "string" then
		if flags[func] ~= nil then
			flags[func] = not flags[func]
			return true
		else
			if builtins[func] then
				return builtins[func](instr)
			else
				error("No builtin with name '"..func.."'")
			end
		end
	elseif typ == "function" then
		return func(instr)
	else
		error("Invalid instruction: "..tostring(func))
	end
end

function runFunction(instr)
	if not instr then
		if type(currentInputs[addr]) == "string" then
			instr = currentInputs[addr+1]
		else
			instr = currentInputs[addr]
		end
	end
	
	-- process the condition for this instruction; return true if condition has been met
	-- Misc.dialog(currentInputs)
	-- Misc.dialog(instr)
	return checkCondition(instr)
end

local inputOverride
local inputOverrideTimer = 0
 
local function overrideInputInternal(replace, subtract, add, duration)
	if replace == nil then replace = true end
	subtract = subtract or ""
	add = add or ""
	duration = duration or 1
	
	-- print("overrideInput("..tostring(replace)..",")
	-- print("              "..tostring(subtract)..",")
	-- print("              "..tostring(add)..",")
	-- print("              "..tostring(duration))
	-- print(")")
	
	if replace then
		inputOverride = add
	else
		inputs = currentInputs[addr] or ""
		for c in subtract:gmatch(".") do
			inputs = inputs:gsub(c, "")
		end
		inputOverride = inputs..add
	end
	inputOverrideTimer = duration
end

--- Override the current input instruction for a certain number of frames. Polymorphic. Forms:
-- overrideInput(replace): replace the current input for 1 frame
-- overrideInput(replace, duration): replace the current input for <duration> frames
-- overrideInput(add, subtract): remove <subtract> from the current inputs, then append <add>, for 1 frame
-- overrideInput(add, subtract, duration): remove <subtract> from the current inputs, then append <add>, for <duration> frames
-- @tparam[opt=1] number duration The number of frames for which inputs will be overriden.
-- @tparam[opt=""] string add The inputs that will be added to the current input instruction.
-- @tparam string[opt=""] subtract The inputs that will be subtracted from the current input instruction. This will occur BEFORE adding inputs.
-- @tparam[opt=""] string replace The inputs that will replace the current input instruction.
function sr.overrideInput(...)
	if arg.n == 1 then  -- replace
		overrideInputInternal(true, nil, arg[1])
	elseif arg.n == 2 then
		if type(arg[2]) == "number" then  -- replace, duration
			overrideInputInternal(true, nil, arg[1], arg[2])
		else -- add, subtract
			overrideInputInternal(false, arg[2], arg[1])
		end
	elseif arg.n == 3 then  -- add, subtract, duration
		overrideInputInternal(false, arg[2], arg[1], arg[3])
	else
		error("Invalid arguments")
	end
end

local mutantVineSequence
local mutantVineTimer

local function updateVineControl()
	if Misc.isPaused() or not mutantVineSequence then return end
	
	if mutantVineTimer <= 0 then
		mutantVineTimer = 16
		overrideInputInternal(false, "udlr", mutantVineSequence[1], 1)
		mutantVineSequence[2] = mutantVineSequence[2] - 1
		if mutantVineSequence[2] == 0 then
			for i = 1,2 do
				table.remove(mutantVineSequence, 1)
			end
			if #mutantVineSequence == 0 then
				mutantVineSequence = nil
			end
		end
	end
	mutantVineTimer = mutantVineTimer - 1
end

builtins["mvc"] = function(args)
	-- print("called mvc!")
	mutantVineTimer = 14
	mutantVineSequence = args[2]
	-- Misc.dialog(mutantVineSequence)
	return -1
end

GameData.speedrunOptimization = GameData.speedrunOptimization or {history={}} -- for the stuff that needs to persist between tests
local speedrunOptimization = {} -- for everything else
speedrunOptimization.started = false
--- Optimize a timing-based input instruction.
-- @tparam string input The inputs whose time must be optimized.
-- @tparam number mode The optimization mode. May be utils.optimizationModes.LO or utils.optimizationModes.HI.
-- @tparam function|builtinName failureConditionLo The low failure condition. If it evaluates to true, the input time is marked as too low. Must be a function (that should return true/false) or the name of a builtin condition.
-- @tparam function|builtinName failureConditionHi The high failure condition. If it evaluates to true, the input time is marked as too high. Must be a function (that should return true/false) or the name of a builtin condition.
-- @tparam function|builtinName successCondition The success condition. If it evaluates to true, the input time is marked a working option. Must be a function (that should return true/false) or the name of a builtin condition.
-- @tparam[opt=1] number loTime The minumum amount of time the input should last.
-- @tparam[opt=nil] number hiTime The maximum amount of time the input should last
builtins["optimize"] = function(args)
	assert(args[2], "No input to optimize!")
	assert(args[3], "No optimization mode specified!")
	assert(args[4], "No low failure condition set!")
	assert(args[5], "No high failure condition set!")
	assert(args[6], "No success condition set!")	
	
	speedrunOptimization.input = args[2]
	speedrunOptimization.mode = args[3]
	speedrunOptimization.failureConditionLo = args[4]
	speedrunOptimization.failureConditionHi = args[5]
	speedrunOptimization.successCondition = args[6]
	
	local opt = GameData.speedrunOptimization
	opt.loTime = opt.loTime or args[7] or 0
	opt.hiTime = opt.hiTime or args[8]
	
	local round = (speedrunOptimization.mode == LO) and floor or ceil
	opt.midTime = opt.hiTime and round((opt.loTime + opt.hiTime) / 2) or max(opt.loTime * 2, 1)
	-- Misc.dialog(opt.loTime.." <= "..opt.midTime.." <= "..tostring(opt.hiTime))
	table.insert(opt.history, opt.midTime) -- DEBUG
	
	table.insert(currentInputs, addr+1, speedrunOptimization.input)
	table.insert(currentInputs, addr+2, {opt.midTime})
	
	speedrunOptimization.started = true
	GameData.speedrunOptimization = opt
	
	return -1
end

--- Clear all optimization data
builtins["clearOptimizationData"] = function(args)
	GameData.speedrunOptimization = {history={}}
	Misc.dialog("Optimization data cleared!")
	return -1
end

--- Update the optimization data if an optimization condition has been met. Assume that an optimization is currently taking place. Based on a modified version of the binary search algorithm.
local function checkOptimizationConditions()
	local opt = GameData.speedrunOptimization
	
	local done = false
	if checkCondition(speedrunOptimization.failureConditionLo) then
		if opt.hiTime then
			opt.loTime = opt.midTime + 1
		else
			opt.loTime = max(opt.loTime * 2, 1)
		end
		done = "Too low!"
	elseif checkCondition(speedrunOptimization.failureConditionHi) then
		opt.hiTime = opt.midTime - 1
		done = "Too high!"
	elseif checkCondition(speedrunOptimization.successCondition) then
		if opt.mode == LO then
			opt.hiTime = opt.midTime
		else
			opt.loTime = opt.midTime
		end
		done = "Within range!"
	end
	
	if done then
		-- Misc.dialog(done)
		-- Misc.dialog(opt.history)
		if opt.loTime == opt.hiTime then -- found the best time
			Misc.dialog("Optimal time: "..opt.loTime.." ticks")
			Misc.dialog(opt.history)
		elseif opt.loTime > (opt.hiTime or huge) then
			Misc.dialog("Options for time value exhausted")
			Misc.dialog(opt.history)
		end
		Level.exit()
	end
end

local lastKeys = {}
-- Manipulate a key in rawKeys by circumventing the table's __newindex function
-- This should normally never be done, but in the case of a TASBot...
local function setRawKey(k, v)
	if not lastKeys[k] and v then
		v = KEYS_PRESSED
	elseif lastKeys[k] and v then
		v = KEYS_DOWN
	elseif lastKeys[k] and not v then
		v = KEYS_UNPRESSED
	elseif not lastKeys[k] and not v then
		v = KEYS_UP
	end
	rawset(player.rawKeys, k, v)
	lastKeys[k] = (v ~= nil) and (v ~= false)
end

local function manageInputs()
	local inputs
	if inputOverrideTimer > 0 then
		inputs = inputOverride
		inputOverrideTimer = inputOverrideTimer - 1
	else
		inputs = currentInputs[addr]
	end
	-- process player inputs
	local newkeys = {}
	for c in inputs:gmatch(".") do
		newkeys[charToKey[c] or error("Invalid key code: "..c)] = true
	end
	for _,k in ipairs(keys) do
		player.keys[k] = newkeys[k]
		setRawKey(k, newkeys[k])
	end
	clearpipe.overrideInput(player, "up", newkeys.up)
	clearpipe.overrideInput(player, "down", newkeys.down)
	clearpipe.overrideInput(player, "left", newkeys.left)
	clearpipe.overrideInput(player, "right", newkeys.right)
end

local function runInstruction(recursiveCall)

	if Misc.isPaused() and not flags.ignorePause then return end

	local doNext
	if inputOverrideTimer <= 0 then
		if not recursiveCall and speedrunOptimization.started then
			checkOptimizationConditions()
		end
		doNext = runFunction()
	end
	
	if addr <= #currentInputs then
		if not doNext then
			manageInputs()
		else
			if doNext == true then
				addr = addr + 2
			elseif doNext == -1 then
				addr = addr + 1
			end
			if addr <= #currentInputs then
				runInstruction(true)
			end
		end
	end
end

local file
local fullpath

-----------------------------------------------
-- MARK: Input recording
-----------------------------------------------

--- Set this to true to record a log of inputs. Recorded inputs are saved in __runs/<level name>.rec on death or level exit.
sr.recordInputs = false

--- Set this to true to play back the inputs logged in the .rec file for the current level.
sr.playbackInputs = false

--- Simultaneous Recording and Playback

-- If both playbackInputs and recordInputs are set, recorded inputs will be played back until the player makes a new input.
-- After a new input is made, playback will stop until the level is reloaded, but recording will continue. This allows for combining
-- multiple takes into a single recording.

--- Set this to true to restore the recording to the way it was before the last run through the level. Useful in case you accidentally
-- input over a part of the recording that you wanted to keep, like a fool. (This happened to me, so I added this)
-- Don't forget to clear this after restoring. This won't do anything if playbackInputs is not set.
sr.restoreBackupRecording = false

-- Inputs recorded this session. Has a subtable for each section of the level.
local recordedInputs = {}
-- True if the level ended, either through player death or level restart.
local endedLevel
-- True if new inputs have been recorded during this play session. Reset when the level ends.
local recordedNewInputs = false

local function getCurrentInputString()
	local result = ""
	for _,v in ipairs(keys) do
		if player.rawKeys[v] then
			result = result..keyToChar[v]
		end
	end
	return result
end

--- Add the current inputs from the player to the recording.
-- @tparam string currentInputs Inputs this tick.
-- @return true if more than zero inputs were made this tick.
local function handleInputRecording(currentInputs)
	local s = player.section
	if not recordedInputs[s] then
		recordedInputs[s] = {}
	end
	local count = #recordedInputs[s]
	if currentInputs == recordedInputs[s][count-1] then
		recordedInputs[s][count][1] = recordedInputs[s][count][1] + 1
	else
		table.insert(recordedInputs[s], count+1, currentInputs)
		table.insert(recordedInputs[s], count+2, { 1 })
	end
	return #currentInputs > 0
end

--------------------------------------------
-- MARK: Events
--------------------------------------------

-- registerEvent(sr, "onInputUpdate")
function sr.onInitAPI()
	registerEvent(sr, "onInputUpdate")
	registerEvent(sr, "onDrawEnd")
	-- registerEvent(sr, "onInputUpdate", "onInputUpdateLate", false)
	-- registerEvent(sr, "onTick", "onInputUpdateLate")
	registerEvent(sr, "onStart", "onStart", false)
	registerEvent(sr, "onMessageBox")
	-- stuff to find a working seed while AFK
	-- registerEvent(sr, "onPostPlayerKill", "onEndLevel")
	-- registerEvent(sr, "onExitLevel", "onEndLevel")
	-- input recording stuff
	registerEvent(sr, "onPostPlayerKill", "onEndLevel")
	registerEvent(sr, "onExitLevel", "onEndLevel")
end

local seed
local legacySeed
function sr.onPostPlayerKill(p)
	Level.exit(0) -- will immediately restart the level if in testing mode
end

function sr.onExitLevel(winType)
	if winType ~= LEVEL_WIN_TYPE_NONE then
		Misc.richDialog("succeeded on seed "..seed)
	end
end

function sr.onMessageBox()
	showingMessageBox = true
end

function sr.onStart()
	file = "__runs/"..Level.filename():gsub(".lvlx", ""):gsub(".lvl","")
	local epPath = Misc.episodePath()
	fullpath = epPath..file
	local restorePath = epPath.."__runs/latest.rec.bak"
	local f = io.open(fullpath..".lua")
	local seedOverride
	local legacySeedOverride
	if f ~= nil then
		f:close()
		local inputList = require(file)
		if inputList.global then
			currentInputs = inputList
			addr = 1
			assert(currentInputs, "currentInputs empty after set")
		else
			sectionInputs = inputList
			assert(sectionInputs, "sectionInputs empty after set")
		end
		seedOverride = inputList.seed
		legacySeedOverride = inputList.legacySeed
	else
		sectionInputs = {}
	end
	if sr.playbackInputs then
		if sr.restoreBackupRecording then
			f = io.open(restorePath)
			if not f then
				Misc.dialog("Unable to restore backup: backup file not found.")
				return
			end
			local str = f:read("*all")
			f:close()
			f = io.open(fullpath..".rec", "w")
			f:write(str)
			f:close()
			Misc.dialog("Backup restored. Remove the line that sets the restoreBackupRecording from your code, then hit OK to restart.")
			endedLevel = true
			Level.finish(LEVEL_END_STATE_ROULETTE, false)
		else
			f = io.open(fullpath..".rec")
			local str = f:read("*all")
			sectionInputs = serializer.deserialize(str)
			f:close()
			f = io.open(restorePath, "w")
			f:write(str)
			f:close()
		end
	end
	-- Disable randomization
	RNG.seed = seedOverride or 8675309
	LegacyRNG.seed = legacySeedOverride or 8675309
end

function sr.onInputUpdate()

	if lunatime.tick() == 0 then return end
	if sectionInputs and player.section ~= currentSect then
		currentSect = player.section
		if sectionInputs[player.section] then
			currentInputs = table.deepclone(sectionInputs[player.section])
		else
			currentInputs = nil
		end
		addr = 1
		-- Misc.richDialog(currentInputs)
	end
	
	if not Misc.isPaused() then
		updateVineControl()
	end

	if player:isDead() and not flags.ignoreDeath then return end

	local inputsThisTick
	if sr.recordInputs then
		inputsThisTick = getCurrentInputString()
		recordedNewInputs = recordedNewInputs or #inputsThisTick > 0
	end
	
	-- Misc.dialog("inputsThisTick: "..inputsThisTick)
	-- Misc.dialog("recordedNewInputs: "..tostring(recordedNewInputs))
	-- Misc.dialog("addr <=> #currentInputs: "..tostring(addr).." <=> "..tostring(#currentInputs))
	if not recordedNewInputs and currentInputs and addr <= #currentInputs then
		runInstruction() -- changes the input
		inputsThisTick = getCurrentInputString()
	end

	-- Misc.dialog("forced inputsThisTick: "..inputsThisTick)
	if sr.recordInputs then
		handleInputRecording(inputsThisTick)
	end
	
	showingMessageBox = false
end

-- still pressed by this point
function sr.onInputUpdateLate()
	if lunatime.tick() == 0 then return end
	-- if checkCondition{"tg"} then
		-- Misc.dialog("speedrun onInputUpdateLate")
	-- end
	-- manageInputs()
	-- if player.keys.jump == KEYS_PRESSED and Misc.isPaused() then
		-- Misc.dialog("sr2: jump pressed")
	-- end
	-- if Misc.isPaused() then
		-- Misc.dialog("sr: "..tostring(player.keys.jump))
	-- end
end

function sr.onDrawEnd()
	for _,k in ipairs(keys) do
		rawset(player.rawKeys, k, nil)
	end
end

function sr.onEndLevel()
	-- This will be called more than once if the player dies and the level is restarted
	-- We only want it to run once per level load
	-- Only overwrite the recording if new inputs were recorded
	if sr.recordInputs and recordedNewInputs and not endedLevel then
		recordedInputs.version = 0
		local sectionInputs = recordedInputs[currentSect]
		-- shorten the length of the last input if it's a null input
		if sectionInputs[#sectionInputs - 1] == "" then
			sectionInputs[#sectionInputs][1] = 1
		end
		local f = assert(io.open(Misc.episodePath()..file..".rec", "w"))
		f:write(serializer.serialize(recordedInputs))
		f:close()
		endedLevel = true
		recordedNewInputs = false
	end
end

return sr
