local caps = require('st.capabilities')
local utils = require('st.utils')
local neturl = require('net.url')
local log = require('log')
local json = require('dkjson')
local cosock = require "cosock"
local http = cosock.asyncify "socket.http"
http.TIMEOUT = 5
local ltn12 = require('ltn12')
local httpUtil = require('httpUtil')
local socket = require('socket')
local config = require('config')

--Custom capabilities
local zoneRuntimeCap = caps['towertalent27877.zoneruntime2']
local zoneTimeRemaningCap = caps['towertalent27877.zonetimeremaining']

local activeStatusCapName = 'towertalent27877.activestatus9'
local activeStatusCap = caps[activeStatusCapName]

local healthCapName = 'towertalent27877.health'
local healthCap = caps[healthCapName]

--Device type info
baseUrl = ''
local controllerId = 'RainMachineController'
local programProfile = 'RainMachineProgram.v1'
local zoneProfile = 'RainMachineZone.v1'


--Prevent spamming bad auth info
local authIsBad = false
local access_token = ''

--Allow for occasional errors
local consecutiveFailureCount = 0
local consecutiveFailureThreshold = 20

--Handle skipping a refresh iteration if a command was just issued
local commandIsPending = false

--Main exported object
local command_handler = {}

--Allow resetting auth flag from outside
function command_handler.resetAuth()
  authIsBad = false
end

------------------
-- Refresh command
function command_handler.refresh(driver, callingDevice, skipScan, firstAuth)

  log.info('NetworkId ' ..callingDevice.device_network_id)
  if commandIsPending == true then
    log.info('Skipping refresh to let command settle.')
    commandIsPending = false
    return
  end

  if authIsBad == true then
    log.info('Bad auth.')
    return
  end

  local rainMachineController
  local device_list = driver:get_devices() --Grab existing devices

  --If called from controller, shortcut it
  if (callingDevice.device_network_id == controllerId) then
    rainMachineController = callingDevice

  --Otherwise, look up the controller device
  else
    for _, device in ipairs(device_list) do
      if device.device_network_id == controllerId then
        rainMachineController = driver.get_device_info(driver, device.id, true)
      end
    end
  end

  --Handle manual IP entry
  if rainMachineController.preferences.serverIp == '' or rainMachineController.preferences.serverPort == '' then
    log.info('Missing network info')
    return
  end

--Handle blank auth info
  if rainMachineController.preferences.password == '' then
    local defaultAuthStatus = 'Awaiting credentials'
    consecutiveFailureCount = 100 --Force immediate display of errors once auth is entered
    return
  end

  baseUrl = 'http://' ..rainMachineController.preferences.serverIp ..':' ..rainMachineController.preferences.serverPort

  --Call out to RM device to get access token if needed
  if access_token == '' then

    local data = {pwd=rainMachineController.preferences.password}
    local success, code, res_body = httpUtil.send_lan_command(baseUrl, 'POST', 'api/4/auth/login', data)

    --Handle server result
    if success and code == 200 then
      local tokenData = json.decode(table.concat(res_body)..'}') --ltn12 bug drops last  bracket
      log.info('Got token: ' ..tokenData.access_token)
      access_token = tokenData.access_token
    end
  end

  --Get programs
  local programUrl = 'api/4/program?access_token=' ..access_token
  local success, code, res_body = httpUtil.send_lan_command(baseUrl, 'GET', programUrl, '')
  if success and code == 200 then
    local programData = json.decode(table.concat(res_body)..'}') --ltn12 bug drops last  bracket

    local installedprogramCount = 0

    for programNumber, program in pairs(programData.programs) do
      local stProgramDeviceExists = false
      local stProgramDevice
      local programId = 'rainmachine-program-' ..program.uid

      for _, device in ipairs(device_list) do
        if device.device_network_id == programId then
          stProgramDeviceExists = true
          stProgramDevice = device
        end
      end

      --If this device already exists in SmartThings, update the status
      if stProgramDeviceExists then
        installedprogramCount = installedprogramCount + 1

        --Set health online
        stProgramDevice:online()
        local currentHealthStatus = stProgramDevice:get_latest_state('main', healthCapName, "healthStatus", "unknown")
        if currentHealthStatus ~= 'Online' then
          stProgramDevice:emit_event(healthCap.healthStatus('Online'))
        end

        local programStatus
        if program.status == 0 then
          programStatus = 'off'
        else
          programStatus = 'on'
        end

        local stState = stProgramDevice:get_latest_state('main', caps.switch.switch.ID, "switch", "unknown")

        if stState ~= programStatus then
          log.trace('Switch ' ..stProgramDevice.label .. ': setting status to ' ..stState)
          stProgramDevice:emit_event(caps.switch.switch(programStatus))
        end

        --Program active status
        local programActiveStatus
        if program.active == true then
          programActiveStatus = 'enabled'
        else
          programActiveStatus = 'disabled'
        end

        local stProgramActiveStatus = stProgramDevice:get_latest_state('main', activeStatusCapName, "statustext", "unknown")

        if stProgramActiveStatus ~= programActiveStatus then
          log.trace('Program active ' ..stProgramDevice.label ..' ' ..stProgramActiveStatus ..programActiveStatus)
          stProgramDevice:emit_event(activeStatusCap.statustext(programActiveStatus))
        end


      --Create new devices
      else

        local profileName

        log.info('Ready to create ' ..program.name ..' ('..programId ..') ')

        local metadata = {
          type = 'LAN',
          device_network_id = programId,
          label = program.name,
          profile = programProfile,
          manufacturer = 'rainmachine',
          model = rainMachineController.model,
          vendor_provided_label = 'rainmachineProgram',
          parent_device_id = rainMachineController.id
        }
        assert (driver:try_create_device(metadata), "failed to create device")
        installedprogramCount = installedprogramCount + 1
      end
    end

  else
    log.info('Resetting token.')
    access_token = ''
  end

  --Get zones
  local zoneUrl = 'api/4/zone?access_token=' ..access_token
  local success, code, res_body = httpUtil.send_lan_command(baseUrl, 'GET', zoneUrl, '')
  if success and code == 200 then
    local zoneData = json.decode(table.concat(res_body)..'}') --ltn12 bug drops last  bracket

    local stZoneDevice
    local installedZoneCount = 0

    for zoneNumber, zone in pairs(zoneData.zones) do
      local stZoneDeviceExists = false
      local zoneId = 'rainmachine-zone-' ..zone.uid
      --log.trace('Checking zone ' ..zoneId)

      for _, device in ipairs(device_list) do
        if device.device_network_id == zoneId then
          --log.trace('Found existing zone ' ..zoneId)
          stZoneDeviceExists = true
          stZoneDevice = device
        end
      end

      --If this device already exists in SmartThings, update the status
      if stZoneDeviceExists then
        installedZoneCount = installedZoneCount + 1

        --Set health online
        stZoneDevice:online()
        local currentHealthStatus = stZoneDevice:get_latest_state('main', healthCapName, "healthStatus", "unknown")
        if currentHealthStatus ~= 'Online' then
          stZoneDevice:emit_event(healthCap.healthStatus('Online'))
        end

        --Set default runtime
        local currentRuntime = stZoneDevice:get_latest_state('main', "towertalent27877.zoneruntime2", "runminutes", 0)
        --log.trace('current runtime ' ..currentRuntime)
        if currentRuntime == 0 then
          stZoneDevice:emit_event(zoneRuntimeCap.runminutes(5))
        end

        local zoneStatus
        if zone.state == 0 then
          zoneStatus = 'off'
        else
          zoneStatus = 'on'
        end

        local stState = stZoneDevice:get_latest_state('main', caps.switch.switch.ID, "switch", "unknown")

        --log.trace('stState ' ..stState .. ', zoneStatus ' ..zoneStatus)
        if stState ~= zoneStatus then
          log.trace('Switch ' ..stZoneDevice.label .. ': setting status to ' ..stState)
          stZoneDevice:emit_event(caps.switch.switch(zoneStatus))
        end

        local zoneMinutesRemaining = math.ceil(zone.remaining/60)
        local stRemaining = stZoneDevice:get_latest_state('main', "towertalent27877.zonetimeremaining", "minutesRemaining", 99)
        --log.trace('zone remaining ' ..zoneMinutesRemaining ..'stremaining' ..stRemaining)
        if zoneMinutesRemaining ~= stRemaining then
          log.trace('Zone ' ..stZoneDevice.label .. ': setting remaining to ' ..zoneMinutesRemaining)
          stZoneDevice:emit_event(zoneTimeRemaningCap.minutesRemaining(zoneMinutesRemaining))
        end

        local zoneTimeRemaningCap = caps['towertalent27877.zonetimeremaining']

      --Create new devices
      else

        local profileName

        log.info('Ready to create ' ..zone.name ..' ('..zoneId ..') ')

        local metadata = {
          type = 'LAN',
          device_network_id = zoneId,
          label = zone.name,
          profile = zoneProfile,
          manufacturer = 'rainmachine',
          model = rainMachineController.model,
          vendor_provided_label = 'rainmachinezone',
          parent_device_id = rainMachineController.id
        }
        assert (driver:try_create_device(metadata), "failed to create device")
        installedZoneCount = installedZoneCount + 1
      end
    end

  else
    log.info('Resetting token.')
    access_token = ''
  end

end


----------------
-- Device commands


--Zone runtime--
function command_handler.handle_zoneruntime(driver, device, command)
  device:emit_event(zoneRuntimeCap.runminutes(command.args.value))
end

--Program schedule status--
function command_handler.handle_programstatus(driver, device, command)
  commandIsPending = true
  --log.debug (string.format('%s command received: %s', command.component, command.command))
  --log.debug (command.args.value)

  local apiCommand
  if command.args.value == 'enabled' then
    apiCommand = true
  else
    apiCommand = false
  end

  local deviceId = device.device_network_id
  local requestBody= {active=apiCommand}
  local deviceType = 'program'

  local removeString = 'rainmachine%-' ..deviceType ..'%-'
  deviceId = deviceId:gsub(removeString, '')

  local baseUrl = getBaseUrl(driver) ..'/api/4/'
  local success = httpUtil.send_lan_command(baseUrl, 'POST', deviceType ..'/' ..deviceId ..'?access_token=' ..access_token, requestBody)

  --Handle result
  if success then
    log.trace('Success! Setting program schedule to ' ..command.args.value)
    commandIsPending = false
    return device:emit_event(activeStatusCap.statustext(command.args.value))
  end

  --Handle bad result
  log.error('no response from device')
  commandIsPending = false
  return false
end



--Switch--
function command_handler.switchControl(driver, device, commandParam)
  commandIsPending = true
  local command = commandParam.command
  log.trace('Sending switch command: ' ..command)

  local apiCommand = ''
  if command == 'on' then
    apiCommand = 'start'
  else
    apiCommand = 'stop'
  end

  local deviceId = device.device_network_id
  local requestBody
  local deviceType
  if string.find(device.device_network_id, "program") then
    deviceType = 'program'
  else
    deviceType = 'zone'
    local currentRuntimeMinutes = device:get_latest_state('main', "towertalent27877.zoneruntime2", "runMinutes", 65)
    requestBody = {time=currentRuntimeMinutes}
  end

  local removeString = 'rainmachine%-' ..deviceType ..'%-'
  deviceId = deviceId:gsub(removeString, '')

  local baseUrl = getBaseUrl(driver) ..'/api/4/'
  local success = httpUtil.send_lan_command(baseUrl, 'POST', deviceType ..'/' ..deviceId ..'/' ..apiCommand ..'?access_token=' ..access_token, requestBody)

  --Handle result
  if success then
    if command == 'on' then
      log.trace('Success! Setting switch to on')
      commandIsPending = false
      return device:emit_event(caps.switch.switch.on())
    else
      log.trace('Success! Setting switch to off')
      commandIsPending = false
      return device:emit_event(caps.switch.switch.off())
    end
  end

  --Handle bad result
  log.error('no response from device')
  commandIsPending = false
  return false
end


function command_handler.getControllerDevice(driver)
  local device_list = driver:get_devices() --Grab existing devices
  for _, device in ipairs(device_list) do
    if device.device_network_id == controllerId then
      return driver.get_device_info(driver, device.id)
    end
  end
end

function getLoginDetails(driver)

  --Email/password are stored on the controller device. Find it.
  local rainMachineController
  local device_list = driver:get_devices() --Grab existing devices
  local deviceExists = false
  for _, device in ipairs(device_list) do
    if device.device_network_id == controllerId then
      rainMachineController = driver.get_device_info(driver, device.id)
    end
  end
  return {email=rainMachineController.preferences.email, password=rainMachineController.preferences.password}
end

function getBaseUrl(driver)

  --IP/Port are stored on the controller device. Find it.
  local rainMachineController
  local device_list = driver:get_devices() --Grab existing devices
  local deviceExists = false
  for _, device in ipairs(device_list) do
    if device.device_network_id == controllerId then
      rainMachineController = driver.get_device_info(driver, device.id)
    end
  end
  return 'http://' ..rainMachineController.preferences.serverIp ..':' ..rainMachineController.preferences.serverPort
end

return command_handler