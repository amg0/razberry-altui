-- // This program is free software: you can redistribute it and/or modify
-- // it under the condition that it is for private or home useage and 
-- // this whole comment is reproduced in the source code file.
-- // Commercial utilisation is not authorized without the appropriate
-- // written agreement from amg0 / alexis . mermet @ gmail . com
-- // This program is distributed in the hope that it will be useful,
-- // but WITHOUT ANY WARRANTY; without even the implied warranty of
-- // MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE . 

local version = "v0.08beta"

local MSG_CLASS = "RAZB"
local RAZB_SERVICE = "urn:upnp-org:serviceId:razb1"
local devicetype = "urn:schemas-upnp-org:device:razb:1"
local DEBUG_MODE = false	-- controlled by UPNP action
local UI7_JSON_FILE= "D_RAZB.json"

local json = require("dkjson")
local mime = require("mime")
local socket = require("socket")
local http = require("socket.http")
local https = require ("ssl.https")
local ltn12 = require("ltn12")
local modurl = require "socket.url"

local DATA_REFRESH_RATE = 2		-- refresh rate from zway
local timestamp = 0				-- last timestamp received
local zway_controller_id = "1"	-- zway device id of the razberry controller 
local zway_tree = {}			-- zWay data model tree ( agregates all info as we receives it )
local this_device
local this_ipaddr

-- Wiki doc
-- http://wiki.micasaverde.com/index.php/ZWave_Debugging
-- mapping zWave to D_XML
-- https://github.com/yepher/RaZBerry/blob/master/README.md

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
			if( getAltID(k) == altid) then
				return k,v
			end
		end
	end
	debug(string.format("findChild failed"))
	return nil,nil
end


-----------------------------------------------------
-- code and decode ALTID from zway path information
-----------------------------------------------------
local function generateAltid(devid,instid,cls,variable)
	local str = string.format("%s.%s",devid,instid or '0')
	if (cls ~= nil) and (variable ~= nil) then
		str = str .. string.format(".%s.%s",cls,variable)
	end
	return str
end

local function decodeAltid(altid)
	local parts = Split(altid,"%.")
	-- debug(string.format("parts %s",json.encode(parts)))
	return parts[1],parts[2] or '0',parts[3] or '',parts[4] or ''
	-- local devid,instid,cls,variable
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
	setVariableIfChanged("urn:upnp-org:serviceId:SwitchPower1", "Target", newTargetValue, lul_device)
	local altid  = luup.attr_get('altid',lul_device)
	local zwid,instid,cls,variable = decodeAltid(altid)

-- debug(string.format("lul %s altid %s zwid %s",lul_device,altid,zwid))
	if (newTargetValue >0) then
		newTargetValue = 255
	end

	local url = string.format(
		"http://%s:8083/ZWave.zway/Run/devices[%s].instances[%s].commandClasses[%s].Set(%s)",
		this_ipaddr,
		zwid,
		instid,
		37,
		newTargetValue)
	return myHttp(url,"POST","")
end

--serviceId=urn:upnp-org:serviceId:Dimming1&action=SetLoadLevelTarget&newLoadlevelTarget=32 
local function UserSetLoadLevelTarget(lul_device,lul_settings)
	local newLoadlevelTarget = tonumber(lul_settings.newLoadlevelTarget) or 0
	debug(string.format("UserSetLoadLevelTarget(%s,%s)",lul_device,newLoadlevelTarget))
	setVariableIfChanged("urn:upnp-org:serviceId:Dimming1", "LoadLevelTarget", newLoadlevelTarget, lul_device)
	local altid  = luup.attr_get('altid',lul_device)
	local zwid,instid,cls,variable = decodeAltid(altid)
	newLoadlevelTarget = newLoadlevelTarget % 256

	local url = string.format(
		"http://%s:8083/ZWave.zway/Run/devices[%s].instances[%s].commandClasses[%s].Set(%s,255)",
		this_ipaddr,
		zwid,
		instid,
		38,
		newLoadlevelTarget)
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
	["urn:upnp-org:serviceId:SwitchPower1.SetTarget"] = UserSetPowerTarget,
	["urn:upnp-org:serviceId:Dimming1.SetLoadLevelTarget"] = UserSetLoadLevelTarget, 
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
	-- { 
		-- ["genericType"]=16,
		-- ["result"]={
			-- ["name"]="Switch Device",
			-- ["devicetype"]="urn:schemas-upnp-org:device:BinaryLight:1",
			-- ["DFile"]="D_BinaryLight1.xml",
			-- ["IFile"]="",
			-- ["Parameters"]="urn:upnp-org:serviceId:SwitchPower1,Status=0\nurn:upnp-org:serviceId:SwitchPower1,Target=0",	-- "service,variable=value\nservice..."
		-- }
	-- },
	-- { 
		-- ["genericType"]=32,
		-- ["result"]={
			-- ["name"]="Sensor Device",
			-- ["devicetype"]="urn:schemas-micasaverde-com:device:MotionSensor:1",
			-- ["DFile"]="D_MotionSensor1.xml",
			-- ["IFile"]="",
			-- ["Parameters"]="urn:micasaverde-com:serviceId:SecuritySensor1,Tripped=0\n",	-- "service,variable=value\nservice..."
		-- }
	-- },
	{ 
		["manufacturerId"]=271,  --Fibaro
		["manufacturerProductId"]=4096,   -- Door Window
		["manufacturerProductType"]=1792,		
		["result"]={
			["name"]="Door Sensor Device",
			["devicetype"]="urn:schemas-micasaverde-com:device:DoorSensor:1",
			["DFile"]="D_DoorSensor1.xml",
			["IFile"]="",
			["Parameters"]="urn:micasaverde-com:serviceId:SecuritySensor1,Tripped=0\nurn:micasaverde-com:serviceId:SecuritySensor1,Armed=0\n",	-- "service,variable=value\nservice..."
		}
	},
	{ 
		["manufacturerId"]=271,  --Fibaro
		["manufacturerProductId"]=4096,   -- Smoke Window
		["manufacturerProductType"]=3072,		
		["result"]={
			["name"]="Smoke Sensor Device",
			["devicetype"]="urn:schemas-micasaverde-com:device:SmokeSensor:1",
			["DFile"]="D_SmokeSensor1.xml",
			["IFile"]="",
			["Parameters"]="urn:micasaverde-com:serviceId:SecuritySensor1,Tripped=0\nurn:micasaverde-com:serviceId:SecuritySensor1,Armed=0\n",	-- "service,variable=value\nservice..."
		}
	},
}

local loader = require "openLuup.loader"    -- just keeping this require near the place it's used,
                                            -- rather than at the start of the file at the moment.

-------------------------------
-- GENERIC DEVICES
-- blame @akbooer

-- use Generic Type to lookup Vera category, hence generic device type...
-- ...and from the device file we can then get services...
-- ...and from the service files, the actions and variables.
-- returns nil if no match found.
--

local function findGenericDevice (zway_device, instance_id,sensor_type)
  -- map between DeviceClasses and Vera categories and generic devices
  -- TODO:  add finer detail with instance_id, etc...
  local DeviceClassMap = {
    [0x01] = {label="Remote Controller",  category = 1,   upnp_file = "D_SceneController1.xml"},
    [0x02] = {label="Static Controller",  category = 1,   upnp_file = "D_SceneController1.xml"},
--    [0x03] = {label="AV Control Point",   category = 15},
--    [0x04] = {label="Display", command_classes="0x20"},
    [0x08] = {label="Thermostat",         category = 5,   upnp_file = "D_HVAC_ZoneThermostat1.xml"},
    [0x09] = {label="Window Covering",    category = 8,   upnp_file = "D_WibdowCovering1.xml"},
--    [0x0f] = {label="Repeater Slave", command_classes="0x20"},
    [0x10] = {label="Binary Switch",      category = 3,   upnp_file = "D_BinaryLight1.xml"},
    [0x11] = {label="Multilevel Switch",  category = 2,   upnp_file = "D_DimmableLight1.xml"},
    [0x12] = {label="Remote Switch",      category = 3,   upnp_file = "D_BinaryLight1.xml"},
    [0x13] = {label="Toggle Switch",      category = 3,   upnp_file = "D_BinaryLight1.xml"},
--    [0x14] = {label="Z/IP Gateway",       category = 19},
--    [0x15] = {label="Z/IP Node"},
    [0x16] = {label="Ventilation",        category = 5,   upnp_file = "D_HVAC_ZoneThermostat1.xml"},
    [0x20] = {label="Binary Sensor",      category = 4,   upnp_file = "D_MotionSensor1.xml"},
    [0x21] = {label="Multilevel Sensor",  category = 12,  upnp_file = "D_GenericSensor1.xml",
        sensor_type = {
            ["Light"]       = {upnp_file="D_LightSensor1.xml", device_type="urn:schemas-micasaverde-com:device:LightSensor:1"},
            ["Humidity"]    = {upnp_file="D_HumiditySensor1.xml", device_type="urn:schemas-micasaverde-com:device:HumiditySensor:1"},
            ["Temperature"] = {upnp_file="D_TemperatureSensor1.xml", device_type="urn:schemas-micasaverde-com:device:TemperatureSensor:1"},
          }
      },
    [0x30] = {label="Pulse Meter",        category = 21,  upnp_file = "D_PowerMeter1.xml"},
    [0x31] = {label="Meter",              category = 21,  upnp_file = "D_PowerMeter1.xml"},
    [0x40] = {label="Entry Control",      category = 7,   upnp_file = "D_DoorLock1.xml"},
--    [0x50] = {label="Semi Interoperable"},
--    [0xa1] = {label="Alarm Sensor",       category = 22},   -- TODO: find generic Alarm Sensor device
--    [0xff] = {label="Non Interoperable"},
  }

  local generic = tonumber (zway_device.instances[instance_id].data.genericType.value) or 0  -- should already be a number
  local map =  DeviceClassMap[generic]  
  if map and map.upnp_file then
    local upnp_file = map.upnp_file		
		local device_type = "urn:schemas-upnp-org:device:razb:unk:1"
		if (map.sensor_type ~= nil and map.sensor_type[sensor_type]~=nil) then
			upnp_file = map.sensor_type[sensor_type].upnp_file or map.upnp_file
			device_type = map.sensor_type[sensor_type].device_type or "urn:schemas-upnp-org:device:razb:unk:1"
		end
    local d = loader.read_device (upnp_file)          -- read the device file
    
    local p = {}
		if (d.service_list ~=nil) then
			for _, s in ipairs (d.service_list) do
				if s.SCPDURL then 
					local svc = loader.read_service (s.SCPDURL)   -- read the service file(s)
					local parameter = "%s,%s=%s"
					for _,v in ipairs (svc.variables or {}) do
						local default = v.defaultValue
						if default and default ~= '' then            -- only variables with defaults
							p[#p+1] = parameter: format (s.serviceId, v.name, default)
						end
					end
				end
			end
		end
    local parameters = table.concat (p, '\n')
    local result = {
        name = sensor_type or zway_device.data.givenName.value or upnp_file:match "D_(%D+)%d*%.xml" or '?',
        devicetype  = d.device_type or device_type,
        DFile       = upnp_file,
        IFile       = '',
        Parameters  = parameters,
      }
		debug(string.format("Applying device mapping based on generic type : %s",json.encode(result)))
    return result
  end
	debug(string.format("Did not find a generic type mapping for type: %d",generic))
	return nil
end

local function getIconPath( zway_device , instance_id )
	local generic  = zway_device.instances[instance_id].data.genericType.value
	local specific = zway_device.instances[instance_id].data.specificType.value
	return string.format("http://%s:8081/pics/icons/device_icon_%s_%s.png",this_ipaddr,generic,specific)
end

local function findDeviceDescription( zway_device , instance_id , sensor_type )
	debug(string.format("findDeviceDescription for instance %s sensor:'%s'",instance_id,sensor_type or '' ))

	local unknown_device = {
		["name"]=zway_device.data.givenName.value or "New Unknown Device",
		["devicetype"]="urn:schemas-upnp-org:device:razb:unk:1",
		["DFile"]="D_RAZB_UNK.xml",
		["IFile"]="",
		["Parameters"]="urn:upnp-org:serviceId:razbunk1,IconCode=".. getIconPath( zway_device , instance_id ) .."\n",	-- "service,variable=value\nservice..."
	}
	
	-- return a device description in VERA's terms
	local result = nil
	
	-- test on product ID matching, overriding default mapping
	if (instance_id=="0") and (sensor_type==nil) then
		for k,record in pairs(DeviceDiscoveryTable) do
			if (record.manufacturerId ~=nil) then
				if (zway_device.data.manufacturerId.value == record["manufacturerId"] and 
					zway_device.data.manufacturerProductId.value == record["manufacturerProductId"] and
					zway_device.data.manufacturerProductType.value == record["manufacturerProductType"]  ) then
					result = record["result"]
					result["name"] = zway_device.data.givenName.value or result["name"]
					debug(string.format("Found precise device mapping by manuf+prod ID : %s",json.encode(record)))
					return result
				end
			end
		end
	end
	
	if (result == nil) then
		result = findGenericDevice(zway_device, instance_id,sensor_type) or unknown_device
	end
	
	return result
end


------------------------------------------------
-- Update Vera Devices from zWay Cmd Class data
-- ZWay => VERA
-- obj = {zwid=devid, instid=instid, cls=cls, var=variable}
------------------------------------------------
local function getLuupDeviceFromObj( lul_device, obj )
	local altid = generateAltid(obj.zwid,obj.instid,obj.cls,obj.var)
	local veraid, veradev = findChild(lul_device,altid)
	return veraid, veradev
end
-- Same but ignore class & variable
local function getLuupDeviceFromObjInstance( lul_device, obj )
	local altid = generateAltid(obj.zwid,obj.instid)
	local veraid, veradev = findChild(lul_device,altid)
	return veraid, veradev
end

local function updateSwitchBinary( lul_device, obj , cmdClass )
	debug(string.format("updateSwitchBinary(%s,%s)",lul_device,json.encode(cmdClass)))
	local value = 0
	if (cmdClass.data.level.value==true) then
		value = 1
	end
	local childid, child = getLuupDeviceFromObjInstance( lul_device, obj )
	setVariableIfChanged("urn:upnp-org:serviceId:SwitchPower1", "Status", value, childid)
	-- setVariableIfChanged("urn:upnp-org:serviceId:SwitchPower1", "Target", value, lul_device)
end

local function updateSensorMultiLevel( lul_device, obj , cmdClass )
	debug(string.format("updateSensorMultiLevel(%s,%s)",lul_device,json.encode(cmdClass)))
	local childid, child = getLuupDeviceFromObj( lul_device, obj )
	-- Incomplete code : 
	-- for now, just decode the Power sensor
	if (cmdClass.data["1"] ~= nil) then
		-- local altid = luup.devices[lul_device].id .. ".49.1"
		-- local child = findChild(lul_device,altid)
		local temp = cmdClass.data["1"].val.value
		setVariableIfChanged("urn:upnp-org:serviceId:TemperatureSensor1", "CurrentTemperature", temp or '', childid)
	end
	if (cmdClass.data["3"] ~= nil) then
		-- local altid = luup.devices[lul_device].id .. ".49.3"
		-- local child = findChild(lul_device,altid)
		local lux = cmdClass.data["3"].val.value
		setVariableIfChanged("urn:micasaverde-com:serviceId:LightSensor1", "CurrentLevel", lux or '', childid)
	end
	if (cmdClass.data["4"] ~= nil) then
		-- exception, we log it on the instance level node.
		local veraid, veradev = getLuupDeviceFromObjInstance( lul_device, obj )
		local power = cmdClass.data["4"].val.value
		setVariableIfChanged("urn:micasaverde-com:serviceId:EnergyMetering1", "Watts", power or '', veraid)
	end
	if (cmdClass.data["5"] ~= nil) then
		-- local altid = luup.devices[lul_device].id .. ".49.5"
		-- local child = findChild(lul_device,altid)
		local hum = cmdClass.data["5"].val.value
		setVariableIfChanged("urn:micasaverde-com:serviceId:HumiditySensor1", "CurrentLevel", hum or '', childid)
	end
	if (cmdClass.data["27"] ~= nil) then
		-- local altid = luup.devices[lul_device].id .. ".49.27"
		-- local child = findChild(lul_device,altid)
		local uv = cmdClass.data["27"].val.value
		setVariableIfChanged("urn:micasaverde-com:serviceId:UltravioletSensor1", "CurrentLevel", uv or '', childid)
	end
end

local function updateSensorBinary( lul_device, obj , cmdClass )
	debug(string.format("updateSensorBinary(%s,%s)",lul_device,json.encode(cmdClass)))
	local childid, child = getLuupDeviceFromObjInstance( lul_device, obj )
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
		setVariableIfChanged("urn:micasaverde-com:serviceId:SecuritySensor1", "Tripped", result, childid)
		if (result=="1") then
			setVariableIfChanged("urn:micasaverde-com:serviceId:SecuritySensor1", "LastTrip", tostring(cmdClass.data["1"].level.updateTime), childid)
		else
			setVariableIfChanged("urn:micasaverde-com:serviceId:SecuritySensor1", "LastUntrip", tostring(cmdClass.data["1"].level.updateTime), childid)
		end
	end
end

local function updateBatteryLevel( lul_device, obj , cmdClass )
	debug(string.format("updateBatteryLevel(%s,%s)",lul_device,json.encode(cmdClass)))
	local childid, child = getLuupDeviceFromObjInstance( lul_device, obj )
	setVariableIfChanged("urn:micasaverde-com:serviceId:HaDevice1", "BatteryLevel", cmdClass.data.last.value, childid)
	setVariableIfChanged("urn:micasaverde-com:serviceId:HaDevice1", "BatteryDate", cmdClass.data.last.updateTime, childid)
end

local function updateWakeUp( lul_device, obj , cmdClass )
	debug(string.format("updateWakeUp(%s,%s)",lul_device,json.encode(cmdClass)))
	local childid, child = getLuupDeviceFromObjInstance( lul_device, obj )
	setVariableIfChanged("urn:micasaverde-com:serviceId:ZWaveDevice1", "LastWakeup", cmdClass.data.lastWakeup.updateTime, childid)
	setVariableIfChanged("urn:micasaverde-com:serviceId:ZWaveDevice1", "WakeupInterval", cmdClass.data.interval.value, childid)
end

local function updateSwitchMultiLevel( lul_device, obj , cmdClass )
	debug(string.format("updateSwitchMultiLevel(%s,%s)",lul_device,json.encode(cmdClass)))
	local childid, child = getLuupDeviceFromObjInstance( lul_device, obj )
	local value = tonumber (cmdClass.data.level.value) or 0
	setVariableIfChanged("urn:upnp-org:serviceId:Dimming1", "LoadLevelStatus", value, childid)
	-- setVariableIfChanged("urn:upnp-org:serviceId:Dimming1", "LoadLevelTarget", value, childid)
end

 -- one entry per cmdClass which we know how to decode and update VERA device from
local updateCommandClassDataMap = {
	["37"] = updateSwitchBinary,
	["38"] = updateSwitchMultiLevel,
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
	local altid = zway_device_id.."."..instance_id
	local veraDeviceId = findChild(lul_device, altid)
	if (veraDeviceId == nil ) then
		debug(string.format("initDeviceInstanceFromZWayData could not find device %s in parent %s",altid,lul_device))
		return -1
	end
		
	-- update status variables from zway instance cmdClass data
	local instance = zway_device.instances[instance_id]	
	setVariableIfChanged(
		RAZB_SERVICE, "ZW_PID", 
		string.format("%s_%s_%s_%s",
			zway_device.data.manufacturerId.value,
			zway_device.data.manufacturerProductType.value,
			zway_device.data.manufacturerProductId.value,
			instance_id), 
		veraDeviceId)		

	setVariableIfChanged(
		RAZB_SERVICE, "ZW_Generic_Specific", 
		string.format("%s_%s",
			instance.data.genericType.value,
			instance.data.specificType.value
		), 
	veraDeviceId)

	for cmdClass_id,cmdClass in pairs(instance.commandClasses) do 
		local updateFunc = updateCommandClassDataMap[cmdClass_id]
		if (updateFunc ~= nil) then
			(updateFunc)(lul_device, {zwid=zway_device_id, instid=instance_id, cls=cmdClass_id, var=nil}, cmdClass)
		else
			debug(string.format("Unknown cmdClass '%s', ignoring update",cmdClass_id))
		end
	end		
	return 0
end


local function zWayToVeraNodeInfo(arr)
	-- debug(string.format("zWayToVeraNodeInfo(%s)",json.encode(arr)))
	table.sort(arr)
	local result = {}
	for k,v in ipairs(arr) do
		result [ #result +1 ] = string.format("%x",v)
	end
	-- debug(string.format("zWayToVeraNodeInfo result(%s)",json.encode(result)))
	return table.concat(result,",")
end

local function zWayToVeraNeighbors(lul_device,arr)
	local result = {}
	for k,v in ipairs(arr) do
		local veraDeviceId = findChild(lul_device, v..".0")
		result [ #result +1 ] = veraDeviceId 
	end
	return table.concat(result,",")
end

local function initDeviceFromZWayData( lul_device, zway_device_id, zway_device )
	debug(string.format("initDeviceFromZWayData(%s,%s)",zway_device_id,json.encode(zway_device)))
	for instance_id,instance in pairs(zway_device.instances) do 
		initDeviceInstanceFromZWayData( lul_device, zway_device_id, instance_id , zway_device )
	end

	-- update device with ZW specific information 
	local veraDeviceId = findChild(lul_device, zway_device_id..".0")
	-- this info could depend on the fact that the user selected a device description in the zway user interface ( peperdb ! )
	luup.attr_set( "manufacturer", zway_device.data.vendorString.value , veraDeviceId)
		  
	-- update device with VERA type of information 
	setVariableIfChanged(
		"urn:micasaverde-com:serviceId:ZWaveDevice1","ManufacturerInfo",
		string.format("%s,%s,%s",
			zway_device.data.manufacturerId.value,
			zway_device.data.manufacturerProductType.value,
			zway_device.data.manufacturerProductId.value),
		veraDeviceId)
	setVariableIfChanged("urn:micasaverde-com:serviceId:ZWaveDevice1","NodeInfo",zWayToVeraNodeInfo(zway_device.data.nodeInfoFrame.value),veraDeviceId)
	setVariableIfChanged("urn:micasaverde-com:serviceId:ZWaveDevice1","Neighbors",zWayToVeraNeighbors(lul_device,zway_device.data.neighbours.value),veraDeviceId)
	setVariableIfChanged("urn:micasaverde-com:serviceId:ZWaveDevice1","PollNoReply",0,veraDeviceId)
	setVariableIfChanged("urn:micasaverde-com:serviceId:ZWaveDevice1","PollOk",0,veraDeviceId)
end

local function refreshDevices( lul_device, zway_data ) 
	debug(string.format("refreshDevices(%s,%s)",lul_device,json.encode(zway_data)))
	for k,v in pairs(zway_data) do
		local devid,instid,cls,variable = k:match("devices%.(%d+)%.instances%.(%d+).commandClasses.(%d+).data.(.+)")
		--
		-- try to decode command classes
		-- debug( string.format("devid:%s,instid:%s,cls:%s,variable:%s",devid or 'unk',instid or 'unk',cls or 'unk',variable or 'unk') )
		if (devid ~= nil ) then
			-- update zway tree
			zway_tree.devices[devid].instances[instid].commandClasses[cls].data[variable] = v
			-- update vera devices
			local updateFunc = updateCommandClassDataMap[cls]
			if (updateFunc ~= nil) then
				(updateFunc)(lul_device, {zwid=devid, instid=instid, cls=cls, var=variable}, zway_tree.devices[devid].instances[instid].commandClasses[cls])
			else
				debug(string.format("Unknown cmdClass:'%s', ignoring update",cls))
			end				
		else
			-- try to decode NIF
			devid = k:match("devices%.(%d+)%.data%.nodeInfoFrame")
			if (devid ~= nil ) then
				local altid = generateAltid(devid,"0")
				local vera_id, child_v = findChild( lul_device, altid )
				setVariableIfChanged(
					"urn:micasaverde-com:serviceId:ZWaveDevice1","NodeInfo",
					zWayToVeraNodeInfo(v.value),
					vera_id)					
			else
				debug("ignoring zway update key:"..k)
			end
		end
	end
end

local function appendZwayDevice (lul_device, handle, altid, descr)
	debug(string.format("Creating device for zway dev-instance #%s", altid))
	luup.chdev.append(
		lul_device, handle, 	-- parent device and handle
		altid , descr.name, 	-- id and description
		descr.devicetype, 		-- device type
		descr.DFile, descr.IFile, -- device filename and implementation filename
		descr.Parameters, 				-- uPNP child device parameters: "service,variable=value\nservice..."
		false,							-- embedded
		false							-- invisible
	)
end

-- create correct parent/child relationship between instances
local function resyncZwayDevices(lul_device)
	local no_reload = true
	lul_device = tonumber(lul_device)
	debug(string.format("resyncZwayDevices(%s)",lul_device))
	
	-- for all top-level ["0"] instances
	local parent = {}

	local handle = luup.chdev.start(lul_device);
	for device_id,zway_device in pairs(zway_tree.devices) do
		if (device_id~= zway_controller_id ) then
			for instance_id,instance in pairs({["0"] = zway_device.instances["0"]}) do 
				local descr = findDeviceDescription(zway_device,instance_id)
				if (descr ~= nil) then
					local altid = generateAltid(device_id,instance_id) 
					parent [altid] = {device_id = device_id, zway_device = zway_device}
					appendZwayDevice (lul_device, handle, altid, descr)
				end
			end
		end
	end
	local reload = luup.chdev.sync(lul_device, handle, no_reload)   -- sync all the top-level devices
  	
  -- now for all lower-level instances
	for devNo, dev in pairs(luup.devices) do
		local p = parent [dev.id]	-- dev.id is the altid 
		if p then
			getmetatable(dev).__index.handle_children = true       -- ensure parent handles Zwave actions
			local handle = luup.chdev.start(devNo);
			local device_id, zway_device = p.device_id, p.zway_device
			for instance_id,instance in pairs(zway_device.instances) do 
				debug( string.format("Instance %s", instance_id))
				-- treat the SensorMultiLevel situation
				-- even on instance 0
				if (instance.commandClasses["49"] ~= nil ) then
					-- sensor type
					local class_data = instance.commandClasses["49"].data
					-- debug( string.format("Sensor 49 data %s", json.encode(class_data)) )
					-- in case of sensor
					for k,sensor_type in pairs({
							["1"]="Temperature",
							["3"]="Light",
							["5"]="Humidity",
							["27"]="Ultraviolet"
						}) do
						if (class_data[k] ~= nil) then
							local descr = findDeviceDescription(zway_device,instance_id,sensor_type)
							if (descr ~= nil) then
								local altid = generateAltid(device_id,instance_id,"49",k)
								appendZwayDevice (devNo, handle, altid, descr)
							end
						end
					end
				else
					-- classical situation, we need to create other instances
					if instance_id ~= "0" then	-- instance 0 is already done
						-- debug( string.format("No Sensor data"))
						local descr = findDeviceDescription(zway_device,instance_id)
						if (descr ~= nil) then
							local altid = generateAltid(device_id,instance_id) 
							appendZwayDevice (devNo, handle, altid, descr)
						end
					end
				end
			end
			local reload2 = luup.chdev.sync(devNo, handle, no_reload)   -- sync the lower-level devices for this top-level one
			reload = reload or reload2
		end
	end
	
	-- reload if needed
	if reload then luup.reload () end
  
	-- if we are here, it means we did not reload and we can update the devices that were created
	debug(string.format("Updating Vera devices"))
	for zway_device_id,zway_device in pairs(zway_tree.devices) do
		if (zway_device_id ~= zway_controller_id ) then
			initDeviceFromZWayData( lul_device, zway_device_id, zway_device )
		end
	end
	
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
	luup.set_failure(0,lul_device)	-- openLuup is UI7 compatible
	
	-- get data
	getZWayData(lul_device)
	
	log("startup completed")	
end
		
function initstatus(lul_device)
	lul_device = tonumber(lul_device)
	this_device = lul_device

	local ip = luup.attr_get ("ip", lul_device)   -- use specified IP, if present
	this_ipaddr = ip:match "%d+%.%d+%.%d+%.%d+" and ip or "127.0.0.1"

	log("initstatus("..lul_device..") starting version: "..version)	

	luup.devices[lul_device].action_callback (generic_action)     -- catch all undefined action calls
	startupDeferred(lul_device)
	-- local delay = 10		-- delaying first refresh by x seconds
	-- luup.call_delay("startupDeferred", delay, tostring(lul_device))		
end
 
-- do not delete, last line must be a CR according to MCV wiki page
