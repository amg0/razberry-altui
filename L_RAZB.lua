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
local version = "v0.03"
local UI7_JSON_FILE= "D_RAZB.json"
local json = require("dkjson")

local mime = require("mime")
local socket = require("socket")
local http = require("socket.http")
local https = require ("ssl.https")
local ltn12 = require("ltn12")
local modurl = require "socket.url"

local DATA_REFRESH_RATE = 2		-- refresh rate from zway
local timestamp = 0						-- last timestamp received
local zway_tree = {}						-- zWay data model tree ( agregates all info as we receives it )
local this_device
local this_ipaddr

-- Wiki doc
-- http://wiki.micasaverde.com/index.php/ZWave_Debugging
-- mapping zWave to D_XML
-- https://github.com/yepher/RaZBerry/blob/master/README.md
-- <DeviceClasses>
  -- <Basic key="0x01" label="Controller" />
  -- <Basic key="0x02" label="Static Controller" />
  -- <Basic key="0x03" label="Slave" />
  -- <Basic key="0x04" label="Routing Slave" />
  -- <Generic key="0x01" label="Remote Controller" command_classes="0xef,0x20">
    -- <Specific key="0x01" label="Portable Remote Controller" />
    -- <Specific key="0x02" label="Portable Scene Controller" command_classes="0x2d,0x72,0x85,0xef,0x2b" />
    -- <Specific key="0x03" label="Portable Installer Tool" command_classes="0x21,0x72,0x86,0x8f,0xef,0x21,0x60,0x70,0x72,0x84,0x85,0x86,0x8e" />
  -- </Generic>
  -- <Generic key="0x02" label="Static Controller" command_classes="0xef,0x20">
    -- <Specific key="0x01" label="Static PC Controller" />
    -- <Specific key="0x02" label="Static Scene Controller" command_classes="0x2d,0x72,0x85,0xef,0x2b" />
    -- <Specific key="0x03" label="Static Installer Tool" command_classes="0x21,0x72,0x86,0x8f,0xef,0x21,0x60,0x70,0x72,0x84,0x85,0x86,0x8e" />
  -- </Generic>
  -- <Generic key="0x03" label="AV Control Point" command_classes="0x20">
    -- <Specific key="0x04" label="Satellite Receiver" command_classes="0x72,0x86,0x94" />
    -- <Specific key="0x11" label="Satellite Receiver V2" command_classes="0x72,0x86,0x94" basic="0x94" />
    -- <Specific key="0x12" label="Doorbell" command_classes="0x30,0x72,0x85,0x86" basic="0x30"/>
  -- </Generic>
  -- <Generic key="0x04" label="Display" command_classes="0x20">
    -- <Specific key="0x01" label="Simple Display" command_classes="0x72,0x86,0x92,0x93" />
  -- </Generic>
  -- <Generic key="0x08" label="Thermostat" command_classes="0x20">
    -- <Specific key="0x01" label="Heating Thermostat" />
    -- <Specific key="0x02" label="General Thermostat" command_classes="0x40,0x43,0x72" basic="0x40" />
    -- <Specific key="0x03" label="Setback Schedule Thermostat" command_classes="0x46,0x72,0x86,0x8f,0xef,0x46,0x81,0x8f" basic="0x46" />
    -- <Specific key="0x04" label="Setpoint Thermostat" command_classes="0x43,0x72,0x86,0x8f,0xef,0x43,0x8f" basic="0x43" />
    -- <Specific key="0x05" label="Setback Thermostat" command_classes="0x40,0x43,0x47,0x72,0x86" basic="0x40" />
    -- <Specific key="0x06" label="General Thermostat V2" command_classes="0x40,0x43,0x72,0x86" basic="0x40" />
  -- </Generic>
  -- <Generic key="0x09" label="Window Covering" command_classes="0x20">
    -- <Specific key="0x01" label="Simple Window Covering" command_classes="0x50" basic="0x50" />
  -- </Generic>
  -- <Generic key="0x0f" label="Repeater Slave" command_classes="0x20">
    -- <Specific key="0x01" label="Basic Repeater Slave" />
  -- </Generic>
  -- <Generic key="0x10" label="Binary Switch" command_classes="0x20,0x25" basic="0x25">
    -- <Specific key="0x01" label="Binary Power Switch" command_classes="0x27" />
    -- <Specific key="0x03" label="Binary Scene Switch" command_classes="0x27,0x2b,0x2c,0x72" />
  -- </Generic>
  -- <Generic key="0x11" label="Multilevel Switch" command_classes="0x20,0x26" basic="0x26">
    -- <Specific key="0x01" label="Multilevel Power Switch" command_classes="0x27" />
    -- <Specific key="0x03" label="Multiposition Motor" command_classes="0x72,0x86" />
    -- <Specific key="0x04" label="Multilevel Scene Switch" command_classes="0x27,0x2b,0x2c,0x72" />
    -- <Specific key="0x05" label="Motor Control Class A" command_classes="0x25,0x72,0x86" />
    -- <Specific key="0x06" label="Motor Control Class B" command_classes="0x25,0x72,0x86" />
    -- <Specific key="0x07" label="Motor Control Class C" command_classes="0x25,0x72,0x86" />
  -- </Generic>
  -- <Generic key="0x12" label="Remote Switch" command_classes="0xef,0x20">
    -- <Specific key="0x01" label="Binary Remote Switch" command_classes="0xef,0x25" basic="0x25"/>
    -- <Specific key="0x02" label="Multilevel Remote Switch" command_classes="0xef,0x26" basic="0x26"/>
    -- <Specific key="0x03" label="Binary Toggle Remote Switch" command_classes="0xef,0x28" basic="0x28"/>
    -- <Specific key="0x04" label="Multilevel Toggle Remote Switch" command_classes="0xef,0x29" basic="0x29"/>
  -- </Generic>
  -- <Generic key="0x13" label="Toggle Switch" command_classes="0x20" >
    -- <Specific key="0x01" label="Binary Toggle Switch" command_classes="0x25,0x28" basic="0x28" />
    -- <Specific key="0x02" label="Multilevel Toggle Switch" command_classes="0x26,0x29" basic="0x29" />
  -- </Generic>
  -- <Generic key="0x14" label="Z/IP Gateway" command_classes="0x20">
    -- <Specific key="0x01" label="Z/IP Tunneling Gateway" command_classes="0x23,0x24,0x72,0x86"/>
    -- <Specific key="0x02" label="Z/IP Advanced Gateway" command_classes="0x23,0x24,0x2f,0x33,0x72,0x86"/>
  -- </Generic>
  -- <Generic key="0x15" label="Z/IP Node">
    -- <Specific key="0x01" label="Z/IP Tunneling Node" command_classes="0x23,0x2e,0x72,0x86" />
    -- <Specific key="0x02" label="Z/IP Advanced Node" command_classes="0x23,0x2e,0x2f,0x34,0x72,0x86" />
  -- </Generic>
  -- <Generic key="0x16" label="Ventilation" command_classes="0x20">
    -- <Specific key="0x01" label="Residential Heat Recovery Ventilation" command_classes="0x37,0x39,0x72,0x86" basic="0x39"/>
  -- </Generic>
  -- <Generic key="0x20" label="Binary Sensor" command_classes="0x30,0xef,0x20" basic="0x30">
    -- <Specific key="0x01" label="Routing Binary Sensor" />
  -- </Generic>
  -- <Generic key="0x21" label="Multilevel Sensor" command_classes="0x31,0xef,0x20" basic="0x31">
    -- <Specific key="0x01" label="Routing Multilevel Sensor" />
  -- </Generic>
  -- <Generic key="0x30" label="Pulse Meter" command_classes="0x35,0xef,0x20" basic="0x35"/>
  -- <Generic key="0x31" label="Meter" command_classes="0xef,0x20">
    -- <Specific key="0x01" label="Simple Meter" command_classes="0x32,0x72,0x86" basic="0x32" />
  -- </Generic>
  -- <Generic key="0x40" label="Entry Control" command_classes="0x20">
    -- <Specific key="0x01" label="Door Lock" command_classes="0x62" basic="0x62"/>
    -- <Specific key="0x02" label="Advanced Door Lock" command_classes="0x62,0x72,0x86" basic="0x62"/>
    -- <Specific key="0x03" label="Secure Keypad Door Lock" command_classes="0x62,0x63,0x72,0x86,0x98" basic="0x62"/>
  -- </Generic>
  -- <Generic key="0x50" label="Semi Interoperable" command_classes="0x20,0x72,0x86,0x88">
    -- <Specific key="0x01" label="Energy Production" command_classes="0x90" />
  -- </Generic>
  -- <Generic key="0xa1" label="Alarm Sensor" command_classes="0xef,0x20" basic="0x71">
    -- <Specific key="0x01" label="Basic Routing Alarm Sensor" command_classes="0x71,0x72,0x85,0x86,0xef,0x71" />
    -- <Specific key="0x02" label="Routing Alarm Sensor" command_classes="0x71,0x72,0x80,0x85,0x86,0xef,0x71" />
    -- <Specific key="0x03" label="Basic Zensor Alarm Sensor" command_classes="0x71,0x72,0x86,0xef,0x71" />
    -- <Specific key="0x04" label="Zensor Alarm Sensor" command_classes="0x71,0x72,0x80,0x86,0xef,0x71" />
    -- <Specific key="0x05" label="Advanced Zensor Alarm Sensor" command_classes="0x71,0x72,0x80,0x85,0x86,0xef,0x71" />
    -- <Specific key="0x06" label="Basic Routing Smoke Sensor" command_classes="0x71,0x72,0x85,0x86,0xef,0x71" />
    -- <Specific key="0x07" label="Routing Smoke Sensor" command_classes="0x71,0x72,0x80,0x85,0x86,0xef,0x71" />
    -- <Specific key="0x08" label="Basic Zensor Smoke Sensor" command_classes="0x71,0x72,0x86,0xef,0x71" />
    -- <Specific key="0x09" label="Zensor Smoke Sensor" command_classes="0x71,0x72,0x80,0x86,0xef,0x71" />
    -- <Specific key="0x0a" label="Advanced Zensor Smoke Sensor" command_classes="0x71,0x72,0x80,0x85,0x86,0xef,0x71" />
  -- </Generic>
  -- <Generic key="0xff" label="Non Interoperable" />
-- </DeviceClasses>

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
	debug(string.format("setVariableIfChanged(%s,%s,%s,%s)",serviceId, name, tostring(value), deviceId))
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

local function TableLength(T)
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

--------------------------------------------------------
-- VERA utils
--------------------------------------------------------
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
  local hostname, command
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
-- Razberry ZWay communications
------------------------------------------------
local function getAuthCookie(lul_device,user,password)
	debug(string.format("getAuthCookie (%s,%s)",user or '',password or ''))
	local sessioncookie = ""
	local url = string.format("http://%s:8083/ZAutomation/api/v1/login",this_ipaddr)
	debug(string.format("getAuthCookie url:%s",url))
	local data = string.format('{"login":"%s","password":"%s"}',user,password)
	local response_body = {}
	local commonheaders = {
			["Accept"]="application/json, text/plain, */*",
			-- ["Accept-Encoding"]="gzip, deflate",
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
	debug(string.format("myHttp (%s,%s)  data:%s",method,url,data or ''))
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
			-- ["Accept-Encoding"]="gzip, deflate",
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
-- Child Device Actions / VERA => ZWay
------------------------------------------------
local function UserSetPowerTarget(lul_device,lul_settings)
	local newTargetValue = tonumber(lul_settings.newTargetValue)
	debug(string.format("UserSetPowerTarget(%s,%s)",lul_device,newTargetValue))
	local zwid = luup.attr_get('altid',lul_device)
	if (newTargetValue >0) then
		newTargetValue = 255
	end

	local url = string.format(
		"http://%s:8083/ZWave.zway/Run/devices[%s].instances[0].commandClasses[%s].Set(%s)",
		this_ipaddr,
		zwid,
		37,
		newTargetValue)
	return myHttp(url,"POST","")
end

-- urn:micasaverde-com:serviceId:SecuritySensor1
local function UserSetArmed(lul_device,lul_settings)
	local newArmedValue = tonumber(lul_settings.newArmedValue)
	debug(string.format("UserSetArmed(%s,%s)",lul_device,newArmedValue))
	setVariableIfChanged("urn:micasaverde-com:serviceId:SecuritySensor1", "Armed", newArmedValue, lul_device)
end

local function noop(lul_device) 
	debug(string.format("Unknown Action (%s)",lul_device))
end 

local ActionMap = {
	["urn:micasaverde-com:serviceId:SecuritySensor1.SetArmed"] = UserSetArmed,
	["urn:upnp-org:serviceId:SwitchPower1.SetTarget"] = UserSetPowerTarget	
}
local function generic_action (serviceId, name)
	local key = serviceId .. "." .. name
	debug(string.format("generic_action: %s",key))
  return { run = ActionMap[key] or noop  }    -- TODO: map per name
end

------------------------------------------------------------------------------------------------
-- Device Map
-- in the future this will be a intelligent map that takes manufid, productid, generic class, specific class as input
-- and deliver the right structure like below to create VERA devices
------------------------------------------------------------------------------------------------

local DeviceDiscoveryTable = {
	{ 
		["genericType"]=16,
		["result"]={
			["name"]="Switch Device",
			["devicetype"]="urn:schemas-upnp-org:device:BinaryLight:1",
			["DFile"]="D_BinaryLight1.xml",
			["IFile"]="",
			["Parameters"]="urn:upnp-org:serviceId:SwitchPower1,Status=0\nurn:upnp-org:serviceId:SwitchPower1,Target=0",	-- "service,variable=value\nservice..."
		}
	},
	{ 
		["genericType"]=32,
		["result"]={
			["name"]="Sensor Device",
			["devicetype"]="urn:schemas-micasaverde-com:device:MotionSensor:1",
			["DFile"]="D_MotionSensor1.xml",
			["IFile"]="",
			["Parameters"]="urn:micasaverde-com:serviceId:SecuritySensor1,Tripped=0\n",	-- "service,variable=value\nservice..."
		}
	},
	-- { 
		-- ["manufacturerId"]=271,  Fibaro
		-- ["manufacturerProductId"]=4096,   Door Window
		-- ["manufacturerProductType"]=1792,		
		-- ["result"]={
			-- ["name"]="Door Lock Device",
			-- ["devicetype"]="urn:schemas-micasaverde-com:device:MotionSensor:1",
			-- ["DFile"]="D_MotionSensor1.xml",
			-- ["IFile"]="",
			-- ["Parameters"]="urn:micasaverde-com:serviceId:SecuritySensor1,Tripped=0\n",	-- "service,variable=value\nservice..."
		-- }
	-- },
}
local function findDeviceDescription( zway_device , instance_id )
	local unknown_device = {
		["name"]=zway_device.data.givenName.value or "New Unknown Device",
		["devicetype"]="urn:schemas-upnp-org:device:razb:unk:1",
		["DFile"]="D_RAZB_UNK.xml",
		["IFile"]="",
		["Parameters"]="",	-- "service,variable=value\nservice..."
	}
	
	-- return a device description in VERA's terms
	local result = unknown_device
	
	-- TODO need to implement the detection logic
	for k,record in pairs(DeviceDiscoveryTable) do
		if (record.genericType ~=nil) then
			if (zway_device.data.genericType.value == record["genericType"]) then
				result = record["result"]
				result["name"] = zway_device.data.givenName.value or result["name"]
			end
		end
	end
	
	return result
end


------------------------------------------------
-- Update Vera Devices from zWay Cmd Class data
-- ZWay => VERA
------------------------------------------------
local function updateSwitchBinary( lul_device , cmdClass )
	debug(string.format("updateSwitchBinary(%s,%s)",lul_device,json.encode(cmdClass)))
	local value = 0
	if (cmdClass.data.level.value==true) then
		value = 1
	end
	setVariableIfChanged("urn:upnp-org:serviceId:SwitchPower1", "Status", value, lul_device)
	setVariableIfChanged("urn:upnp-org:serviceId:SwitchPower1", "Target", value, lul_device)
end

local function updateSensorMultiLevel( lul_device , cmdClass )
	debug(string.format("updateSensorMultiLevel(%s,%s)",lul_device,json.encode(cmdClass)))
	-- Incomplete code : 
	-- for now, just decode the Power sensor
	if (cmdClass.data["4"] ~= nil) then
		local power = cmdClass.data["4"].val.value
		setVariableIfChanged("urn:micasaverde-com:serviceId:EnergyMetering1", "Watts", power, lul_device)
	end
end

local function updateSensorBinary( lul_device , cmdClass )
	debug(string.format("updateSensorBinary(%s,%s)",lul_device,json.encode(cmdClass)))
	-- Incomplete code : 
	-- for now, just decode the General Purpose sensor
	-- 1 = General Purpose
	-- 2 = Smoke
	-- 3 = Carbon Monoxide
	-- 4 = Carbon Dioxide
	-- 5 = Heat
	-- 6 = Water
	-- 7 = Freeze
	-- 8 = Tamper
	-- 9 = Aux
	-- 10 = Door/Window
	-- 11 = Tilt
	-- 12 = Motion
	-- 13 = Glass Break
	if (cmdClass.data["1"] ~= nil) then
		local result = "0"
		if (cmdClass.data["1"].level.value == true ) then
			result = "1"
		end
		setVariableIfChanged("urn:micasaverde-com:serviceId:SecuritySensor1", "Tripped", result, lul_device)
		if (result=="1") then
			setVariableIfChanged("urn:micasaverde-com:serviceId:SecuritySensor1", "LastTrip", tostring(cmdClass.data["1"].level.updateTime), lul_device)
		else
			setVariableIfChanged("urn:micasaverde-com:serviceId:SecuritySensor1", "LastUntrip", tostring(cmdClass.data["1"].level.updateTime), lul_device)
		end
	end
end

local function updateBatteryLevel( lul_device , cmdClass )
	debug(string.format("updateBatteryLevel(%s,%s)",lul_device,json.encode(cmdClass)))
	setVariableIfChanged("urn:micasaverde-com:serviceId:HaDevice1", "BatteryLevel", cmdClass.data.last.value, lul_device)
	setVariableIfChanged("urn:micasaverde-com:serviceId:HaDevice1", "BatteryDate", cmdClass.data.last.updateTime, lul_device)
end

local function updateWakeUp( lul_device , cmdClass )
	debug(string.format("updateWakeUp(%s,%s)",lul_device,json.encode(cmdClass)))
	setVariableIfChanged("urn:micasaverde-com:serviceId:ZWaveDevice1", "LastWakeup", cmdClass.data.lastWakeup.updateTime, lul_device)
	setVariableIfChanged("urn:micasaverde-com:serviceId:ZWaveDevice1", "WakeupInterval", cmdClass.data.interval.value, lul_device)
end

 -- one entry per cmdClass which we know how to decode and update VERA device from
local updateCommandClassDataMap = {
	["37"] = updateSwitchBinary,
	["48"] = updateSensorBinary,
	["49"] = updateSensorMultiLevel,
	["128"] = updateBatteryLevel,
	["132"] = updateWakeUp
}

------------------------------------------------
-- ZWAY data gathering loop
------------------------------------------------
local function initDeviceInstanceFromZWayData( lul_device, zway_device_id, instance_id , zway_device )
	debug(string.format("initDeviceInstanceFromZWayData(%s,%s,%s)",zway_device_id, instance_id ,json.encode(zway_device)))

	-- update all cmdclass from all instances if cmdClass is known in the update function map
	local veraDeviceId = findChild(lul_device, zway_device_id.."."..instance_id)
	if (veraDeviceId == nil ) then
		debug(string.format("initDeviceInstanceFromZWayData could not find device %s in parent %s",zway_device_id.."."..instance_id,lul_device))
		return -1
	end
	
	-- update device header
	luup.attr_set( "manufacturer", zway_device.data.vendorString.value , veraDeviceId)
	setVariableIfChanged(
		RAZB_SERVICE, "ZW_PID", 
		string.format("%s-%s-%s-%s",
			zway_device.data.manufacturerId.value,
			zway_device.data.manufacturerProductType.value,
			zway_device.data.manufacturerProductId.value,
			instance_id), 
		veraDeviceId)
	
	-- update status variables from zway instance cmdClass data
	local instance = zway_device.instances[instance_id]	
	for cmdClass_id,cmdClass in pairs(instance.commandClasses) do 
		local updateFunc = updateCommandClassDataMap[cmdClass_id]
		if (updateFunc ~= nil) then
			(updateFunc)(veraDeviceId, cmdClass)
		else
			debug(string.format("Unknown cmdClass '%s', ignoring update",cmdClass_id))
		end
	end		
	return 0
end


local function initDeviceFromZWayData( lul_device, zway_device_id, zway_device )
	debug(string.format("initDeviceFromZWayData(%s,%s)",zway_device_id,json.encode(zway_device)))
	for instance_id,instance in pairs(zway_device.instances) do 
		initDeviceInstanceFromZWayData( lul_device, zway_device_id, instance_id , zway_device )
	end
end

local function refreshDevices( lul_device, zway_data ) 
	debug(string.format("refreshDevices(%s,%s)",lul_device,json.encode(zway_data)))
	for k,v in pairs(zway_data) do
		local devid,instid,cls,variable = k:match("devices%.(%d+)%.instances%.(%d+).commandClasses.(%d+).data.(.+)")
		-- debug( string.format("devid:%s,instid:%s,cls:%s,variable:%s",devid or 'unk',instid or 'unk',cls or 'unk',variable or 'unk') )
		if (devid ~= nil ) then
			local vera_id, child_v = findChild( lul_device, devid.."."..instid )
			if (vera_id ~= nil) then
				zway_tree.devices[devid].instances[instid].commandClasses[cls].data[variable] = v
				local updateFunc = updateCommandClassDataMap[cls]
				if (updateFunc ~= nil) then
					(updateFunc)(vera_id, zway_tree.devices[devid].instances[instid].commandClasses[cls])
				else
					debug(string.format("Unknown cmdClass:'%s', ignoring update",cls))
				end				
			else
				debug("Unknown zWay device:"..devid )
			end
		else
				debug("ignoring zway update key:"..k)
		end
	end
end

local function resyncZwayDevices(lul_device)
	lul_device = tonumber(lul_device)
	debug(string.format("resyncZwayDevices(%s)",lul_device))
	local handle = luup.chdev.start(lul_device);
	for device_id,zway_device in pairs(zway_tree.devices) do
		-- for all instances
		if (device_id~="1") then
			for instance_id,instance in pairs(zway_device.instances) do 
				local descr = findDeviceDescription(zway_device,instance_id)
				if (descr ~= nil) then
					debug(string.format("Creating device for zway dev #%s , instance #%s",device_id,instance_id))
					luup.chdev.append(
						lul_device, handle, 	-- parent device and handle
						device_id.."."..instance_id , descr.name, 				-- id and description
						descr.devicetype, 		-- device type
						descr.DFile, descr.IFile, -- device filename and implementation filename
						descr.Parameters, 				-- uPNP child device parameters: "service,variable=value\nservice..."
						false,							-- embedded
						false								-- invisible
					)
				end
			end
		end
	end

	luup.chdev.sync(lul_device, handle)
	
	debug(string.format("Updating Vera devices"))
	for zway_device_id,zway_device in pairs(zway_tree.devices) do
		initDeviceFromZWayData( lul_device, zway_device_id, zway_device )
	end
	return true -- success if it comes here, otherwise luup will reload
end

function getZWayData(lul_device,forcedtimestamp)
	lul_device = tonumber(lul_device)
	if (forcedtimestamp==nil) then
		forcedtimestamp = timestamp
	end
	debug(string.format("getZWayData(%s,%s)",lul_device,forcedtimestamp))

	local url = string.format("http://%s:8083/ZWave.zway/Data/%s",this_ipaddr,forcedtimestamp)
	local user = getSetVariable(RAZB_SERVICE, "User", lul_device, "admin")
	local password = getSetVariable(RAZB_SERVICE, "Password", lul_device, "")
	local result = myHttp(url,"POST","")
	if (result ~= -1) then
		local obj = json.decode(result)
		if (timestamp==0) then
			-- very first update
			zway_tree = obj
			timestamp = zway_tree.updateTime	-- last timestamp received
			debug(string.format("First refresh -- Next timestamp: %s",timestamp))
			resyncZwayDevices(lul_device)

		else
			-- refresh updates
			timestamp = obj.updateTime	-- last timestamp received
			refreshDevices(lul_device,obj)
			debug(string.format("Regular refresh -- Next timestamp: %s",timestamp))
		end
	end
	
	debug(string.format("getZWayData done, new timestamp=%s os.time=%s",timestamp,os.time()))
	luup.call_delay("getZWayData",DATA_REFRESH_RATE,tostring(lul_device))	
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
	
	if (oldversion~=nil) then
		major,minor = string.match(oldversion,"v(%d+)%.(%d+)")
		major,minor = tonumber(major),tonumber(minor)
		debug ("Plugin version: "..version.." Device's Version is major:"..major.." minor:"..minor)

		local newmajor,newminor = string.match(version,"v(%d+)%.(%d+)")
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
	getZWayData(lul_device)

end
		
function initstatus(lul_device)
	lul_device = tonumber(lul_device)
	this_device = lul_device
	this_ipaddr = "127.0.0.1"

	log("initstatus("..lul_device..") starting version: "..version)	
	math.randomseed( os.time() )
	checkVersion(lul_device)

	local delay = 10		-- delaying first refresh by x seconds
	luup.devices[lul_device].action_callback (generic_action)     -- catch all undefined action calls
	luup.call_delay("startupDeferred", delay, tostring(lul_device))		
end
 
-- do not delete, last line must be a CR according to MCV wiki page
