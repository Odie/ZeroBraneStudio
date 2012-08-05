local indexer = require "src.editor.functionIndexer"
local pretty = require "pl.pretty"
local path = require "pl.path"

local quicknav = {}

function quicknav.show(event)
	local defaultWidth = 400
	local defaultHeight = 500

	-- Which entry is the user trying to navigate to via the arrow keys?
	local keyboardCursor = 1



	-- Create the dialog that will hold everything
	local dialog = wx.wxDialog(wx.NULL, 
		-1,
    	"Quicknav",
    	wx.wxDefaultPosition,
    	wx.wxSize(defaultWidth, defaultHeight),
    	wx.wxCAPTION + wx.wxCLOSE_BOX + wx.wxRESIZE_BORDER)

  	-- Create the search box the users will use to enter search terms
    local searchBox = wx.wxTextCtrl(dialog,
		-1,
    	"",             -- default content
    	wx.wxDefaultPosition,
    	wx.wxDefaultSize)

  	local searchBoxSizer = wx.wxBoxSizer(wx.wxHORIZONTAL)
  	searchBoxSizer:Add(searchBox, 1)

	-- Create the scroll window that will hold the search results
	local scrollWindow = wx.wxScrolledWindow(dialog,
    	-1,
    	wx.wxDefaultPosition,
    	wx.wxSize(100, 500),
    	wx.wxVSCROLL)
  	scrollWindow:SetMinSize(wx.wxSize(-1, 100))
  	scrollWindow:SetSizer(wx.wxBoxSizer(wx.wxVERTICAL))
  
	local scrollWindowSizer = wx.wxBoxSizer(wx.wxHORIZONTAL)
	scrollWindowSizer:Add(scrollWindow, 1, wx.wxEXPAND)

	-- Add the scroll window to the top level sizer
	local topSizer = wx.wxBoxSizer(wx.wxVERTICAL)
	topSizer:Add(searchBoxSizer, 0, wx.wxEXPAND, 0)
	topSizer:Add(scrollWindowSizer, 1, wx.wxEXPAND+wx.wxALL, 5)
	dialog:SetSizer(topSizer)

	local lineHeight = 0	-- Irrelevant initial value

	--scrollWindow:SetScrollbars(0, 40, 0, 20)
  
	scrollWindow:Connect(wx.wxEVT_PAINT,
	function (event)
		local target = scrollWindow
    	local dc = wx.wxPaintDC(target)
    	target:PrepareDC(dc)

		local result = quicknav.result
		if not result then 
			return 
		end
		
		-- Set a new clipping region to manually set spacing with other elements
		local x, y, dcWidth, dcHeight = dc:GetClippingBox()
		--dc:SetClippingRegion(x+5, y+5, w-10, h-10)

		lineHeight = dc:GetCharHeight() + dc:GetCharHeight() * 0.25
    	local lineCount = #result
    	
    	for i = 1, lineCount do
    		local currentLineHeight = (i-1) * lineHeight
    		-- Indicate the item that the user has selected
    		if i == keyboardCursor then
    			dc:DrawRectangle(0, currentLineHeight, dcWidth, lineHeight)
    		end

      		dc:DrawText(result[i][1], 10, currentLineHeight + 2)
      		-- +2 to align with selection rectangle better
    	end

		--paintTarget:SetVirtualSize(-1, lineHeight * lineCount + 100)
		--target:SetScrollRate(5, 20)
		target:SetScrollbars(0, lineHeight, 0, lineCount)
	end)

	searchBox:Connect(wx.wxEVT_COMMAND_TEXT_UPDATED,
	function (event)
		-- Create the index right now if it's not available
		if not quicknav.index then
			local startTime = os.clock()
			quicknav.index = indexer.generateIndex(ide.config.path.projectdir)
			local elapsed = os.clock() - startTime
		end

		-- Perform the search		
		local target = searchBox:GetLineText(0)
		local handle = indexer.startSearch(quicknav.index)
		quicknav.result = indexer.searchIndex(handle, target)

		-- Repaint scrollWindow to show the updated result
		scrollWindow:Refresh()

		keyboardCursor = 1
	end)

	searchBox:Connect(wx.wxEVT_KEY_DOWN,
    function (event)
		local keycode = event:GetKeyCode()
		if keycode == wx.WXK_UP then
			-- Pressing the down key will move the cursor down one entry
			-- Keep the cursor within valid range

			keyboardCursor = keyboardCursor - 1
			if keyboardCursor < 1 then
				keyboardCursor = 1
			end

			scrollWindow:SetScrollbars(0, lineHeight, 0, #quicknav.result, 0, keyboardCursor)

			-- Update the results window to show our selection
			scrollWindow:Refresh()

		elseif keycode == wx.WXK_DOWN then
			-- Pressing the down key will move the cursor down one entry
			-- Keep the cursor within valid range

			if quicknav.result then
				keyboardCursor = keyboardCursor + 1
				if keyboardCursor >= #quicknav.result then
					keyboardCursor = #quicknav.result
				end
			end
			
			scrollWindow:Refresh()

		elseif keycode == wx.WXK_RETURN then
			-- Pressing the enter key should activate the selected entry
			DisplayOutput("Got return key\n")
			if quicknav.result then
				DisplayOutput("Proceeding to selection\n")

				-- Grab the item the user selected
				local selection = quicknav.result[keyboardCursor]
				local selectedFilename;

				-- Try to "goto" the item as appropriate
				if indexer.tableIsFileDataTable(selection) then
					-- If it's a file, just open it up
					selectedFilename = path.join(indexer.getSourceRoot(quicknav.index), selection[indexer.eFilePath])
					LoadFile(selectedFilename)
					dialog:EndModal(0)
				else
					-- If it's a function, open it up and jump to the function
					selectedFilename = path.join(indexer.getSourceRoot(quicknav.index), selection[indexer.eFunctionPath])
					LoadFile(selectedFilename)
					DisplayOutput("going to line ", selection[indexer.eFunctionLineno], "\n")
					GetEditor():GotoLine(selection[indexer.eFunctionLineno]-1)
					dialog:EndModal(0)
				end
			end

      	elseif keycode == wx.WXK_TAB then
      		-- ignore
      		-- We want to hang on to keyboard focus, regardless of
      		-- what else might be in the dialog
      	else
        	event:Skip()
      	end
    end)


  dialog:Center()
  dialog:ShowModal()
end

return quicknav
