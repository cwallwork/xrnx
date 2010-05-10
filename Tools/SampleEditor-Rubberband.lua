--[[----------------------------------------------------------------------------

  Script        : Rubberband.lua
  Creation Date : 2010-05-05
  Last modified : 2010-05-05
  Version       : 0.2

----------------------------------------------------------------------------]]--

manifest = {}
manifest.api_version = 0.2
manifest.author = "ClySuva | clysuva@gmail.com"
manifest.description = "adds rubberband interface to Renoise"
manifest.actions = {}

manifest.actions[#manifest.actions + 1] = {
  name = "SampleEditor:Process:Timestretch",
  description = 'Stretches sample length without changing pitch',
  invoke = function() show_stretch_dialog() end
}

manifest.actions[#manifest.actions + 1] = {
  name = "SampleEditor:Process:Pitch Shift",
  description = 'Changes sample pitch without chaning  length',
  invoke = function() show_shift_dialog() end
}

-- Does file exist?
function exists(filename)
  local file = io.open(filename)
  if file then
    io.close(file)
    return true
  else
    return false
  end
end

function display_error() 
  local res = renoise.app():show_prompt('Rubberband missing!',
  "To use this feature you must download Rubberband executable and\n"..
  "copy it to your operating system path!\n\n"..
  "On Ubuntu you must install package rubberband-cli\n\n"..
  "On other systems, you can download binaries or the source code from:\n"..
  "http://www.breakfastquay.com/rubberband/"
  , {'Visit website', 'Ok'})
  
  if res == 'Visit website' then
    renoise.app():open_url('http://www.breakfastquay.com/rubberband/');
  end
end

function process_rubberband(cmd)
  print(cmd);
  local ofile = os.tmpname()
  local ifile = os.tmpname()..'.wav'

  renoise.song().selected_sample.sample_buffer:save_as(ofile, 'wav')

  os.execute(cmd .. " "..ofile.." "..ifile);
         
  if not exists(ifile) then
    display_error()
    return
  end
          
  renoise.song().selected_sample.sample_buffer:load_from(ifile)
  
  os.remove(ofile)
  os.remove(ifile)
end


function process_stretch(stretch, crisp)
  process_rubberband("rubberband --time "..stretch.." --crisp "..crisp);
end

function process_shift(shift, crisp, preserve_formant)
  local cmd = "rubberband --pitch "..shift.." --crisp "..crisp;
  if preserve_formant then
    cmd = cmd .. ' -F'
  end
  process_rubberband(cmd);
end

function show_shift_dialog()

  local vb = renoise.ViewBuilder()
  
  local semitone_selector = vb:valuebox { min = -48, max = 48, value = 0 }
  local cent_selector = vb:valuebox { min = -100, max = 100, value = 0 }
  local crisp_selector = vb:popup { 
    items = {'1', '2', '3', '4', '5'},
    value = 4 
  }
  local formant_selector = vb:checkbox {}
  
  local view = 
  vb:vertical_aligner {
    margin = 10,
    vb:horizontal_aligner{
      spacing = 10,
      vb:vertical_aligner{
        vb:text{text = 'Semitones:' },
        semitone_selector,
      },
      vb:vertical_aligner{
        vb:text{text = 'Cents:' },
        cent_selector,
      },
      vb:vertical_aligner{
        vb:text{text = 'Crispness:' },
        crisp_selector
      },
    },
    vb:horizontal_aligner{
      margin = 10,
      spacing = 5,
      formant_selector,
      vb:text{text = 'Preserve formant' },
    }
  }
  
  local res = renoise.app():show_custom_prompt  (
    "Pitch Shift",
    view,
    {'Shift', 'Cancel'}
  );
    
  if res == 'Shift' then
    process_shift(semitone_selector.value + (cent_selector.value / 100), crisp_selector.value, formant_selector.value)
  end;
end

function show_stretch_dialog()
  local bpm = renoise.song().transport.bpm
  local lpb = renoise.song().transport.lpb
  local coef = bpm * lpb / 60.0

  local sel_sample = renoise.song().selected_sample
  local nframes = sel_sample.sample_buffer.number_of_frames
  local srate = sel_sample.sample_buffer.sample_rate

  local slength = nframes / srate
  local rows = slength * coef

  local vb = renoise.ViewBuilder()
  
  local nlines_selector = vb:valuebox { min = 1, value = 16 }
  local crisp_selector = vb:popup { 
    items = {'1', '2', '3', '4', '5'},
    value = 4 
  }
  local type_selector = vb:popup {
    items = {'lines', 'beats', 'seconds'},
    value = 2
  }
  
  local view = vb:horizontal_aligner{
    margin = 10,
    spacing = 10,
    vb:vertical_aligner{
      vb:text{text = 'Length:' },
      nlines_selector,
    },
    vb:vertical_aligner{
      vb:text{text = 'Units:' },
      type_selector,
    },
    vb:vertical_aligner{
      vb:text{text = 'Crispness:' },
      crisp_selector
    },
  }
  
  local res = renoise.app():show_custom_prompt  (
    "Time Stretch",
    view,
    {'Stretch', 'Cancel'}
  );
  
  -- How long we stretch?
  local stime
  if type_selector.value == 1 then
    stime = nlines_selector.value / rows
  elseif type_selector.value == 2 then
    stime = (nlines_selector.value * lpb) / rows
  elseif type_selector.value == 3 then
    stime = nlines_selector.value / slength 
  end;
  
  if res == 'Stretch' then
    process_stretch(stime, crisp_selector.value)
  end;
end
