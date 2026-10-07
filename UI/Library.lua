local ADDON, ns = ...

local LibDD = LibStub("LibUIDropDownMenu-4.0")

--[[
Pack and board selectors. A pack is the shareable unit ("BT guild"); a board is
one boss within it.
]]

--[[
Dialogs are registered statically at load and read current state inside OnShow
and OnAccept, the way every addon in this folder does it. The edit box comes
from ns.PopupEditBox: reaching for self.editBox is what broke rename, on both
clients.
]]

local function makeDialog(prompt, getInitial, apply)
	return {
		text = prompt,
		button1 = ACCEPT or "Okay",
		button2 = CANCEL or "Cancel",
		hasEditBox = true,
		maxLetters = 48,
		timeout = 0,
		whileDead = true,
		hideOnEscape = true,
		OnShow = function(self)
			local editBox = ns.PopupEditBox(self)
			editBox:SetText(getInitial() or "")
			editBox:HighlightText()
			editBox:SetFocus()
		end,
		OnAccept = function(self)
			apply(ns.PopupEditBox(self):GetText())
		end,
		EditBoxOnEnterPressed = function(self)
			apply(self:GetText())
			self:GetParent():Hide()
		end,
		EditBoxOnEscapePressed = function(self)
			self:GetParent():Hide()
		end,
	}
end

StaticPopupDialogs["RAIDMAP_NEW_PACK"] = makeDialog(
	"Name the new pack:",
	function() return "" end,
	function(name)
		if name == "" then return end
		local pack = ns.Pack:Add(ns.Pack:New(name))
		ns.Pack:Select(pack.uid)
	end
)

StaticPopupDialogs["RAIDMAP_RENAME_PACK"] = makeDialog(
	"Rename pack:",
	function()
		local pack = ns:CurrentPack()
		return pack and pack.title
	end,
	function(name)
		ns.Pack:Rename(ns:CurrentPack(), name)
	end
)

StaticPopupDialogs["RAIDMAP_RENAME_BOARD"] = makeDialog(
	"Rename board:",
	function()
		local board = ns:CurrentBoard()
		return board and board.name
	end,
	function(name)
		local pack = ns:CurrentPack()
		ns.Pack:RenameBoard(pack, pack.currentBoard, name)
	end
)

--[[
Changing board is the same kind of act as changing slide, so it broadcasts the
same way: a lead moving to the next boss carries the raid with them instead of
leaving twenty-four people staring at the boss that just died. Presentation mode
routes through here too, where CanPublish is false and it is a purely local view
change.

There is no fromRemote counterpart to ns.SwitchSlide's here. A received focus
calls ns.Pack:SelectBoard directly, because Comm sits below UI and must not
reach up into it.
]]
function ns.SelectBoard(index)
	local pack = ns:CurrentPack()
	local board = pack and pack.boards[index]
	if not board then return end

	ns.Pack:SelectBoard(pack, index)

	if ns.Comm and ns.Comm:CanPublish() then
		ns.Comm:PublishFocus(board.currentSlide or 1, board)
	end
end

local function BuildPackMenu(self, level, menuList)
	level = level or 1

	local current = ns:CurrentPack()

	if level == 2 and menuList == "history" then
		local pack = ns:CurrentPack()
		local entries = pack and pack.history or {}

		if #entries == 0 then
			local info = LibDD:UIDropDownMenu_CreateInfo()
			info.text, info.notCheckable, info.disabled = "No published revisions yet", true, true
			LibDD:UIDropDownMenu_AddButton(info, level)
			return
		end

		for i, entry in ipairs(entries) do
			local info = LibDD:UIDropDownMenu_CreateInfo()
			local ago = math.max(0, time() - (entry.at or 0))
			info.text = ("rev %d -- %s, %s ago")
				:format(entry.rev or 0, entry.by or "?", SecondsToTime(ago) or "?")
			info.notCheckable = true
			info.func = function()
				ns.Pack:RestoreRevision(ns:CurrentPack(), i)
				LibDD:CloseDropDownMenus()
			end
			LibDD:UIDropDownMenu_AddButton(info, level)
		end
		return
	end

	if level ~= 1 then return end

	local info = LibDD:UIDropDownMenu_CreateInfo()
	info.text, info.isTitle, info.notCheckable = "Packs", true, true
	LibDD:UIDropDownMenu_AddButton(info, level)

	for _, pack in ipairs(ns.Pack:List()) do
		info = LibDD:UIDropDownMenu_CreateInfo()
		info.text = ("%s |cff888888(%s, rev %d)|r")
			:format(pack.title, pack.author or "?", pack.revision or 0)
		info.checked = (pack.uid == (current and current.uid))
		info.func = function()
			ns.Pack:Select(pack.uid)
			LibDD:CloseDropDownMenus()
		end
		LibDD:UIDropDownMenu_AddButton(info, level)
	end

	info = LibDD:UIDropDownMenu_CreateInfo()
	info.text, info.isTitle, info.notCheckable = " ", true, true
	LibDD:UIDropDownMenu_AddButton(info, level)

	local actions = {
		{
			text = "New pack",
			func = function() StaticPopup_Show("RAIDMAP_NEW_PACK") end,
		},
		{
			text = "Rename pack",
			func = function() StaticPopup_Show("RAIDMAP_RENAME_PACK") end,
		},
		{
			text = "Duplicate pack",
			func = function()
				local copy = ns.Pack:Duplicate(ns:CurrentPack())
				if copy then ns.Pack:Select(copy.uid) end
			end,
		},
	}

	-- Forking only means something for a pack you did not author.
	if current and current.author ~= ns.Pack.AuthorName() then
		actions[#actions + 1] = {
			text = "Fork as mine",
			func = function()
				local copy = ns.Pack:Fork(ns:CurrentPack())
				if copy then
					ns.Pack:Select(copy.uid)
					ns:Print("Forked \"%s\". Updates from %s will no longer reach it.",
						copy.title, current.author or "?")
				end
			end,
		}
	end

	actions[#actions + 1] = {
		text = "Export string",
		func = function() ns.ShowExport(ns:CurrentPack()) end,
	}

	actions[#actions + 1] = {
		text = "Import string",
		func = function() ns.ShowImport() end,
	}

	actions[#actions + 1] = {
		text = "Link in chat",
		func = function() ns.LinkPackInChat(ns:CurrentPack()) end,
	}

	-- The lock is the author's to set; it reaches everyone else on the next
	-- publish. Offered to anyone, an assistant could simply untick it.
	if current and current.author == ns.Pack.AuthorName() then
		actions[#actions + 1] = {
			text = current.locked and "Unlock (allow others to publish)" or "Lock (only I may publish)",
			func = function()
				local pack = ns:CurrentPack()
				pack.locked = not pack.locked or nil
				pack.modified = true
				ns.Events:Fire("PACK_CHANGED")
			end,
		}
	end

	actions[#actions + 1] = {
		text = "|cffff6666Delete pack|r",
		func = function()
			if not ns.Pack:Delete(ns:CurrentPack().uid) then
				ns:Print("That is your only pack.")
			end
		end,
	}

	for _, action in ipairs(actions) do
		info = LibDD:UIDropDownMenu_CreateInfo()
		info.text = action.text
		info.notCheckable = true
		info.func = function()
			action.func()
			LibDD:CloseDropDownMenus()
		end
		LibDD:UIDropDownMenu_AddButton(info, level)
	end

	-- Rollback lives behind a submenu: rarely needed, bad to hit by accident.
	info = LibDD:UIDropDownMenu_CreateInfo()
	info.text = "Revision history"
	info.notCheckable = true
	info.hasArrow = true
	info.menuList = "history"
	LibDD:UIDropDownMenu_AddButton(info, level)
end

local function BuildBoardMenu(self, level)
	level = level or 1
	if level ~= 1 then return end

	local pack = ns:CurrentPack()
	if not pack then return end

	local info = LibDD:UIDropDownMenu_CreateInfo()
	info.text, info.isTitle, info.notCheckable = "Boards", true, true
	LibDD:UIDropDownMenu_AddButton(info, level)

	for i, board in ipairs(pack.boards) do
		info = LibDD:UIDropDownMenu_CreateInfo()
		info.text = board.name
		info.checked = (i == pack.currentBoard)
		info.func = function()
			ns.SelectBoard(i)
			LibDD:CloseDropDownMenus()
		end
		LibDD:UIDropDownMenu_AddButton(info, level)
	end

	info = LibDD:UIDropDownMenu_CreateInfo()
	info.text, info.isTitle, info.notCheckable = " ", true, true
	LibDD:UIDropDownMenu_AddButton(info, level)

	local actions = {
		{
			text = "New board",
			func = function()
				local index = ns.Pack:AddBoard(pack)
				if index then ns.Pack:SelectBoard(pack, index) end
			end,
		},
		{
			text = "Duplicate board",
			func = function()
				local index = ns.Pack:AddBoard(pack, pack.currentBoard)
				if index then ns.Pack:SelectBoard(pack, index) end
			end,
		},
		{
			text = "Rename board",
			func = function() StaticPopup_Show("RAIDMAP_RENAME_BOARD") end,
		},
		{
			text = "|cffff6666Delete board|r",
			func = function()
				if not ns.Pack:RemoveBoard(pack, pack.currentBoard) then
					ns:Print("That is the only board in this pack.")
				end
			end,
		},
	}

	for _, action in ipairs(actions) do
		info = LibDD:UIDropDownMenu_CreateInfo()
		info.text = action.text
		info.notCheckable = true
		info.func = function()
			action.func()
			LibDD:CloseDropDownMenus()
		end
		LibDD:UIDropDownMenu_AddButton(info, level)
	end
end

function ns.CreateLibraryDropdowns(parent)
	local packDD = LibDD:Create_UIDropDownMenu("RaidMapPackDropDown", parent)
	LibDD:UIDropDownMenu_SetWidth(packDD, 120)
	LibDD:UIDropDownMenu_Initialize(packDD, BuildPackMenu)

	local boardDD = LibDD:Create_UIDropDownMenu("RaidMapBoardDropDown", parent)
	LibDD:UIDropDownMenu_SetWidth(boardDD, 120)
	LibDD:UIDropDownMenu_Initialize(boardDD, BuildBoardMenu)

	local function Refresh()
		local pack = ns:CurrentPack()
		local board = ns:CurrentBoard()

		local title = pack and pack.title or "?"
		if pack and pack.locked then title = "|cffffd100*|r " .. title end
		if pack and pack.modified then title = title .. " |cffff8800~|r" end

		LibDD:UIDropDownMenu_SetText(packDD, title)
		LibDD:UIDropDownMenu_SetText(boardDD, board and board.name or "?")
	end

	ns.Events:On("PACK_CHANGED", Refresh)

	return packDD, boardDD, Refresh
end
