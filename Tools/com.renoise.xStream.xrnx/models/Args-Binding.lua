--[[============================================================================
Args-Binding.lua
 File generated by xStream - please see documentation for details
============================================================================]]--

return {
arguments = {
  {
      name = "velocity_enabled",
      value = true,
      properties = {},
      bind = "rns.transport.keyboard_velocity_enabled_observable",
      description = "Whether to apply velocity or note",
  },
  {
      name = "velocity",
      value = 52,
      properties = {
          min = 0,
          display_as = "hex",
          max = 127,
      },
      bind = "rns.transport.keyboard_velocity_observable",
      description = "Specify the keyboard velocity",
  },
  {
      name = "instr_idx",
      value = 1,
      properties = {
          max = 255,
          min = 1,
          display_as = "hex",
          zero_based = true,
      },
      bind = "rns.selected_instrument_index_observable",
      description = "Specify the instrument number",
  },
},
presets = {
  {
      velocity_enabled = true,
      velocity = 84,
      instr_idx = 1,
  },
  {
      velocity_enabled = true,
      velocity = 84,
      instr_idx = 1,
  },
},
data = {
},
options = {
 color = 0x60AACA,
},
callback = [[
-------------------------------------------------------------------------------
-- Binding to (observable) properties 
-- Bind an arguments to update the value in Renoise when it changes in 
-- xStream, and vice versa. Full bi-directional synchronization! 
-- This example will write notes ranging from C-3 to B-5 into the first note 
-- column, using the selected instrument and the current keyboard velocity.
-------------------------------------------------------------------------------

xline.note_columns[1] = {
  note_value = (xinc%36)+36,
  instrument_value = args.instr_idx,
  volume_value = args.velocity_enabled and args.velocity or EMPTY_VOLUME_VALUE,
}  




]],
}