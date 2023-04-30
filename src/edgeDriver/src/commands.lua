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
local myqStatusCap = caps['towertalent27877.myqstatus']
local myqServerAddressCap = caps['towertalent27877.bridgeServerStatus']
local healthCap = caps['towertalent27877.health']

--Device type info
local controllerId = 'RainMachineController'
local programProfile = 'RainMachineProgram.v1'
local zoneProfile = 'RainMachineZone.v1'

local myqDoorFamilyName = 'garagedoor'
local myqLampFamilyName = 'lamp'
local doorDeviceProfile = 'MyQDoor.v1'
local lampDeviceProfile = 'MyQLamp.v1'
local lockDeviceProfile = 'MyQLock.v1'

--Prevent spamming bad auth info
local authIsBad = false
local access_token = ''

--Allow for occasional MyQ errors
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

  --Update controller server address
  -- local currentControllerServerAddress = rainMachineController:get_latest_state('main', "towertalent27877.myqserveraddress", "serverAddress", "unknown")
  -- local serverAddress = "Pending"
  -- if rainMachineController.model ~= '' then
  --   serverAddress = rainMachineController.model
  -- end
  -- if currentControllerServerAddress ~= serverAddress then
  --   rainMachineController:emit_event(myqServerAddressCap.serverAddress(serverAddress))
  -- end

--Handle blank auth info
  if rainMachineController.preferences.password == '' then
    local defaultAuthStatus = 'Awaiting credentials'
    local currentStatus = rainMachineController:get_latest_state('main', "towertalent27877.myqstatus", "statusText", "unknown")
    if currentStatus ~= defaultAuthStatus then
      log.info('No credentials yet. Waiting.' ..currentStatus)
      rainMachineController:emit_event(myqStatusCap.statusText(defaultAuthStatus))
    end
    consecutiveFailureCount = 100 --Force immediate display of errors once auth is entered
    return
  end

  --Handle missing myq server URL - try and broadcast to auto-discover
  -- if rainMachineController.model == '' then
  --   doBroadcast(driver, callingDevice, rainMachineController)
  --   return
  -- end
  local baseUrl = 'http://' ..rainMachineController.preferences.serverIp ..':' ..rainMachineController.preferences.serverPort

  --Call out to RM device to get access token if needed
  if access_token == '' then

    --local loginInfo = {pwd=rainMachineController.preferences.password}
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
    local stProgramDeviceExists = false
    local stProgramDevice
    local installedprogramCount = 0

    for programNumber, program in pairs(programData.programs) do
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
        local currentHealthStatus = stProgramDevice:get_latest_state('main', "towertalent27877.health", "healthStatus", "unknown")
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

      --Create new devices
      else

        local profileName

        log.info('Ready to create ' ..program.name ..' ('..programId ..') ')

        local metadata = {
          type = 'LAN',
          device_network_id = programId,
          label = program.name ..' program',
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
    local stZoneDeviceExists = false
    local stZoneDevice
    local installedZoneCount = 0

    for zoneNumber, zone in pairs(zoneData.zones) do
      local zoneId = 'rainmachine-zone-' ..zone.uid

      for _, device in ipairs(device_list) do
        if device.device_network_id == zoneId then
          stZoneDeviceExists = true
          stZoneDevice = device
        end
      end

      --If this device already exists in SmartThings, update the status
      if stZoneDeviceExists then
        installedZoneCount = installedZoneCount + 1

        --Set health online
        stZoneDevice:online()
        local currentHealthStatus = stZoneDevice:get_latest_state('main', "towertalent27877.health", "healthStatus", "unknown")
        if currentHealthStatus ~= 'Online' then
          stZoneDevice:emit_event(healthCap.healthStatus('Online'))
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

      --Create new devices
      else

        local profileName

        log.info('Ready to create ' ..zone.name ..' ('..zoneId ..') ')

        local metadata = {
          type = 'LAN',
          device_network_id = zoneId,
          label = zone.name ..' zone',
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

--Door--
function command_handler.doorControl(driver, device, commandParam)
  commandIsPending = true
  local command = commandParam.command
  log.trace('Sending door command: ' ..command)
  local success = httpUtil.send_lan_command(device.model ..'/' ..device.device_network_id, 'POST', 'control', {command=command, auth=getLoginDetails(driver)})

  local pendingStatus
  if command == 'open' then
    pendingStatus = 'opening'
  else
    pendingStatus = 'closing'
  end

  if success then
    return device:emit_event(caps.doorControl.door(pendingStatus))
  end
  log.error('no response from device')
  return device:emit_event(myqStatusCap.statusText(command ..' command failed'))
end


--Switch--
function command_handler.switchControl(driver, device, commandParam)
  local command = commandParam.command
  log.trace('Sending switch command: ' ..command)

  --If this is a door, jump over to open/close
  if (device.vendor_provided_label == doorDeviceProfile) then
    if command == 'on' then
      return command_handler.doorControl(driver, device, {command='open'})
    else
      return command_handler.doorControl(driver, device, {command='close'})
    end
  end

  --Send it
  local success = httpUtil.send_lan_command(device.model ..'/' ..device.device_network_id, 'POST', 'control', {command=command, auth=getLoginDetails(driver)})

  --Handle result
  if success then
    if command == 'on' then
      return device:emit_event(caps.switch.switch.on())
    else
      return device:emit_event(caps.switch.switch.off())
    end
  end

  --Handle bad result
  log.error('no response from device')
  device:emit_event(myqStatusCap.statusText(command ..' command failed'))
  return false
end

--Lock--
function command_handler.lockControl(driver, device, commandParam)
  commandIsPending = true
  local command = commandParam.command
  log.trace('Sending lock command: ' ..command)

  --Translate to door commands
  local doorCommand
  if (command == 'unlock') then
    doorCommand = 'open'
  else
    doorCommand = 'close'
  end

  --Send it
  local success = httpUtil.send_lan_command(device.model ..'/' ..device.device_network_id, 'POST', 'control', {command=doorCommand, auth=getLoginDetails(driver)})

  --Handle result
  if success then
    commandIsPending = true
    device:emit_event(myqStatusCap.statusText(command ..' in progress..'))
    if command == 'unlock' then
      return device:emit_event(caps.lock.lock('unlocked'))
    else
      return device:emit_event(caps.lock.lock('locked'))
    end
  end

  --Handle bad result
  commandIsPending = false
  log.error('no response from device')
  device:emit_event(myqStatusCap.statusText(command ..' command failed'))
  return device:emit_event(caps.lock.lock("unknown"))
end

function command_handler.getControllerDevice(driver)
  local device_list = driver:get_devices() --Grab existing devices
  for _, device in ipairs(device_list) do
    if device.device_network_id == 'rainMachineController' then
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
    if device.device_network_id == 'rainMachineController' then
      rainMachineController = driver.get_device_info(driver, device.id)
    end
  end
  return {email=rainMachineController.preferences.email, password=rainMachineController.preferences.password}
end

return command_handler