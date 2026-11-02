--[[
	@name suggestions
	@author driftingAurora, dullflowerr, alias; kioukaii
	@time June 12, 2026
]]

--// imports
local Imports = {
	Suggest = require("../../motion/suggest"),
    Providers = require("./providers"),
    
	Text = require("../misc/text"),
	View = require("../misc/view"),
}

--// locals
local function startsWith(value, prefix)
	return string.sub(value, 1, #prefix) == prefix
end

local function contains(value, needle)
	return string.find(value, needle, 1, true) ~= nil
end

local function rankSuggestion(query, suggestion)
	local lower = string.lower(tostring(suggestion or ""))
    local firstWord = string.match(lower, "^(%S+)") or lower
    
	local score = 0

	if lower == query then
        score = 1200
        
	elseif firstWord == query then
        score = 1100
        
	elseif startsWith(firstWord, query) then
        score = 1000
        
	elseif startsWith(lower, query) then
        score = 900
        
	elseif contains(firstWord, query) then
        score = 650
        
	elseif contains(lower, query) then
		score = 420
	else
		local fuzzy = Imports.Text.fuzzyScore(query, lower)
		if fuzzy <= 0 then
			return 0
		end
		score = fuzzy
	end

	if string.find(lower, " ", 1, true) then
		score -= 80
	end

	return score - math.min(#lower, 80) * 0.2
end

local function compareRanked(a, b)
	if a.score ~= b.score then
		return a.score > b.score
    end
    
	if #a.text ~= #b.text then
		return #a.text < #b.text
	end

	return string.lower(a.text) < string.lower(b.text)
end

local function rankList(source, query)
    query = string.lower(tostring(query or ""))
    
    local ranked = {}
    local seen = {}
    
	for _, item in source or {} do
		local itemText = tostring(item)
        local key = string.lower(itemText)
        
		if itemText ~= "" and not seen[key] then
            seen[key] = true
            
			local score = query == "" and (1000 - math.min(#key, 80) * 0.2) or rankSuggestion(query, itemText)
            
            if score > 0 then
				table.insert(ranked, { text = itemText, score = score })
			end
		end
    end
    
	table.sort(ranked, compareRanked)

	local matches = {}

	for _, item in ranked do
		table.insert(matches, item.text)
	end

	return matches
end

local function placeList(session)
	local refs = session.refs
	local useSecondRoot = session.activeChannel == 2 and session.hasSecondChat and session.secondDetached
    
    local root = useSecondRoot and refs.secondRoot or refs.root
	if refs.suggList.Parent == root then
		return
	end

    refs.suggShadow.Parent = root
    refs.suggList.Parent = root
end

-- The first entry a window of `slots` rows shows when the canvas is scrolled to
-- `canvasY`. Pure, so what is on screen follows from the list and the scroll alone.
local function firstVisible(canvasY, rowHeight, count, slots)
	local first = math.floor(math.max(0, canvasY) / rowHeight) + 1

	return math.clamp(first, 1, math.max(1, count - slots + 1))
end

-- One row more than the panel fits, because a scrolled canvas shows part of two.
local function windowSlots(limit, count)
	return math.min(count, limit + 1)
end

--// public api
local Suggestions = {}

function Suggestions.attach(Session)
	function Session:placeSuggestions()
		placeList(self)
	end

	function Session:refreshMeasured(channel)
        self.refreshMeasuredToken[channel] = (self.refreshMeasuredToken[channel] or 0) + 1
        
        local token = self.refreshMeasuredToken[channel]
        
		task.delay(0.04, function()
            if self.refs and self.refreshMeasuredToken[channel] == token then
                
				self:queueWidthRefresh(channel)
			end
		end)
	end

	function Session:suggestionsFor(text)
        text = string.lower(Imports.Text.cleanStart(text))
        
		if text == "" then
			return {}
		end

		return rankList(self.suggestionSource, text)
	end

	function Session:resolveSuggestions(text)
        local chip = if type(self.focusedChip) == "function" then self:focusedChip() else self.activeChip
        
		if chip and type(chip.arg) == "table" then
			local source = Imports.Providers.resolve(chip.arg)

			if text == "" then
				return source, text
			end

			local matches = rankList(source, text)

			if #matches == 0 then
				matches = source
			end

			return matches, text
		end

		local query = string.lower(Imports.Text.cleanStart(text))

		if string.find(query, "%s") then
			return {}, query
		end

		return self:suggestionsFor(query), query
	end

	function Session:hideSuggestions()
        local suggList = self.refs.suggList
        
		if typeof(suggList) ~= "Instance" or not suggList:IsA("ScrollingFrame") then
			return
		end

		Imports.View.clearSuggestionConnections(self)
		self.suggestionRows = {}

		if not suggList.Visible and #self.currentSuggestions == 0 then
            self.suggestionsHiding = false
            
			if
				typeof(self.refs.suggShadow) == "Instance"
				and self.refs.suggShadow:IsA("ImageLabel")
			then
                self.refs.suggShadow.ImageTransparency = 1
                self.refs.suggShadow.Visible = false
			end
			return
		end

        self.currentSuggestions = {}
        
		self.selectedSuggestion = nil
        self.suggestionsHiding = true
        
        self.suggestToken += 1
		
		Imports.Suggest.hide(self)
	end

	function Session:syncSelection()
		local suggList = self.refs.suggList
		if typeof(suggList) ~= "Instance" or not suggList:IsA("ScrollingFrame") then
			return
		end

		local config = self.config
		for _, row in self.suggestionRows do
			local suggestion = self.currentSuggestions[row.index]
			if not suggestion then
				continue
			end

			local selected = self.selectedSuggestion == row.index
			local richText = Imports.View.richSuggestion(suggestion, self.suggestionQuery, config)

			row.label.Font = selected and config.font.title or config.font.body
			row.label.Text = selected and ("<b>" .. richText .. "</b>") or richText

			row.button.BackgroundTransparency = selected and 0.72 or 1
			row.button.BackgroundColor3 = config.color.suggPanel
		end
	end

	function Session:renderSuggestionWindow()
		local suggList = self.refs.suggList
		local rows = self.suggestionRows
		local rowHeight = self.config.panel.suggestionHeight

		local count = #self.currentSuggestions
		local slots = math.min(#rows, count)
		local first = firstVisible(suggList.CanvasPosition.Y, rowHeight, count, slots)

		self.refs.suggSpacer.Size = UDim2.new(1, 0, 0, (first - 1) * rowHeight)

		for slot, row in rows do
			row.index = first + slot - 1
			row.button.Visible = slot <= slots
		end

		self:syncSelection()
	end

	function Session:ensureSuggestionRows(slots, showing)
		local suggList = self.refs.suggList
		local config = self.config
		local panel = config.panel
		local rows = self.suggestionRows

		if #rows == 0 then
			for _, child in suggList:GetChildren() do
				if child:IsA("TextButton") then
					child:Destroy()
				end
			end

			table.insert(
				self.suggestionConnections,

				suggList:GetPropertyChangedSignal("CanvasPosition"):Connect(function()
					self:renderSuggestionWindow()
				end)
			)
		end

		local slide = showing and 0 or (config.motion.textSlideOffset or 10)

		for slot = #rows + 1, slots do
			local button = Imports.View.make("TextButton", {
                LayoutOrder = slot,

				Size = UDim2.new(1, 0, 0, panel.suggestionHeight),
                BackgroundColor3 = config.color.suggPanel,

                BackgroundTransparency = 1,
				BorderSizePixel = 0,
                ZIndex = 32,

                AutoButtonColor = false,

                Name = "Sugg_" .. tostring(slot),
                Text = "",
            }, suggList)

			Imports.View.corner(button, panel.suggestionRadius or 10)

			local label = Imports.View.make("TextLabel", {
                Name = "Label",

                Position = UDim2.new(0, config.layout.paddingX, 0, 1 + slide),
                Size = UDim2.new(1, -(config.layout.paddingX * 2), 1, -2),

                TextYAlignment = Enum.TextYAlignment.Center,
                TextXAlignment = Enum.TextXAlignment.Left,

                TextSize = config.layout.suggTextSize,
                TextColor3 = config.color.suggText,
                Font = config.font.body,

                BackgroundTransparency = 1,
                TextTransparency = showing and config.transparency.suggText or 1,
                ZIndex = 33,

                Text = "",
                RichText = true,
			}, button)

			local row = { button = button, label = label, index = slot }
			rows[slot] = row

			table.insert(
                self.suggestionConnections,

				button.Activated:Connect(function()
					self:applySuggestion(self.currentSuggestions[row.index])
				end)
			)
			table.insert(
                self.suggestionConnections,

				button.MouseEnter:Connect(function()
					self.selectedSuggestion = row.index
					self:syncSelection()
				end)
			)

			if not showing then
				Imports.Suggest.item(self, label)
			end
		end
	end

	function Session:moveSelection(delta)
		local count = #self.currentSuggestions
		if count == 0 then
			return false
		end

        local current = self.selectedSuggestion or 1
        
		self.selectedSuggestion = ((current - 1 + delta) % count) + 1
        self:syncSelection()

		local suggList = self.refs.suggList
		if suggList:IsA("ScrollingFrame") then
			local rowHeight = self.config.panel.suggestionHeight
			local top = 2 + ((self.selectedSuggestion - 1) * rowHeight)

			local position = suggList.CanvasPosition.Y
			local bottom = top + rowHeight

			if top < position then
				position = top

			elseif bottom > position + suggList.AbsoluteWindowSize.Y then
				position = bottom - suggList.AbsoluteWindowSize.Y
			end

			suggList.CanvasPosition = Vector2.new(0, math.max(0, position))
		end
        
		return true
	end

	function Session:updateSuggestions(text)
		if not self.isExpanded then
			return
		end

        local suggList = self.refs.suggList
        local config = self.config
        local panel = config.panel
        
		if typeof(suggList) ~= "Instance" or not suggList:IsA("ScrollingFrame") then
			return
		end

		local showing = suggList.Visible and not self.suggestionsHiding
		local list, query = self:resolveSuggestions(text)
		local limit = math.max(0, math.floor(tonumber(panel.maxSuggestions) or 5))
		local count = #list
		local visibleCount = math.min(count, limit)

		if visibleCount == 0 then
			self:hideSuggestions()
			return
		end

        self.suggestionQuery = query
        self.currentSuggestions = table.clone(list)
        
        self.suggestionsHiding = false

        self.selectedSuggestion = 1
        self.suggestToken += 1

        self:placeSuggestions()
		self:ensureSuggestionRows(windowSlots(limit, count), showing)

		suggList.CanvasPosition = Vector2.zero
		suggList.CanvasSize = UDim2.fromOffset(0, (count * panel.suggestionHeight) + 4)

		self:renderSuggestionWindow()
        Imports.Suggest.reveal(self, visibleCount)
        
		task.defer(function()
			self:updateShadows()
		end)
	end

	function Session:applySuggestion(rawSuggestion: any)
		if type(rawSuggestion) ~= "string" then
			return false
		end
		local suggestion: string = rawSuggestion

		local chip = if type(self.focusedChip) == "function" then self:focusedChip() else self.activeChip
		if chip and typeof(chip.box) == "Instance" and chip.box:IsA("TextBox") then
            
            chip.box.CursorPosition = #suggestion + 1
            chip.box.Text = suggestion

			local chips = self.channelChips[chip.channel] or {}
            if chip.index < #chips then
				self:focusChip(chip.channel, chip.index + 1)
			else
                self:hideSuggestions()
                
                 chip.box.CursorPosition = #suggestion + 1
                 chip.box:CaptureFocus()
                
			end
			return true
		end

		local channel = self.activeChannel
		local input = self:activeInput()
		if typeof(input) ~= "Instance" or not input:IsA("TextBox") then
			return false
		end

        local newText = suggestion
        
		local schema = type(self.argSchemas) == "table" and self.argSchemas[string.lower(suggestion)]
		local hasArguments = type(schema) == "table" and #schema > 0 and not string.find(suggestion, " ", 1, true)

		if hasArguments then
			self:enterStructured(channel, self:commandContext(newText))

			return true
		end

		input.Text = newText
		input:CaptureFocus()
		input.CursorPosition = #newText + 1

		task.defer(function()
			if typeof(input) == "Instance" and input:IsA("TextBox") and input:IsFocused() then
                input.CursorPosition = #newText + 1
                input.Text = newText
			end
		end)

		return true
	end

	function Session:acceptSuggestion()
		local input = self:activeInput()
		if typeof(input) ~= "Instance" or not input:IsA("TextBox") then
			return false
        end
        
		if self.acceptGuard then
			return true
        end
        
		self.acceptGuard = true
		task.defer(function()
			self.acceptGuard = false
		end)

		local suggestion = self.currentSuggestions[self.selectedSuggestion or 1]
		if not suggestion then
			suggestion = (self:resolveSuggestions(input.Text))[1]
        end
        
		if not suggestion then
			return false
		end

		return self:applySuggestion(suggestion)
	end
end

return Suggestions
