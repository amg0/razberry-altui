-- // This program is free software: you can redistribute it and/or modify
-- // it under the condition that it is for private or home useage and 
-- // this whole comment is reproduced in the source code file.
-- // Commercial utilisation is not authorized without the appropriate
-- // written agreement from amg0 / alexis . mermet @ gmail . com
-- // This program is distributed in the hope that it will be useful,
-- // but WITHOUT ANY WARRANTY; without even the implied warranty of
-- // MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE . 
local MSG_CLASS = "RAZB"
local RAZB_SERVICE = "urn:upnp-org:serviceId:razb1"
local devicetype = "urn:schemas-upnp-org:device:razb:1"
local DEBUG_MODE = false	-- controlled by UPNP action
local WFLOW_MODE = false	-- controlled by UPNP action
local version = "v0.01"
local UI7_JSON_FILE= "D_RAZB.json"
local json = require("dkjson")

local mime = require("mime")
local socket = require("socket")
local http = require("socket.http")
local https = require ("ssl.https")
local ltn12 = require("ltn12")
local modurl = require "socket.url"
local this_device
local this_ipaddr

------------------------------------------------
-- Debug --
------------------------------------------------
local function log(text, level)
	luup.log(string.format("%s: %s", MSG_CLASS, text), (level or 50))
end

local function debug(text)
	if (DEBUG_MODE) then
		log("debug: " .. text)
	end
end

local function warning(stuff)
	log("warning: " .. stuff, 2)
end

local function error(stuff)
	log("error: " .. stuff, 1)
end

-- local function dumpString(str)
	-- for i=1,str:len() do
		-- debug(string.format("i:%d c:%d char:%s",i,str:byte(i),str:sub(i,i) ))
	-- end
-- end

function string.starts(String,Start)
   return string.sub(String,1,string.len(Start))==Start
end

local function isempty(s)
  return s == nil or s == ''
end

local function findRAZBDevice()
	for k,v in pairs(luup.devices) do
		if( v.device_type == devicetype ) then
			return k
		end
	end
	return -1
end

------------------------------------------------
-- Device Properties Utils
------------------------------------------------

local function getSetVariable(serviceId, name, deviceId, default)
	local curValue = luup.variable_get(serviceId, name, deviceId)
	if (curValue == nil) then
		curValue = default
		luup.variable_set(serviceId, name, curValue, deviceId)
	end
	return curValue
end

local function getSetVariableIfEmpty(serviceId, name, deviceId, default)
	local curValue = luup.variable_get(serviceId, name, deviceId)
	if (curValue == nil) or (curValue:trim() == "") then
		curValue = default
		luup.variable_set(serviceId, name, curValue, deviceId)
	end
	return curValue
end

local function setVariableIfChanged(serviceId, name, value, deviceId)
	debug(string.format("setVariableIfChanged(%s,%s,%s,%s)",serviceId, name, value, deviceId))
	local curValue = luup.variable_get(serviceId, name, deviceId) or ""
	value = value or ""
	if (tostring(curValue)~=tostring(value)) then
		luup.variable_set(serviceId, name, value, deviceId)
	end
end

local function setAttrIfChanged(name, value, deviceId)
	debug(string.format("setAttrIfChanged(%s,%s,%s)",name, value, deviceId))
	local curValue = luup.attr_get(name, deviceId)
	if ((value ~= curValue) or (curValue == nil)) then
		luup.attr_set(name, value, deviceId)
		return true
	end
	return value
end


local function setDebugMode(lul_device,newDebugMode)
	lul_device = tonumber(lul_device)
	newDebugMode = tonumber(newDebugMode) or 0
	log(string.format("setDebugMode(%d,%d)",lul_device,newDebugMode))
	luup.variable_set(RAZB_SERVICE, "Debug", newDebugMode, lul_device)
	if (newDebugMode==1) then
		DEBUG_MODE=true
	else
		DEBUG_MODE=false
	end
end

local function getIP()
	local mySocket = socket.udp ()  
	mySocket:setpeername ("42.42.42.42", "424242")  -- arbitrary IP/PORT  
	local ip = mySocket:getsockname ()  
	mySocket: close()  
	return ip or "127.0.0.1"
end

------------------------------------------------
-- Check UI7
------------------------------------------------
local function checkVersion(lul_device)
	local ui7Check = luup.variable_get(RAZB_SERVICE, "UI7Check", lul_device) or ""
	if ui7Check == "" then
		luup.variable_set(RAZB_SERVICE, "UI7Check", "false", lul_device)
		ui7Check = "false"
	end
	if( luup.version_branch == 1 and luup.version_major == 7 and ui7Check == "false") then
		luup.variable_set(RAZB_SERVICE, "UI7Check", "true", lul_device)
		luup.attr_set("device_json", UI7_JSON_FILE, lul_device)
		luup.reload()
	end
end

------------------------------------------------
-- Tasks
------------------------------------------------
local taskHandle = -1
local TASK_ERROR = 2
local TASK_ERROR_PERM = -2
local TASK_SUCCESS = 4
local TASK_BUSY = 1

--
-- Has to be "non-local" in order for MiOS to call it :(
--
local function task(text, mode)
	if (mode == TASK_ERROR_PERM)
	then
		error(text)
	elseif (mode ~= TASK_SUCCESS)
	then
		warning(text)
	else
		log(text)
	end
	if (mode == TASK_ERROR_PERM)
	then
		taskHandle = luup.task(text, TASK_ERROR, MSG_CLASS, taskHandle)
	else
		taskHandle = luup.task(text, mode, MSG_CLASS, taskHandle)

		-- Clear the previous error, since they're all transient
		if (mode ~= TASK_SUCCESS)
		then
			luup.call_delay("clearTask", 15, "", false)
		end
	end
end

function clearTask()
	task("Clearing...", TASK_SUCCESS)
end

function UserMessage(text, mode)
	mode = (mode or TASK_ERROR)
	task(text,mode)
end

------------------------------------------------
-- LUA Utils
------------------------------------------------
local function Split(str, delim, maxNb)
    -- Eliminate bad cases...
    if string.find(str, delim) == nil then
        return { str }
    end
    if maxNb == nil or maxNb < 1 then
        maxNb = 0    -- No limit
    end
    local result = {}
    local pat = "(.-)" .. delim .. "()"
    local nb = 0
    local lastPos
    for part, pos in string.gmatch(str, pat) do
        nb = nb + 1
        result[nb] = part
        lastPos = pos
        if nb == maxNb then break end
    end
    -- Handle the last field
    if nb ~= maxNb then
        result[nb + 1] = string.sub(str, lastPos)
    end
    return result
end

local function Trim(str)
  return str:match "^%s*(.-)%s*$"
end

------------------------------------------------
-- VERA Device Utils
------------------------------------------------

function tablelength(T)
  local count = 0
  if (T~=nil) then
	for _ in pairs(T) do count = count + 1 end
  end
  return count
end

function inTable(tbl, item)
    for key, value in pairs(tbl) do
        if value == item then return key end
    end
    return false
end

local function getParent(lul_device)
	return luup.devices[lul_device].device_num_parent
end

local function getAltID(lul_device)
	return luup.devices[lul_device].id
end


-----------------------------------
-- from a altid, find a child device
-- returns 2 values
-- a) the index === the device ID
-- b) the device itself luup.devices[id]
-----------------------------------
local function findChild( lul_parent, altid )
	debug(string.format("findChild(%s,%s)",lul_parent,altid))
	for k,v in pairs(luup.devices) do
		if( getParent(k)==lul_parent) then
			if( v.id==altid) then
				return k,v
			end
		end
	end
	return nil,nil
end


------------------------------------------------------------------------------------------------
-- Http handlers : Communication FROM RAZB
-- http://192.168.1.5:3480/data_request?id=lr_RAZB_Handler&command=xxx
-- recommended settings in RAZB: PATH = /data_request?id=lr_RAZB_Handler&mac=$M&deviceID=114
------------------------------------------------------------------------------------------------
function switch( command, actiontable)
	-- check if it is in the table, otherwise call default
	if ( actiontable[command]~=nil ) then
		return actiontable[command]
	end
	log("RAZB_Handler:Unknown command received:"..command.." was called. Default function")
	return actiontable["default"]
end

function myRAZB_Handler(lul_request, lul_parameters, lul_outputformat)
	debug('myRAZB_Handler: request is: '..tostring(lul_request))
	debug('myRAZB_Handler: parameters is: '..json.encode(lul_parameters))
	-- debug('RAZB_Handler: outputformat is: '..json.encode(lul_outputformat))
	local lul_html = "";	-- empty return by default
	local mime_type = "";
	-- debug("hostname="..hostname)
	if (hostname=="") then
		hostname = this_ipaddr
		debug("now hostname="..hostname)
	end
	
	-- find a parameter called "command"
	if ( lul_parameters["command"] ~= nil ) then
		command =lul_parameters["command"]
	else
	    debug("RAZB_Handler:no command specified, taking default")
		command ="default"
	end
	
	local deviceID = this_device or tonumber(lul_parameters["DeviceNum"] or findRAZBDevice() )
	
	-- switch table
	local action = {
		["default"] = 
			function(params)	
				return "not successful", "text/plain"
			end
	}
	-- actual call
	lul_html , mime_type = switch(command,action)(lul_parameters)
	if (command ~= "home") and (command ~= "oscommand") then
		debug(string.format("lul_html:%s",lul_html or ""))
	end
	return (lul_html or "") , mime_type
end

------------------------------------------------
-- Get Status
------------------------------------------------
local function getAuthCookie(lul_device,user,password)
	debug(string.format("getAuthCookie (%s,%s)",user or '',password or ''))
	local sessioncookie = ""
	local url = "http://192.168.1.19:8083/ZAutomation/api/v1/login"
	debug(string.format("getAuthCookie url:%s",url))
	local data = string.format('{"login":"%s","password":"%s"}',user,password)
	local response_body = {}
	local commonheaders = {
			["Accept"]="application/json, text/plain, */*",
			["Accept-Encoding"]="gzip, deflate",
			["Content-Type"] = "application/json;charset=UTF-8",
			["Content-Length"] = data:len(),
			["User-agent"] = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/51.0.2704.103 Safari/537.36",
			["Connection"]= "keep-alive"
		}
	local response, status, headers = http.request{
		method="POST",
		url=url,
		headers = commonheaders,
		source = ltn12.source.string(data),
		sink = ltn12.sink.table(response_body)
	}
	debug(string.format("getAuthCookie response:%s",response or ''))
	debug(string.format("getAuthCookie status:%s",status or ''))
	debug(string.format("getAuthCookie headers:%s",json.encode(headers or '')))
	if ( response==1 and status==200 ) then
		local setcookie = headers["set-cookie"]
		sessioncookie = setcookie:match "^ZWAYSession=(.-);.*;.*$"
		luup.variable_set(RAZB_SERVICE, "Session", sessioncookie, lul_device)
	end
	debug(string.format("sessioncookie=%s",sessioncookie))
	return sessioncookie
end

local function myHttp(url,method,data)
	debug(string.format("myHttp (%s,%s) (%s,%s) data:%s",method,url,user or '',password or '',data or ''))
	-- local data = "contents="..plugin
	local sessiontoken = getSetVariable(RAZB_SERVICE, "Session", lul_device, "")
	if ( sessiontoken=="" or sessiontoken==nil) then
		local user = getSetVariable(RAZB_SERVICE, "User", lul_device, "admin")
		local password = getSetVariable(RAZB_SERVICE, "Password", lul_device, "")
		sessiontoken = getAuthCookie(lul_device,user,password)
	end
	local response_body = {}
	local commonheaders = {
			["Accept"]="application/json, text/plain, */*",
			["Accept-Encoding"]="gzip, deflate",
			["Content-Type"] = "application/json;charset=UTF-8",
			["Content-Length"] = data:len(),
			["User-agent"] = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/51.0.2704.103 Safari/537.36",
			["Connection"]= "keep-alive",
			["Cookie"]= string.format("ZWAYSession=%s",sessiontoken),
		}
	debug(string.format("myHttp Request headers:%s",json.encode(commonheaders or '')))
	debug(string.format("myHttp data:%s",data))

	local response, status, headers = http.request{
		method=method,
		url=url,
		headers = commonheaders,
		source = ltn12.source.string(data),
		sink = ltn12.sink.table(response_body)
	}
	if (response==1) then
		local completestring = table.concat(response_body)
		debug(string.format("Succeed to %s to %s  result=%s",method,url,json.encode(completestring)))
		-- if (status==302) then
			-- -- redirect
		-- end
		return completestring
	else
		debug(string.format("response:%s",response or ''))
		debug(string.format("status:%s",status or ''))
		debug(string.format("headers:%s",json.encode(headers or '')))
		debug(string.format("Failed to %s to %s",method,url))
	end				
	return -1
end


------------------------------------------------
-- Get Status
------------------------------------------------
local timestamp = 0

local function getZWay(lul_device,forcedtimestamp)
	if (forcedtimestamp==nil) then
		forcedtimestamp = timestamp
	end

	local url = string.format("http://%s:8083/ZWave.zway/Data/%s",this_ipaddr,forcedtimestamp)
	local user = getSetVariable(RAZB_SERVICE, "User", lul_device, "admin")
	local password = getSetVariable(RAZB_SERVICE, "Password", lul_device, "")
	local result = myHttp(url,"POST","")
	if (result ~= -1) then
		local obj = json.decode(result)
		timestamp = obj.updateTime
		debug(string.format("Next timestamp: %s",timestamp))
	end
end

------------------------------------------------
-- STARTUP Sequence
------------------------------------------------

function startupDeferred(lul_device)
	lul_device = tonumber(lul_device)
	log("startupDeferred, called on behalf of device:"..lul_device)
	
	-- testCompress()
	local debugmode = getSetVariable(RAZB_SERVICE, "Debug", lul_device, "0")
	local oldversion = getSetVariable(RAZB_SERVICE, "Version", lul_device, version)
	local user = getSetVariable(RAZB_SERVICE, "User", lul_device, "admin")
	local password = getSetVariable(RAZB_SERVICE, "Password", lul_device, "")
	luup.variable_set(RAZB_SERVICE, "Session", "", lul_device)

	if (debugmode=="1") then
		DEBUG_MODE = true
		UserMessage("Enabling debug mode for device:"..lul_device,TASK_BUSY)
	end
	local major,minor = 0,0
	local tbl={}
	
	if (oldversion~=nil) then
		major,minor = string.match(oldversion,"v(%d+)%.(%d+)")
		major,minor = tonumber(major),tonumber(minor)
		debug ("Plugin version: "..version.." Device's Version is major:"..major.." minor:"..minor)

		newmajor,newminor = string.match(version,"v(%d+)%.(%d+)")
		newmajor,newminor = tonumber(newmajor),tonumber(newminor)
		debug ("Device's New Version is major:"..newmajor.." minor:"..newminor)
		
		-- force the default in case of upgrade
		if ( (newmajor>major) or ( (newmajor==major) and (newminor>minor) ) ) then
			log ("Version upgrade => Reseting Plugin config to default")
		end
		
		luup.variable_set(RAZB_SERVICE, "Version", version, lul_device)
	end	
	
	-- start handlers
	luup.register_handler("myRAZB_Handler","RAZB_Handler")

	-- NOTHING to start 
	if( luup.version_branch == 1 and luup.version_major == 7) then
		luup.set_failure(0,lul_device)	-- should be 0 in UI7
	else
		luup.set_failure(false,lul_device)	-- should be 0 in UI7
	end
	
	log("startup completed")
	
	-- get data
	getZWay(lul_device)
end
		
function initstatus(lul_device)
	lul_device = tonumber(lul_device)
	this_device = lul_device
	this_ipaddr = getIP()

	log("initstatus("..lul_device..") starting version: "..version)	
	checkVersion(lul_device)

	local delay = 10		-- delaying first refresh by x seconds
	debug("initstatus("..lul_device..") startup for Root device, delay:"..delay)
	
	-- almost random seed
	math.randomseed( os.time() )
	
	luup.call_delay("startupDeferred", delay, tostring(lul_device))		
end
 
-- do not delete, last line must be a CR according to MCV wiki page
