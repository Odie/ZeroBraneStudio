-- This file provides the machinary needed to implement fast
-- project navigation by filename or function name.

local dir = require "pl.dir"
local path = require "pl.path"
local utils = require "pl.utils"
local pretty = require "pl.pretty"

local M = {}
local LA, LI, T
local FAST = true

-- Intitizlize module variables
local function init()
  if LA then return end

  require "metalua"
  require "metalua.runtime"
  LA = require "luainspect.ast"
  LI = require "luainspect.init"
  T = require "luainspect.types"

  if FAST then
    LI.eval_comments = function () end
    LI.infer_values = function () end
  end
end


-- FunctionDataTable
--	Holds function name, file path, and line number where the function was found
local eFunctionName, eFunctionLineno, eFunctionPath = 1, 3, 2
M.eFunctionName, M.eFunctionLineno, M.eFunctionPath = eFunctionName, eFunctionLineno, eFunctionPath
local function appendToFunctionDataTable(table, data, lineno, path)
	table[#table+1] = {data, path, lineno}
end
function M.tableIsFunctionData(table)
	if type(table[eFunctionLineno]) == "number" then
		return true
	else
		return false
	end
end

-- FileDataTable
--	Holds filename, modification date, and a table of functions found in the file
local eFilePath, eFileModDate, eFileFunctionTable = 1, 2, 3
M.eFilePath, M.eFileModDate, M.eFileFunctionTable = eFilePath, eFileModDate, eFileFunctionTable
local function appendToFileDataTable(table, filepath, modDate, functionData)
	table[filepath] = {filepath, modDate, functionData}
end
function M.tableIsFileDataTable(table)
	if type(table[eFileFunctionTable]) == "table" then
		return true
	else
		return false
	end
end

-----------------------------------------------------------------------------------------
--			Index Generation
-----------------------------------------------------------------------------------------

function M.getSourceRoot(index)
	-- We store the source root in a strange ".sourceRoot" field because we're
	-- not storing any filenames starting with "." in the index.
	-- By storing the setting in ".sourceRoot", we avoid any potential name
	-- conflicts with actual filenames

	return index[".sourceRoot"]
end

-- Given the root of a source tree, recursively scan the directory and generate a table
-- of defined functions.  If given an old index, this function will skip any files that
-- has not been changed since last index generation.
--
-- Params:
--	sourceRoot
--		String representing the root of the source tree
--	oldIndex
--		[Optional]
--		Given an old(er) index, the function will skip over files that have not been
--		changed.
-- Returns:
--	index
--		Table with elements of the following format:
--			{filepath, file modification date, function data}
--		where "function data" is a table of the following format:
--			{function name, definition line, }
function M.generateIndex(sourceRoot, oldIndex)
	local index = {}
	index[".sourceRoot"] = sourceRoot
	
	-- Params sanity check
	if not path.isdir(sourceRoot) then
		return nil
	end

	-- Grab a list of all files starting at the sourceRoot
	local fileList = dir.getallfiles (sourceRoot, "*.lua")
	
	-- Generate an index for each file in the list
	for i, filepath in ipairs(fileList) do
		local relPath = path.relpath(filepath, sourceRoot)

		if M.debugInfo then
			print("Processing: " .. filepath)
		end
		
		-- Grab the last know file mod date if it's available
		local lastModDate = 0
		if oldIndex then
			local fileData = oldIndex[relPath]
			if fileData then
				lastModDate = fileData[eFileModDate]
			end
		end

		-- Process the file if it looks like it's been updated
		if lastModDate < path.getmtime(filepath) then
			_, entryResult, err = M.extractRequiresAndFunctions(filepath, sourceRoot)
		else
			entryResult = oldIndex[relPath][eFileFunctionTable]
		end
		
		if M.debugInfo then
			if entryResult then
				print("Got: " .. #entryResult .. " entries")
			else
				print("An error ocurred: " .. err)
			end
		end 

		appendToFileDataTable(index, 
			relPath, 
			path.getmtime(filepath), 
			entryResult)
	end
	
	return index
end

-- Given a file, this function walks through the specified file and pulls out
-- function definition info and required file info.
--
-- Returns:
-- 		requiredFiles	
--			table of results with elements formatted {requiredFilename, linenum, filePath}
--			or nil on error
--		definedFunctions
--			table of results with elements formatted {functionName, linenum, filePath}
--			or nil on error 
--		err
--			error message if the file contains a syntax error 	
--		linenum
--			line number where the error occurred
--		colnum
--			???
function M.extractRequiresAndFunctions(filename, basepath)
	if not filename then
		return
	end

	if not path.isfile(filename) then
		return nil, nil, "File is actually a directory"
	end
  
	init()

	local file = assert(io.open(filename, "r"))
	local contents = file:read("*all")
	file:close()

	local ast, err, linenum, colnum = LA.ast_from_string(contents, filename)
	if err then return nil, nil, err, linenum, colnum end

	if FAST then
    	LI.inspect(ast, nil, src)
    	LA.ensure_parents_marked(ast)
  	else
    	local tokenlist = LA.ast_to_tokenlist(ast, src)
   		LI.inspect(ast, tokenlist, src)
    	LI.mark_related_keywords(ast, tokenlist, src)
  	end

  	return M.extractRequiresAndFunctionsFromAst(ast, basepath)
end

function M.extractRequiresAndFunctionsFromAst(top_ast, basepath)
	local requiredFiles = {}
	local definedFunctions = {}
	
	LA.walk(top_ast, function(node)
		-- Skip nodes without useful values
		local value = node[1]
		if value == nil then
			return
		end

    	local line = node.lineinfo and node.lineinfo.first[1] or 0
    	local filepath = node.lineinfo and node.lineinfo.first[4] or '?'
		
		if node.tag == "Id" and node.resolvedname == "require" then
			-- Find all the required modules in this file
			local parent = node.parent
			local stringNode = parent[2]
			local requiredFilename = nil
			if stringNode.tag == "String" then
				requiredFilename = stringNode[1]
				appendToFunctionDataTable(
					requiredFiles, 
					requiredFilename, 
					line, 
					path.relpath(filepath, basepath))
			end
		elseif node.tag == "Function" then
			-- Find all the functions defined in this file
			
			-- case 1: "function foo(bar)" => func.tag == 'Set'
			-- case 2: "local function foo(bar)" => func.tag == 'Localrec'
			-- case 3: "local _, foo = 1, function(bar)" => func.tag == 'Local'
			-- case 4: "print(function(bar) end)" => func.tag == nil
			-- case 5: "function M.foo(bar)" 
			
			local parent = node.parent.parent
			if parent.tag == "Local" then		-- skip case 3.  There is no function identifier
				return
			end
			
			local tempNode = parent[1][1]
			
			-- Try to retrieve the function name
			local funcname = nil
			if tempNode ~= nil then
				if tempNode.tag == "Id" then
					funcname = tempNode[1]		-- This handles case 1 and 2
				elseif tempNode.tag == "Index" then
					funcname = tempNode[2][1]	-- This handles case 5
				end
			end
			
			if funcname then
				appendToFunctionDataTable(definedFunctions, funcname, line, path.relpath(filepath, basepath))
			end
		end
	end)
	
	return requiredFiles, definedFunctions
end

-----------------------------------------------------------------------------------------
--			Index Serialization
-----------------------------------------------------------------------------------------
function M.writeToDisk(index, filepath)
	if not filepath or path.isdir(filepath) then
		return false
	end

	local file = assert(io.open(filepath, "w"))
	if not file then 
		return false
	end

	local indexString = pretty.write(index)
	file:write(indexString)
	file:close()
	return true
end

function M.readFromDisk(filepath)
	if not filepath or path.isdir(filepath) then
		return nil
	end

	local file = assert(io.open(filepath, "r"))
	if not file then 
		return nil
	end

	local indexString = file:read("*all")
	local index = pretty.read(indexString)
	return index
end

-----------------------------------------------------------------------------------------
--			Index Searching
-----------------------------------------------------------------------------------------
function M.stringScore(candidate, abbreviation, offset)
	local offset = offset or 0
	local abbrLen = abbreviation:len()
	
	-- Return dummy value if we don't have something to search against...
	-- Everything matches equally at the moment...
	-- Eventually, every scoring run is going to resolve to this seed score.
	if abbrLen == 0 then return 0.9 end
	
	-- If what we're searching for is longer than the candidate...
	-- We're definitely *not* looking for this candidate
	-- Return worst possible score 
	if abbrLen > candidate:len() then return 0 end

	-- Try matching as much of the string as possible
	-- Start with the whole string, then try with fewer characters
	for i = abbrLen, 1, -1 do
		local sub_abbreviation = abbreviation:sub(1,i)
		local index = candidate:find(sub_abbreviation)
		
		-- If we weren't able to match that much of the string, 
		-- continue trying with fewer characters
		if index and index + abbrLen <= candidate:len() + offset then
			-- If we are able to match part of the string,
			-- let's see if we can match another part
			local next_string       = candidate:sub(index+sub_abbreviation:len())
			local next_abbreviation = nil
			
			if i+1 > abbrLen then
				next_abbreviation = ''
			else
				next_abbreviation = abbreviation:sub(i+1)
			end

			local remaining_score   = M.stringScore(next_string, next_abbreviation, offset+index)

			if remaining_score > 0 then 
				-- Fewer character matches have a higher score
				-- This favors spreading matching characters throughout the candidate string
				local score = candidate:len() - next_string:len();
				
				if index ~= 1 then 
					local j = 0
					
					local c = candidate:byte(index)
			     	if c == 32 or c == 9 then
			       		for j=index-1, j >= 1, -1 do
			         		c = candidate:byte(j)
			         		score = score - (c == 32 or c == 9) and 1 or 0.15
			       		end
					else
			       		score = score - index
			     	end
			   end

			   score = score + remaining_score * next_string:len()
			   score = score / candidate:len()
			   return score
			end
		end
	end
	return 0
end

-- Returns a flatten index we can use to search through both filenames and function names
function M.startSearch(index)
	local flatIndex = {}
	for filename, fileData in pairs(index) do
		if filename ~= ".sourceRoot" then
			flatIndex[#flatIndex+1] = fileData
			
			if fileData[eFileFunctionTable] then

				for _, functionData in ipairs(fileData[eFileFunctionTable]) do
					flatIndex[#flatIndex+1] = functionData
				end
			end
		end
	end
	return flatIndex
end

-- Given a flat list of items to search through and the target string to search for,
-- return a flat list of items in their best match order.
function M.searchIndex(flatIndex, searchString)
	local resultIndex = {};

	-- Look through every entry in the flat index and assign it a score
	for _, indexEntry in ipairs(flatIndex) do

		-- We're assuming the first item in the indexEntry is always a string to be
		-- matched against.  See FileDataTable and FunctionDataTable formats.
		local score = M.stringScore(indexEntry[1], searchString)
		if score ~= 0 then
			indexEntry.score = score
			resultIndex[#resultIndex+1] = indexEntry
		end
	end
	
	table.sort(resultIndex, function(a, b) return a.score > b.score end)

	return resultIndex
end

return M