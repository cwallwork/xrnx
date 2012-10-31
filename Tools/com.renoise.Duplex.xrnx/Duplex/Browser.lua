--[[----------------------------------------------------------------------------
-- Duplex.Browser
----------------------------------------------------------------------------]]--


local NOT_AVAILABLE_POSTFIX = " [N/A]"
local RUNNING_POSTFIX = " (running)"


--==============================================================================

-- The Browser class shows and instantiates registered device configurations
-- and shows the virtual UI for them. More than one configuration can be 
-- active and running for multiple devices.

class 'Browser'

--------------------------------------------------------------------------------

--- Initialize the Browser class
-- @param initial_configuration (Table) set to this configuration 
-- @param start_configuration (Boolean) true to start the application

function Browser:__init(initial_configuration, start_configuration)
  TRACE("Browser:__init")

  
  ---- properties

  -- list of duplex device configuration definitions
  self._available_configurations = duplex_configurations

  -- processes is a table containing BrowserProcess processes
  self._processes = table.create()
  
  -- string, selected device display-name 
  self._device_name = nil 
  -- string, selected configuration for the current device
  self._configuration_name = nil

  -- dump midi information to console (debug option)
  self._dump_midi = false

  -- true while updating the GUI from within the internal browser functions, 
  -- to avoid doubling updates when the changes are not fired from the GUI
  self._suppress_notifiers = false

  -- set when we temporarily have selected "None" as device, 
  -- and want to revert the list choice 
  self._requested_device = nil
  
  -- cast these as standard types instead of Observable-X types,
  -- as the socket will only accept basic string & numbers as arguments
  local osc_host = duplex_preferences.osc_server_host.value
  local osc_port = duplex_preferences.osc_server_port.value

  -- the OSC client takes care of sending internally routed notes
  -- to Renoise (not created if host/port is not defined)
  self._osc_client = OscClient(osc_host,osc_port)
  
  -- the voice manager is handling triggered note messages
  -- (needs the osc_client)
  self._voice_mgr = OscVoiceMgr()

  ---- components
  
  -- view builder that we do use for all our views
  self._vb = renoise.ViewBuilder()
  
  -- referenc eto the main dialog that we create
  self._dialog = nil
  

  ---- build the GUI

  self:_create_content_view()

  
  ---- activate default config

  -- select none by default
  self:set_device("None")
  
  -- as last step, apply optional arguments (autostart devices)
  if (initial_configuration) then
    self:set_configuration(initial_configuration, start_configuration)
  end


  ---- attach to configuration settings
  
  -- MIDI port setup changed
  renoise.Midi.devices_changed_observable():add_notifier(
    Browser._available_device_ports_changed, self
  )
  
  -- MIDI port configs changed
  for _,config in pairs(duplex_configurations) do
    local settings = configuration_settings(config)
    if (settings.device_port_out) then
      settings.device_port_out:add_notifier(
        Browser._device_ports_changed, self
      )
    end
    if (settings.device_port_in) then
      settings.device_port_in:add_notifier(
        Browser._device_ports_changed, self
      )
    end
  end    
end


--------------------------------------------------------------------------------

--- Activate and shows the dialog, or bring the existing one to front

function Browser:show()
  TRACE("Browser:show()")
  
  if (not self._dialog or not self._dialog.visible) then
    assert(self._content_view, "Internal Error. Please report: " .. 
      "browser always needs a valid content view")

    -- switch configuration using the function keys
    local function keyhandler(dialog, key)
      local fkey = (string.match(key.name,"f([%d]+)"))
      if (key.modifiers=="") and (fkey~=nil) then
        fkey = fkey *1
        local config_list = 
          self:_available_configurations_for_device(self._device_name)
        if (config_list[fkey]) then
          self:set_configuration(config_list[fkey], true)
        end
      else
        local notify_main_window = true
        for _,process in ipairs(self._processes) do
          if (process:control_surface_visible()) then
            for __,app in ipairs(process._applications) do
              if not app:on_keypress(key) then
                notify_main_window = false
              end
            end
          end
        end
        if notify_main_window then
          return key
        end
      end
    end

    self._dialog = renoise.app():show_custom_dialog(
      "Duplex Browser", self._content_view,keyhandler)
  else
    self._dialog:show()
  end
end

--------------------------------------------------------------------------------

--- Hide the dialog

function Browser:hide()
  TRACE("Browser:hide()")

  if (self._dialog and self._dialog.visible) then
    self._dialog:close()
  end

  self._dialog = nil

end


--------------------------------------------------------------------------------

--- Forward idle notifications to all active processes

function Browser:on_idle()
  -- TRACE("Browser:on_idle()")
  
  for _,process in pairs(self._processes) do
    process:on_idle()
  end

  -- 
  if self._requested_device then
    self._requested_device = nil
    self:set_device(self._device_name)
  end

end


--------------------------------------------------------------------------------

--- Forward new document notifications to all active processes

function Browser:on_new_document()
  TRACE("Browser:on_new_document()")

  for _,process in pairs(self._processes) do
    process:on_new_document()
  end
end


--------------------------------------------------------------------------------

--- Forward released document notifications to all active processes

function Browser:on_release_document()
  TRACE("Browser:on_new_document()")

  for _,process in pairs(self._processes) do
    process:on_release_document()
  end
end


--------------------------------------------------------------------------------

--- Return a list of valid devices (plus a "None" option)
-- existing devices (ones that we found MIDI ports for) are listed first,
-- all others are listed as (N/A) to indicate that they are not present
-- in the users device setup
-- @return (Table) list of device names

function Browser:available_devices()

  -- devices that are installed on this system 
  local installed_devices = table.create()
  
  local input_devices = table.create(renoise.Midi.available_input_devices())
  local output_devices = table.create(renoise.Midi.available_output_devices())
  
  for _,config in pairs(self._available_configurations) do
    local settings = configuration_settings(config)
    
    local device_port_in = (settings.device_port_in.value ~= "") and 
      settings.device_port_in.value or config.device.device_port_in
      
    local device_port_out = (settings.device_port_out.value ~= "") and 
      settings.device_port_out.value or config.device.device_port_out
  
    local display_name = config.device.display_name
    
    if (input_devices:find(device_port_in) and 
        output_devices:find(device_port_out) and 
        not installed_devices:find(display_name)) 
    then
      installed_devices:insert(display_name)
    end
  end
  
  -- all others that are available in duplex but could not be found
  local remaining_devices = table.create()
  
  for _,config in pairs(self._available_configurations) do
    local display_name = config.device.display_name
    if (not installed_devices:find(display_name) and
        not remaining_devices:find(display_name .. NOT_AVAILABLE_POSTFIX))
    then
      remaining_devices:insert(display_name .. NOT_AVAILABLE_POSTFIX)
    end
  end

  -- build the final list, prepending "none"
  local result = table.create{ "None" }
  
  installed_devices:sort()
  for _,device in pairs(installed_devices) do
    result:insert(device)
  end
  
  remaining_devices:sort()
  for _,device in pairs(remaining_devices) do
    result:insert(device)
  end
  
  return result
end


--------------------------------------------------------------------------------

--- Change the active input device:
-- instantiates a new device, using the first avilable configuration for it,
-- or reusing an already running configuration
-- @param device_display_name (string) device display-name, without postfix
-- @param configuration_hint (optional table) configuration that should be 
-- used to instantiate the device. when nil, a default one is selected from the 
-- available device configs

function Browser:set_device(device_display_name, configuration_hint)
  TRACE("Browser:set_device("..device_display_name..")")
  
    
  ---- activate the device with its default or existing config
  
  if (self._device_name ~= device_display_name) then
    
    self._device_name = self:_strip_postfixes(device_display_name)
    self._configuration_name = "None"
    
    if (device_display_name == "None") then
      TRACE("Browser:releasing all processes")
      
      -- release all devices & applications
      while (not self._processes:is_empty()) do
        self._processes[#self._processes]:invalidate()
        self._processes:remove(#self._processes)
      end
      
      -- make sure all configuration settings are also cleared
      self:set_configuration(nil)
    
    else
      TRACE("Browser:assigning new process")
      
      assert(configuration_hint == nil or 
        configuration_hint.device.display_name == device_display_name, 
        "Internal Error. Please report: invalid device configuration hint")
        
      local configuration = configuration_hint or nil
          
      -- use an already running process by default
      if (not configuration) then
        for _,process in pairs(self._processes) do
          local process_device_name = process.configuration.device.display_name
          if (process_device_name == device_display_name) then
            configuration = process.configuration
            break
          end
        end
      end
      
      -- else the first listed one for the device
      if (not configuration) then
        for _,config in pairs(self._available_configurations) do 
          if (device_display_name == config.device.display_name) then
            configuration = config
            break
          end
        end
      end
      
      assert(configuration, ("Internal Error. Please report: " ..
        "found no configuration for device '%s'"):format(
        device_display_name))

      -- there may be no configs for the device
      self:set_configuration(configuration)
    end
  end
  
  ---- update the GUI, in case this function was not fired from the GUI

  local suppress_notifiers = self._suppress_notifiers
  self._suppress_notifiers = true

  local available_configuration_names = 
    self:_available_configuration_names_for_device(self._device_name)

  self._vb.views.dpx_browser_configurations.items = 
    available_configuration_names


  local index = self:_device_index_by_name(self._device_name)
  self._vb.views.dpx_browser_input_device.value = index
  
  self:_decorate_device_list()

  self._suppress_notifiers = suppress_notifiers
end


--------------------------------------------------------------------------------

--- Return list of valid configurations for the given device 
-- @param device_name (String) the device name

function Browser:available_configurations(device_name)
  TRACE("Browser:available_configurations:",device_name)
  
  return self:_available_configurations_for_device(device_name)
end


--------------------------------------------------------------------------------

--- Determine if the given config is instantiated and running
-- @param configuration (Table) the configuration to check
-- @return (Boolean) true if config is running

function Browser:configuration_running(configuration)
  TRACE("Browser:configuration_running:",configuration.name)
  
  for _,process in pairs(self._processes) do
    if (process:matches_configuration(configuration)) then
      return process:running()
    end
  end
  
  return false
end

--------------------------------------------------------------------------------

--- Activate the previous configuration (if active, has previous)

function Browser:set_previous_configuration()
  TRACE("Browser:set_previous_configuration()")
  if not self._configuration_name or not self._device_name then
    return
  end
  local available_configuration_names = 
    self:_available_configuration_names_for_device(self._device_name)
  for config_idx, config_name in ripairs(available_configuration_names) do
    if (config_name == self._configuration_name) then
      if (config_idx>1) then
        local config_list = 
          self:_available_configurations_for_device(self._device_name)
        local start_running = true
        self:set_configuration(config_list[config_idx-1], start_running)
        return
      end
    end
  end
  
end

--------------------------------------------------------------------------------

--- Check if previous configuration exist
-- @return (Boolean)

function Browser:has_previous_configuration()
  TRACE("Browser:has_previous_configuration()")
  if not self._configuration_name or not self._device_name then
    return
  end
  local available_configuration_names = 
    self:_available_configuration_names_for_device(self._device_name)
  for config_idx, config_name in ripairs(available_configuration_names) do
    if (config_name == self._configuration_name) then
      local config_list = 
        self:_available_configurations_for_device(self._device_name)
      return config_list[config_idx-1]
    end
  end
      
end


--------------------------------------------------------------------------------

--- Activate the next configuration (if active, has next)

function Browser:set_next_configuration()
  TRACE("Browser:set_next_configuration()")
  if not self._configuration_name or not self._device_name then
    return
  end
  local available_configuration_names = 
    self:_available_configuration_names_for_device(self._device_name)
  for config_idx, config_name in ipairs(available_configuration_names) do
    if (config_name == self._configuration_name) then
      if (config_idx<#available_configuration_names) then
        local config_list = 
          self:_available_configurations_for_device(self._device_name)
        local start_running = true
        self:set_configuration(config_list[config_idx+1], start_running)
        return
      end
    end
  end
      
end

--------------------------------------------------------------------------------

--- Check if next configuration exist
-- @return (Boolean)

function Browser:has_next_configuration()
  TRACE("Browser:has_next_configuration()")
  if not self._configuration_name or not self._device_name then
    return
  end
  local available_configuration_names = 
    self:_available_configuration_names_for_device(self._device_name)
  for config_idx, config_name in ipairs(available_configuration_names) do
    if (config_name == self._configuration_name) then
      local config_list = 
        self:_available_configurations_for_device(self._device_name)
      return config_list[config_idx+1]
    end
  end
      
end

--------------------------------------------------------------------------------

--- Activate a configuration based on the provided index  
-- (silently fails if no configuration exist at that index, or already active)
-- @param idx (Number)

function Browser:goto_configuration(idx)
  TRACE("Browser:goto_configuration()",idx)
  if not self._configuration_name or not self._device_name then
    return
  end
  local available_configuration_names = 
    self:_available_configuration_names_for_device(self._device_name)

  if (idx > #available_configuration_names) then
    -- configuration does not exist
    return 
  end

  local cfg_idx = self:get_configuration_index(self._configuration_name)
  if (cfg_idx == idx) then
    -- configuration is already active 
    return
  end

  local config_list = 
    self:_available_configurations_for_device(self._device_name)

  local start_running = true
  self:set_configuration(config_list[idx], start_running)

end


--------------------------------------------------------------------------------

--- Retrieve the index for the configuration matching the provided name
-- @return Number or nil

function Browser:get_configuration_index(cfg_name)
  TRACE("Browser:get_configuration_index()",cfg_name)
  if not self._configuration_name or not self._device_name then
    return
  end
  local available_configuration_names = 
    self:_available_configuration_names_for_device(self._device_name)
  for config_idx, config_name in ipairs(available_configuration_names) do
    if (config_name == cfg_name) then
      return config_idx
    end
  end

end

--------------------------------------------------------------------------------

--- Activate a new configuration for the currently active device
-- @param configuration (Table)
-- @param start_running (Boolean)

function Browser:set_configuration(configuration, start_running)
  TRACE("Browser:set_configuration:", configuration and 
    configuration.name or "None")
  
  start_running = start_running or false

  -- passing no configuration should deinitialize and update the GUI only
  if (configuration ~= nil) then
  
    ---- first make sure the configs device is selected
    
    self:set_device(configuration.device.display_name, configuration)
    
  
    ---- then apply the config, if necessary  
    
    if (self._configuration_name ~= configuration.name) then
      self._configuration_name = configuration.name
      
      -- switching to an existing running process?
      local existing_process = nil
      for _,process in pairs(self._processes) do
        if (process:matches_configuration(configuration)) then
          existing_process = process
          break
        end
      end
      
      if (existing_process) then
        TRACE("Browser:switching to existing process")
            
        -- hide previous instantiated control-maps
        for _,process in pairs(self._processes) do
          if (process ~= existing_process) then
            if (process:control_surface_visible()) then
              process:hide_control_surface()
            end
          end
        end
        
        -- and show the new one
        existing_process:show_control_surface(
          self._vb.views.dpx_browser_device_ui_row)
  
      else
        TRACE("Browser:creating new process")
    
        -- remove already running processes for this device
        for process_index,process in ripairs(self._processes) do
          local process_device_name = process.configuration.device.display_name
          if (process_device_name == self._device_name) then
            process:invalidate()
            self._processes:remove(process_index)
            break
          end
        end
      
        -- hide previous instantiated control-maps from other devices
        for _,process in pairs(self._processes) do
          if (process:control_surface_visible()) then
            process:hide_control_surface()
          end
        end
        
        -- create a new process 
        local new_process = BrowserProcess(self)
        
        if (new_process:instantiate(configuration)) then
          
          -- apply debug options
          new_process:set_dump_midi(self._dump_midi)
          
          -- show it (add the control map GUI to the browser)
          new_process:show_control_surface(
            self._vb.views.dpx_browser_device_ui_row)
  
          -- and add it to the list of active processes
          self._processes:insert(new_process)
        
        else
          self._configuration_name = "None" 
        end
      end
    end
  
  else
  
    self:set_device("None")
    self._configuration_name = "None" 
  end
  

  ---- validate the process list
  
  for _,process in pairs(self._processes) do
    assert(process:instantiated(), "Internal Error. Please report: " ..
      "should only have instantiated processes listed")
  end


  ---- apply start options
  
  if (self:_current_process() and start_running) then
    self:start_current_configuration(start_running)
  end
  
    
  ---- update the GUI, in case this function was not fired from the GUI

  local suppress_notifiers = self._suppress_notifiers
  self._suppress_notifiers = true

  local index = self:_configuration_index_by_name(self._configuration_name)
  self._vb.views.dpx_browser_configurations.value = index
  
  local has_device = (self:_current_process() ~= nil)
    
  self._vb.views.dpx_browser_configuration_row.visible = has_device
  self._vb.views.dpx_browser_device_settings.visible = has_device
  self._vb.views.dpx_browser_device_ui_row.visible = has_device
  self._vb.views.dpx_browser_autostart_row.visible = has_device
  self._vb.views.dpx_browser_device_info_text.visible = has_device

  self._vb.views.dpx_browser_autostart_checkbox.value = 
    self:_configuration_autostart_enabled()
      
  local process = self:_current_process()

  self._vb.views.dpx_browser_configuration_running_checkbox.value = 
    (process and process:running()) or false

  --self._vb.views.dpx_browser_device_ui_row:resize()
  --self._vb.views.dpx_browser_rootnode:resize()

  self:_update_device_description()
    
  self:_decorate_device_list()
  self:_decorate_configuration_list()

  self._suppress_notifiers = suppress_notifiers
end


--------------------------------------------------------------------------------

--- Start current configuration (and all apps within it)

function Browser:start_current_configuration(start_running)
  TRACE("Browser:start_configuration()",start_running)
  
  local process = self:_current_process()
  if (process and not process:running()) then
    process:start(start_running)
  end

  -- adjust the GUI, in case this was not fired from the GUI
  local suppress_notifiers = self._suppress_notifiers
  self._suppress_notifiers = true
  
  self._vb.views.dpx_browser_configuration_running_checkbox.value = 
   (process and process:running()) or false

  self:_decorate_device_list()
  self:_decorate_configuration_list()
  
  self._suppress_notifiers = suppress_notifiers
end
  
  
--------------------------------------------------------------------------------

--- Stop current configuration (and all apps within it)

function Browser:stop_current_configuration()
  TRACE("Browser:stop_configuration()")

  local process = self:_current_process()
  if (process and process:running()) then
    process:stop()
  end

   -- adjust the GUI, in case this was not fired from the GUI
  local suppress_notifiers = self._suppress_notifiers
  self._suppress_notifiers = true
  
  self._vb.views.dpx_browser_configuration_running_checkbox.value = 
   (process and process:running()) or false

  self:_decorate_device_list()
  self:_decorate_configuration_list()
  
  self._suppress_notifiers = suppress_notifiers
end


--------------------------------------------------------------------------------

--- Check if we should write debug data to the std out (console)
-- @return (Boolean) 

function Browser:dump_midi()
  return self._dump_midi
end


--------------------------------------------------------------------------------

--- Set the MIDI dump status
-- @param dump (Boolean)

function Browser:set_dump_midi(dump)
  self._dump_midi = dump
  for _,process in pairs(self._processes) do
    process:set_dump_midi(dump)
  end
end


--------------------------------------------------------------------------------
-------  private helper functions
--------------------------------------------------------------------------------

--- Remove NOT_AVAILABLE_POSTFIX and RUNNING_POSTFIX from the passed name
-- @param name (String)
-- @return (String) the name without decoration

function Browser:_strip_postfixes(name)
  --TRACE("Browser:_strip_postfixes", name)

  local plain_find = true
  
  if (name:find(RUNNING_POSTFIX, 1, plain_find)) then
    name = name:sub(1, #name - #RUNNING_POSTFIX)
  end
  
  if (name:find(NOT_AVAILABLE_POSTFIX, 1, plain_find)) then
    name = name:sub(1, #name - #NOT_AVAILABLE_POSTFIX)
  end
  
  return name
end


--------------------------------------------------------------------------------

--- Check if any processes are running
-- @return (Boolean) true when at least one process is instantiated and running

function Browser:_process_running()
  --TRACE("Browser:_process_running()")

  for _,process in pairs(self._processes) do
    if (process:running()) then
      return true
    end
  end

  return false
end


--------------------------------------------------------------------------------

--- Retrieve the current process
-- @return (BrowserProcess object or nil)

function Browser:_current_process()
  TRACE("Browser:_current_process")

  for _,process in pairs(self._processes) do
    if (process:matches(self._device_name, self._configuration_name)) then
      return process
    end
  end
  
  return nil
end


--------------------------------------------------------------------------------

--- Retrieve index of the given device display name
-- @param device_display_name (String) 
-- @return (Number or nil)

function Browser:_device_index_by_name(device_display_name)
  TRACE("Browser:_device_index_by_name", device_display_name)
  
  if (device_display_name == "None") then
    return 1
  
  else
    device_display_name = self:_strip_postfixes(device_display_name)
  
    local popup = self._vb.views.dpx_browser_input_device
    for index, name in pairs(popup.items)do
      if (device_display_name == self:_strip_postfixes(name)) then
        return index
      end
    end
  
    return nil
  end
end


--------------------------------------------------------------------------------

--- Retrieve index of the given configuration name
-- @param config_name (String) 
-- @return (Number or nil)

function Browser:_configuration_index_by_name(config_name)
  TRACE("Browser:_configuration_index_by_name", config_name)
  
  if (config_name == "None") then
    return 1

  else
    config_name = self:_strip_postfixes(config_name)
    
    local popup = self._vb.views.dpx_browser_configurations
    for index, name in pairs(popup.items)do
      if (config_name == self:_strip_postfixes(name)) then
        return index
      end
    end
  
    return nil
  end
end


--------------------------------------------------------------------------------

--- Retrieve list of configurations present for the provided device
-- @param device_display_name (String) device_display_name
-- @return (Table) list of configurations

function Browser:_available_configurations_for_device(device_display_name)
  TRACE("Browser:_available_configurations_for_device:", device_display_name)

  local configurations = table.create()
  
  for _,config in pairs(self._available_configurations) do 
    if (config.device.display_name == device_display_name) then
      configurations:insert(config)
    end
  end
  
  return configurations
end


--------------------------------------------------------------------------------

--- Retrieve list of configuration-names present for the provided device
-- @param device_display_name (String) device_display_name
-- @return (Table) list of configuration names

function Browser:_available_configuration_names_for_device(device_display_name)
  TRACE("Browser:_available_configuration_names_for_device:", device_display_name)

  local config_names = table.create()
  
  local available_configurations = 
    self:_available_configurations_for_device(device_display_name)

  for _,config in pairs(available_configurations) do 
    config_names:insert(config.name)
  end
  
  return config_names
end


--------------------------------------------------------------------------------

--- Add/remove the "running" postfix for relevant devices.
-- called when we start/stop apps, and choose a device/config

function Browser:_decorate_device_list()
  TRACE("Browser:_decorate_device_list:")

  local device_list = self:available_devices()
  
  for index,device_name in pairs(device_list) do
    device_name = self:_strip_postfixes(device_name) 
    
    local running = false
    for _,process in pairs(self._processes) do
      if (process.configuration.device.display_name == device_name) then
        if (process:running()) then
          running = true
          break
        end
      end
    end
  
    if (running) then
      device_list[index] = device_list[index] .. RUNNING_POSTFIX
    end
  end

  self._vb.views.dpx_browser_input_device.items = device_list
end


--------------------------------------------------------------------------------

--- Add/remove the "running" postfix for relevant configurations.
-- called when we start/stop apps, and choose a device/config

function Browser:_decorate_configuration_list()
  TRACE("Browser:_decorate_configuration_list:")

  local configuration_names = 
    self:_available_configuration_names_for_device(self._device_name)
  
  local config_list = table.create()

  for _,configuration_name in pairs(configuration_names) do
    local running = false
    for _,process in pairs(self._processes) do
      if (process:matches(self._device_name, configuration_name)) then
        running = process:running()
        break
      end
    end
  
    config_list:insert(running and 
      (configuration_name .. RUNNING_POSTFIX) or
      (configuration_name)
    )
  end

  self._vb.views.dpx_browser_configurations.items = config_list
end


--------------------------------------------------------------------------------

--- Show info about the current device, as specified in the control-map 

function Browser:_update_device_description() 

  local active_process = self:_current_process()      
  local info_text_view = self._vb.views.dpx_browser_device_info_text
  
  if (active_process == nil) then
    info_text_view.text = ""

  else
    local author, description
    
    -- get the author and description fields from the controlmap
    if (active_process.device.control_map) then

      local definition = active_process.device.control_map.definition
      if (definition and #definition > 0) then

        for _,tag in pairs(definition[1]) do
          if (tag.label and tag.label == "Author") then
            author = tag[1]
          elseif (tag.label and tag.label == "Description") then
            description = tag[1]
          end
        end
      end
    end

    local paragraphs = table.create()

    if (author) then
      paragraphs:insert("Author: " .. author)
    end

    if (description) then
      paragraphs:insert("Description: " .. description)
    end

    info_text_view.paragraphs = paragraphs
  end
  
  -- fill up the entire dialog width
  info_text_view.width = math.max(
    self._vb.views.dpx_browser_input_device_row.width, 
    self._vb.views.dpx_browser_device_ui_row.width)

  local text_rows = math.min(5, math.max(1, #info_text_view.paragraphs))
  if (text_rows ~= math.floor(info_text_view.height / 16)) then
    self._vb.views.dpx_browser_device_info_text.height = text_rows*16
    
    --self._vb.views.dpx_browser_device_ui_row:resize()
    --self._vb.views.dpx_browser_rootnode:resize()
  end
end


--------------------------------------------------------------------------------

--- Check whether the current configuration should be autostarted
-- return (Boolean) 

function Browser:_configuration_autostart_enabled()

  local process = self:_current_process()  

  if (process) then
    return process.settings.autostart.value

  else
    return false
  end
    
end


--------------------------------------------------------------------------------

--- Add the current configuration to the autostart prefs

function Browser:_enable_configuration_autostart()
  TRACE("Browser:_enable_configuration_autostart()")

  local process = self:_current_process()

  if (process) then
    -- disable autostart for all other configs this device has first
    local device_configs = 
      self:_available_configurations_for_device(self._device_name)

    for _,config in pairs(device_configs) do
      local settings = configuration_settings(config)
      settings.autostart.value = false
    end
        
    -- then enable autostart for the current config
    process.settings.autostart.value = true
  end
end
  

--------------------------------------------------------------------------------

--- Remove the current configuration from the autostart prefs

function Browser:_disable_configuration_autostart()
  TRACE("Browser:_disable_configuration_autostart()")
  
  local process = self:_current_process() 

  if (process) then
    process.settings.autostart.value = false
  end
end



--------------------------------------------------------------------------------

--- Notifier, fired when device input or output port setting changed

function Browser:_available_device_ports_changed()
  TRACE("Browser:_available_device_ports_changed()")

  -- reactivate all devices that are now available but were not available before  
  local input_devices = table.create(renoise.Midi.available_input_devices())
  local output_devices = table.create(renoise.Midi.available_output_devices())
  
  for _,process in pairs(self._processes) do
    if (process:running()) then
      local device = process.device
      
      if (device.protocol == DEVICE_MIDI_PROTOCOL) then
        local now_available = (input_devices:find(device.port_in) ~= nil) and 
          (output_devices:find(device.port_out) ~= nil)
        
        local ports_active = (device.midi_in ~= nil) and
          (device.midi_out ~= nil)
            
        if (now_available and not ports_active) then
          -- ports are now available. reactivate the device
          
          device:release()
          device:open()

          process:clear_display()
        
        elseif (not now_available and ports_active) then

          -- ports no longer available. release the MIDI device ports
          device:release()
        end
        
      end
    end
  end

  -- and update the device list GUI
  self:_device_ports_changed()
end


--------------------------------------------------------------------------------

--- Notifier, fired when device input or output port setting changed

function Browser:_device_ports_changed()

  local suppress_notifiers = self._suppress_notifiers
  self._suppress_notifiers = true

  -- update (NA) postfixes, which depend on the device port settings
  self:_decorate_device_list()

  local index = self:_device_index_by_name(self._device_name)
  self._vb.views.dpx_browser_input_device.value = index

  self._suppress_notifiers = suppress_notifiers
end



--------------------------------------------------------------------------------

--- Build and assign the application dialog

function Browser:_create_content_view()
  
  local vb = self._vb
  
  local txt_device    = "This list contains the supported devices."
                      .."\nSelect 'none' to release all active devices,"

  local txt_config    = "This list contains the device configurations."
                      .."\nClick on 'Settings' to display options"

  local txt_settings  = "Click to open device/application settings"

  local txt_autostart = "When enabled, this configuration will be launched"
                      .."\nautomatically, every time Renoise starts."

  local txt_running   = "Toggle the running status of this configuration."

  self._content_view = vb:column{
    id = 'dpx_browser_rootnode',
    margin = DEFAULT_MARGIN,
    spacing = DEFAULT_SPACING,
    width = 400,
    
    -- device chooser
    vb:row {
      id = 'dpx_browser_input_device_row',
      vb:text {
        text = "Device",
        width = 50,
      },
      vb:popup {
        id = 'dpx_browser_input_device',
        tooltip = txt_device,
        items = self:available_devices(),
        width = 200,
        notifier = function(e)
          if (not self._suppress_notifiers) then
            local device_list = self:available_devices()
            
            if (e == 1 and self:_process_running()) then -- "None"
              local choice = renoise.app():show_prompt("", 
                "This will close all open devices. Are you sure?", 
                {"OK","Cancel"})
                    
              if (choice == "Cancel") then
                -- revert to the last used device in idle loop
                -- (otherwise, we would trigger a notifier feedback)
                self._requested_device = self._device_name
              else
                self:set_device(self:_strip_postfixes(device_list[e]))
              end
            else
              self:set_device(self:_strip_postfixes(device_list[e]))
            end
          end
        end
      },
      vb:button {
        id = 'dpx_browser_device_settings',
        tooltip = txt_settings,
        text = "Settings",
        width = 60,
        notifier = function()
          local process = self:_current_process()
          if (process) then
            --process.device:show_settings_dialog(process)
            process:show_settings_dialog()
            return
          end

        end
      },
    },

    -- configuration chooser
    vb:row {
      id = 'dpx_browser_configuration_row',
      visible = false,
      vb:text {
          text = "Config.",
          width = 50,
      },
      vb:popup {
        id = 'dpx_browser_configurations',
        tooltip = txt_config,
        items = table.create{"None"},
        value = 1,
        width = 200,
        notifier = function(e)
          if (not self._suppress_notifiers) then
            
            local config_list = 
              self:_available_configurations_for_device(self._device_name)
            
            -- when the old config was running, run the new one as well
            local auto_start = (self:_current_process() and
              self:_current_process():running())
            
            self:set_configuration(config_list[e], auto_start)
          end
        end
      },
      vb:row {
        vb:checkbox {
          value = false,
          id = 'dpx_browser_configuration_running_checkbox',
          tooltip = txt_running,
          notifier = function(v)
            if (not self._suppress_notifiers) then
              if (v == true) then
                self:start_current_configuration()
              else
                self:stop_current_configuration()
              end
            end
          end
        },
        vb:text {
          text = "Run",
          tooltip = txt_running,
        }
      }    
    },

    -- autostart checkbox
    vb:row {
      id = 'dpx_browser_autostart_row',
  
      vb:space { width = 50 },
      vb:checkbox {
        value = false,
        id = 'dpx_browser_autostart_checkbox',
        tooltip = txt_autostart,
        notifier = function(v)
          if (not self._suppress_notifiers) then
            if (v == true) then
              self:_enable_configuration_autostart()
            else
              self:_disable_configuration_autostart()
            end
          end
        end
      },     
      vb:text {
        tooltip = txt_autostart,
        text = "Autostart configuration",
      }
    },
    
    -- virtual device ui
    vb:column {
      id = 'dpx_browser_device_ui_row'
    },
    
    -- device info
    vb:multiline_text {
       id = 'dpx_browser_device_info_text',
       width = 300,
       height = 4*16
    }      
  }
end


--==============================================================================

-- BrowserProcess describes a processes that is launched by the browser - a 
-- device with one or more applications, set up by a device configuration

class 'BrowserProcess'

--------------------------------------------------------------------------------

--- Initialize the BrowserProcess class
-- @param p_browser (Browser), instance of Browser class

function BrowserProcess:__init(p_browser)
  TRACE("BrowserProcess:__init")

  -- the full configuration we got instantiated with (if any)
  self.configuration = nil
  -- shortcut for the configurations user settings
  self.settings = nil
  -- Device class instance
  self.device = nil 

  
  -- Display class instance
  self.display = nil 

  -- MessageStream class instance
  self._message_stream = nil

  -- View that got build by the display for the device
  self._control_surface_view = nil
  self._control_surface_parent_view = nil

  -- view for displaying/editing device settings
  self._settings_dialog = nil
  self._settings_view = nil

  -- list of instantiated apps for the current configuration
  self._applications = table.create() 


  
  -- true when this process was running at least once after instantiated
  self._was_running = false

  self._vb = renoise.ViewBuilder()

  self.browser = p_browser

end


--------------------------------------------------------------------------------

--- Check if this process matches the given device configurations
-- @param device_display_name (String)
-- @param config_name (String)
-- @return (Boolean) 

function BrowserProcess:matches(device_display_name, config_name)

  return (self.configuration ~= nil) and
    (self.configuration.device.display_name == device_display_name) and  
    (self.configuration.name == config_name)
end

--------------------------------------------------------------------------------

--- Check if this process matches the given configuration
-- @param config (String)
-- @return (Boolean) 

function BrowserProcess:matches_configuration(config)
  return self:matches(config.device.display_name, config.name)
end


--------------------------------------------------------------------------------

--- Decide whether the process instantiated correctly
-- @return (Boolean)

function BrowserProcess:instantiated()
  return (self.configuration ~= nil and self.device ~= nil)
end


--------------------------------------------------------------------------------

--- Initialize a process from the passed configuration. this will only 
-- create the device, display and app, but not start it. to start a process,
-- "start" must be called. 
-- @param configuration (Table) the device configuration
-- @return (Boolean) true when instantiated

function BrowserProcess:instantiate(configuration)
  TRACE("BrowserProcess:instantiate:", 
    configuration.device.display_name, configuration.name)

  assert(not self:instantiated(), "Internal Error. Please report: " .. 
    "browser process already instantiated")


  ---- validate the configuration (help controller developers to spot bugs)
  
  -- device node specified?
  if (not configuration.device) then
    renoise.app():show_warning(
      "Whoops! This configuration has no device definition")
      
    return false
  end

  -- control map specified?
  if (not configuration.device.control_map) then
    renoise.app():show_warning(
      "Whoops! This configuration has no control-map")
      
    return false
  end

  -- device class specified?
  local device_class_name = configuration.device.class_name

  if (not device_class_name) then
    local protocol = configuration.device.protocol
    
    -- use a generic class if the config does not specify one  
    if (protocol == DEVICE_MIDI_PROTOCOL)then
      device_class_name = "MidiDevice"
    
    elseif (protocol == DEVICE_OSC_PROTOCOL)then
      device_class_name = "OscDevice"
    
    else
      renoise.app():show_warning(
        ("Whoops! This configuration uses an " .. 
         "unexpected protocol (%s)"):format(protocol or "nil"))
        
      return false
    end
  end

  -- device class valid?
  if (not rawget(_G, device_class_name)) then
    renoise.app():show_warning(
      ("Whoops! Cannot instantiate device with " ..
       "unknown class: '%s'"):format(device_class_name))

    return false      
  end

  -- application class node specified?
  if (configuration.applications == nil) then 
    renoise.app():show_warning(("Whoops! Device configuration "..
       "contains no applications"))

    return false
  end
  
  -- application classes valid?
  for app_class_name in pairs(configuration.applications) do

    if configuration.applications[app_class_name].application then
      app_class_name = configuration.applications[app_class_name].application
    end
    if (not rawget(_G, app_class_name)) then
      renoise.app():show_warning(
        ("Whoops! Device configuration "..
         "contains unknown application class: '%s'"):format(
         app_class_name or "nil"))

      return false
    end
  end
  

  ---- assign the config and settings

  self.configuration = configuration
  self.settings = configuration_settings(configuration)

  ---- instantiate the device

  self._message_stream = MessageStream(self)

  if (configuration.device.protocol == DEVICE_MIDI_PROTOCOL) then

    local device_port_in = (self.settings.device_port_in.value ~= "") and 
      self.settings.device_port_in.value or configuration.device.device_port_in
      
    local device_port_out = (self.settings.device_port_out.value ~= "") and 
      self.settings.device_port_out.value or configuration.device.device_port_out
    
    self.device = _G[device_class_name](
      configuration.device.display_name, 
      self._message_stream,
      device_port_in,
      device_port_out
    )

    -- MIDI port setup changed
    renoise.Midi.devices_changed_observable():add_notifier(
      BrowserProcess._available_device_ports_changed, self
    )

  
  else  -- protocol == DEVICE_OSC_PROTOCOL

    local prefix = (self.settings.device_prefix.value ~= "") and 
      self.settings.device_prefix.value or configuration.device.device_prefix
    
    local address = (self.settings.device_address.value ~= "") and 
      self.settings.device_address.value or configuration.device.device_address
    
    local port_in = (self.settings.device_port_in.value ~= "") and 
      self.settings.device_port_in.value or configuration.device.device_port_in

    local port_out = (self.settings.device_port_out.value ~= "") and 
      self.settings.device_port_out.value or configuration.device.device_port_out

    self.device = _G[device_class_name](
      configuration.device.display_name,
      self._message_stream,
      prefix,
      address,
      tonumber(port_in),
      tonumber(port_out)
    )
  end
    
  self.device:set_control_map(
    configuration.device.control_map)

  self.display = Display(self.device)
  self.device.display = self.display


  ---- instantiate all applications

  local config_apps = configuration.applications

  self._applications = table.create()

  for app_class_name,_ in pairs(config_apps) do

    local actual_cname = app_class_name
    if config_apps[app_class_name].application then
      actual_cname = config_apps[app_class_name].application
    end

    --local mappings = config_apps[app_class_name].mappings or {}
    --local palette = config_apps[app_class_name].palette or {}
    local hidden = config_apps[app_class_name].hidden_options or {}
    local mappings = table.rcopy(_G[actual_cname]["available_mappings"]) or {}
    local options = table.rcopy(_G[actual_cname]["default_options"]) or {}
    local palette = table.rcopy(_G[actual_cname]["default_palette"]) or {}
    local config_name = app_class_name

    -- import user-specified options from the preferences
    for k,v in pairs(options) do
      local app_node = self.settings.applications:property(app_class_name)
      if app_node then
        if app_node.options and app_node.options:property(k) then
          options[k].value = app_node.options:property(k).value
          if table_find(hidden,k) then
            options[k].hidden = true
          end
        end
      end
    end

    -- import mappings from device-config
    for k,v in pairs(mappings) do
      local user_mappings = config_apps[app_class_name].mappings or {}
      for k2,v2 in pairs(user_mappings) do
        if (k == k2) then
          for k3,v3 in pairs(v2) do
            mappings[k][k3] = v3
          end
        end
      end
    end
    
    -- merge with palette from device-config
    for k,v in pairs(palette) do
      local user_palette = config_apps[app_class_name].palette or {}
      for k2,v2 in pairs(user_palette) do
        if (k == k2) then
          for k3,v3 in pairs(v2) do
            palette[k][k3] = v3
          end
        end
      end
    end

    local app_instance = nil

    app_instance = _G[actual_cname](
        self, mappings, options, config_name, palette)
    
    self._applications:insert(app_instance)
  end

  self._was_running = false
  
  return true
end

--------------------------------------------------------------------------------

--- Handle device hot-plugging (ports changing while Renoise is running)

function BrowserProcess:_available_device_ports_changed()
  TRACE("BrowserProcess:_available_device_ports_changed()")

  -- close the device setting dialogs on MIDI port changes 
  -- so we don't have to bother updating them
  
  if (self:settings_dialog_visible()) then
      self:close_settings_dialog()
  end
end

--------------------------------------------------------------------------------

--- Decide whether the device settings dialog is visible 
-- @return (Boolean) 

function BrowserProcess:settings_dialog_visible()
  TRACE("BrowserProcess:settings_dialog_visible()")

  return (self._settings_dialog and self._settings_dialog.visible)
end

--------------------------------------------------------------------------------

--- Deinitialize a process actively. can always be called, even when 
-- initialization never happened

function BrowserProcess:invalidate()
  TRACE("BrowserProcess:invalidate")

  while (not self._applications:is_empty()) do
    local last_app = self._applications[#self._applications]
    if (last_app.running) then 
      last_app:stop_app() 
    end
    last_app:destroy_app()
    
    self._applications:remove(#self._applications)
  end
  
  self._was_running = false
  
  self._message_stream = nil
  self.display = nil

  if (self.device) then
    if (self:settings_dialog_visible()) then
      self:close_settings_dialog()
    end
    
    if (self:control_surface_visible()) then
      self:hide_control_surface()
    end
    
    self.device:release()
    self.device = nil
  end
  
  self.configuration = nil
end


--------------------------------------------------------------------------------

--- Decide if process is running (its apps are running)
-- @return Boolean

function BrowserProcess:running()

  if (#self._applications == 0) then
    return false -- can't run without apps
  end
  
  for _,app in pairs(self._applications) do
    if (not app.active) then
      return false
    end
  end
    
  return true
end


--------------------------------------------------------------------------------

--- Start running a fully configured process. returns true when successfully 
-- started, else false (may happen if one of the apps failed to start)

function BrowserProcess:start(start_running)
  TRACE("BrowserProcess:start",start_running)

  assert(self:instantiated(), "Internal Error. Please report: " .. 
    "trying to start a process which was not instantiated")

  assert(not self:running(), "Internal Error. Please report: " ..
    "trying to start a browser process which is already running")
  
  local succeeded = true
  
  -- start every single app we have
  for _,app in pairs(self._applications) do
    if (app:start_app(start_running) == false) then
      succeeded = false
      break
    end
  end
  
  -- stop already started apps on failures
  if (not succeeded) then
    for _,app in pairs(self._applications) do
      if (app.running) then
        app:stop_app()
      end
    end
  end
  
  -- refresh the display when reactivating an old process
  if (succeeded and self._was_running) then
    self.display:clear()
  end

  self._was_running = succeeded
    
  return succeeded
end


--------------------------------------------------------------------------------

--- Stop a running process. will not invalidate it, just stop all apps

function BrowserProcess:stop()
  TRACE("BrowserProcess:stop")

  assert(self:instantiated(), "Internal Error. Please report: " ..
    "trying to stop a process which was not instantiated")

  assert(self:running(), "Internal Error. Please report: " ..
    "trying to stop a browser process which is not running")
  
  for _,app in pairs(self._applications) do
    app:stop_app()
  end
end


--------------------------------------------------------------------------------

--- Returns true when the processes control surface is currently visible
-- (this is also an indication of whether this is the selected device)

function BrowserProcess:control_surface_visible()
  return (self._control_surface_view ~= nil)
end


--------------------------------------------------------------------------------

--- Show a device control surfaces in the browser gui
-- @param parent_view (ViewBuilder) the browser GUI

function BrowserProcess:show_control_surface(parent_view)
  TRACE("BrowserProcess:show_control_surface")

  assert(self:instantiated(), "Internal Error. Please report: " ..
    "trying to show a control map GUI which was not instantiated")
  
  assert(not self:control_surface_visible(), 
    "Internal Error. Please report: " ..
    "trying to show a control map GUI which is already shown")
    
  -- add the device GUI to the browser GUI
  self._control_surface_parent_view = parent_view

  self._control_surface_view = 
    self.display:build_control_surface()

  parent_view:add_child(self._control_surface_view)

  -- refresh the display when reactivating an old process
  if (self:running()) then
    self.display:clear()
  end
end


--------------------------------------------------------------------------------

--- Display, or bring the browser dialog to front

function BrowserProcess:show_settings_dialog()

  -- already visible? bring to front...
  if (self._settings_dialog and self._settings_dialog.visible) then
    self._settings_dialog:show()
    return    
  end

  local vb = self._vb

  local val_unhandled = self.settings.pass_unhandled.value
  local txt_unhandled = "When enabled, messages that are not handled by an "
                      .."\napplication are forwarded to Renoise (this also "
                      .."\napplies when the whole configuration is stopped). "
                      .."\nAllows you to use Renoise MIDI mapping-features in "
                      .."\ncombination with Duplex"

  -- define the basic settings view
  if not self._settings_view then
    self._settings_view = vb:column{
      spacing = DEFAULT_SPACING,
      margin = renoise.ViewBuilder.DEFAULT_DIALOG_MARGIN,
      vb:row{
        id="dpx_device_settings_root",
      },
      vb:column{
        id="dpx_unhandled_root",
        vb:row{
          vb:checkbox{
            value = val_unhandled,
            notifier = function(v)
              self.settings.pass_unhandled.value = v
            end,
          },
          vb:text {
            text = "Pass unhandled MIDI messages to Renoise",
            tooltip = txt_unhandled,
          }
        },
      },
      vb:space{
        height = 4,
      },
      vb:row{
        id="dpx_app_settings_root",
        spacing = DEFAULT_SPACING,
        vb:column{id="dpx_app_settings_col1",spacing = DEFAULT_SPACING},
        vb:column{id="dpx_app_settings_col2",spacing = DEFAULT_SPACING},
        vb:column{id="dpx_app_settings_col3",spacing = DEFAULT_SPACING},
        vb:column{id="dpx_app_settings_col4",spacing = DEFAULT_SPACING},
        vb:column{id="dpx_app_settings_col5",spacing = DEFAULT_SPACING},
        vb:column{id="dpx_app_settings_col6",spacing = DEFAULT_SPACING},
      }
    }

    -- attach the device settings
    self.device:show_settings_dialog(self)
    vb.views.dpx_device_settings_root:add_child(self.device._settings_view)

    -- sort alphabetically
    table.sort(self._applications,function(a,b)
      return (a._app_name < b._app_name)
    end)

    -- create & attach the various application settings
    local app_count = 0
    local apps_per_col = 16
    for _,app in pairs(self._applications) do
      app:_build_options(self)
      local col_idx = math.floor(app_count/apps_per_col)+1
      local col_id = ("dpx_app_settings_col%d"):format(col_idx)
      if not vb.views[col_id] then
        local msg = "The device configuration contains too many applications,"
                  .."\nsome options will not be available"
        renoise.app():show_warning(msg)
        break
      else
        vb.views[col_id]:add_child(app._settings_view)
        app_count = app_count + 1 
      end
    end

    -- show/hide the "unhandled message" part
    local elm = vb.views.dpx_unhandled_root
    local show_unhandled = (self.device.protocol == DEVICE_MIDI_PROTOCOL)
    vb.views.dpx_unhandled_root.visible = show_unhandled

  end

  self._settings_dialog = renoise.app():show_custom_dialog(
    "Duplex: Device Settings", self._settings_view)


end

--------------------------------------------------------------------------------

--- Close the device settings, when open

function BrowserProcess:close_settings_dialog()
  TRACE("BrowserProcess:close_settings_dialog()")

  if (self._settings_dialog and self._settings_dialog.visible) then
    self._settings_dialog:close()
  end

  self._settings_dialog = nil
end
  

--------------------------------------------------------------------------------

--- Hide the device control surfaces, when showing it...

function BrowserProcess:hide_control_surface()
  TRACE("BrowserProcess:hide_control_surface")

  assert(self:instantiated() and self:control_surface_visible(), 
    "Internal Error. Please report: " .. 
    "trying to hide a control map GUI which was not shown")
    
  -- remove the device GUI from the browser GUI
  self._control_surface_parent_view:remove_child(
    self._control_surface_view)

  self._control_surface_view = nil
  self._control_surface_parent_view = nil
end


--------------------------------------------------------------------------------

--- Clears/repaints the display, device, virtual UI

function BrowserProcess:clear_display()
  TRACE("BrowserProcess:clear_display")
  
  assert(self:instantiated(), "Internal Error. Please report: " ..
    "trying to clear a control map GUI which was not instantiated")
  
  if (self:running()) then
    self.display:clear() 
  end
end


--------------------------------------------------------------------------------

--- Start/stop device midi dump
-- @param dump (Boolean), true to start dumping MIDI

function BrowserProcess:set_dump_midi(dump)
  TRACE("BrowserProcess:set_dump_midi", dump)

  if (self:instantiated()) then
    if (self.device.protocol == DEVICE_MIDI_PROTOCOL) then
      self.device.dump_midi = dump
    end
  end
end


--------------------------------------------------------------------------------

--- Provide idle support for all active apps

function BrowserProcess:on_idle()
  -- TRACE("BrowserProcess:idle")
  
  if (self:instantiated()) then
    
    -- idle process for stream
    self._message_stream:on_idle()
    
    -- modify ui components
    self.display:update()
  
    -- then refresh the display 
    for _,app in pairs(self._applications) do
      app:on_idle()
    end
  end
end


--------------------------------------------------------------------------------

--- Provide document released notification for all active apps

function BrowserProcess:on_release_document()
  TRACE("BrowserProcess:on_release_document")

  if (self:instantiated()) then
    for _,app in pairs(self._applications) do
      app:on_release_document()
    end
  end
end


--------------------------------------------------------------------------------

--- Provide new document notification for all active apps

function BrowserProcess:on_new_document()
  TRACE("BrowserProcess:on_new_document")

  if (self:instantiated()) then
    for _,app in pairs(self._applications) do
      app:on_new_document()
    end
  end
end


--------------------------------------------------------------------------------

--- Comparison operator (check configs only)
-- @param other (BrowserProcess) the process to compare against

function BrowserProcess:__eq(other)
  return self:matches_configuration(other.configuration)
end

