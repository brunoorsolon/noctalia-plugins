-- Keeps one flattened lockscreen backdrop per output in sync with the wallpaper.
-- All pixel work happens in generate-masked-wallpaper.sh; this service only decides
-- when to run it. Each output gets a stable destination path that a sticker widget
-- points at once and forever, because the sticker reloads a same-path replacement.

local function str(key)
  local value = noctalia.getConfig(key)
  if type(value) ~= "string" then return "" end
  return value:match("^%s*(.-)%s*$")
end

local function destDir()
  local dir = str("dest_dir")
  if dir == "" then return noctalia.pluginDataDir() end
  return dir
end

local presets = {
  ["center-glow"] = { mask = "masks/center-glow.png", decoration = "decorations/center-glow.png" },
  ["left-panel"] = { mask = "masks/left-panel.png", decoration = "decorations/left-panel.png" },
  ["right-panel"] = { mask = "masks/right-panel.png", decoration = "decorations/right-panel.png" },
  ["facet"] = { mask = "masks/facet.png", decoration = "decorations/facet.png" },
}

local function presetAssets()
  local name = str("mask_preset")
  if name == "custom" then return str("shape"), "" end
  local pluginDir = noctalia.pluginDir()
  if not pluginDir then return "", "" end
  local preset = presets[name] or presets["center-glow"]
  return pluginDir .. "/" .. preset.mask, pluginDir .. "/" .. preset.decoration
end

-- Noctalia rewrites this on every theme change, from the template in this plugin.
local function paletteFile()
  return destDir() .. "/palette.env"
end

-- The GUI slides these 0-100; the script wants 0-1. A plugin "double" setting
-- renders a slider with no reachable middle, so percentages are the usable type.
local function percent(key, fallback)
  local value = noctalia.getConfig(key)
  if type(value) ~= "number" then value = fallback end
  return string.format("%.4f", value / 100)
end

-- Physical pixels, so the sticker stays sharp on a scaled output.
local function pixels(logical, scale)
  if type(scale) ~= "number" or scale <= 0 then scale = 1 end
  return tostring(math.floor(logical * scale + 0.5))
end

local function argvFor(output, wallpaper, shape, presetDecoration, dest)
  local argv = {
    "bash", noctalia.pluginDir() .. "/generate-masked-wallpaper.sh",
    "--wallpaper", wallpaper,
    "--shape", shape,
    "--connector", output.name,
    "--width", pixels(output.width, output.scale),
    "--height", pixels(output.height, output.scale),
    "--blur", percent("blur", 60),
    "--tint", str("tint"),
    "--tint-intensity", percent("tint_intensity", 30),
    "--palette", paletteFile(),
    "--cache-dir", destDir() .. "/cache",
    "--dest", dest,
  }
  if presetDecoration ~= "" then
    table.insert(argv, "--preset-decoration")
    table.insert(argv, presetDecoration)
  end
  for slot = 1, 3 do
    local image = str("decoration_" .. slot)
    if image ~= "" then
      table.insert(argv, "--decoration-" .. slot)
      table.insert(argv, image)
      if noctalia.getConfig("colorize_" .. slot) then
        table.insert(argv, "--decoration-color-" .. slot)
        table.insert(argv, str("color_" .. slot))
      end
    end
  end
  return argv
end

local function sync()
  local shape, presetDecoration = presetAssets()
  if shape == "" then return end
  -- Colours may be palette role names, so the palette's contents belong in the key:
  -- without it a colors_changed event would look like no change at all.
  local palette = noctalia.readFile(paletteFile()) or ""
  for _, output in ipairs(noctalia.outputs()) do
    local wallpaper = noctalia.wallpaperPath(output.name)
    if wallpaper then
      local dest = destDir() .. "/masked-wallpaper-" .. output.name .. ".jpg"
      local argv = argvFor(output, wallpaper, shape, presetDecoration, dest)
      local key = table.concat(argv, "\31") .. "\31" .. palette
      local stateKey = "key:" .. output.name
      if noctalia.state[stateKey] ~= key or not noctalia.fileExists(dest) then
        noctalia.state[stateKey] = key
        -- ponytail: a bad path in settings re-spawns the script on every sync, because
        -- dest never appears. It dies on argument validation in milliseconds.
        noctalia.runAsync(argv)
      end
    end
  end
end

-- The wallpaper_changed and colors_changed hooks drive this through onIpc; update()
-- is only a slow safety net, so a missing hook still converges and a deleted output
-- file comes back.
function update()
  noctalia.setUpdateInterval(3600000)
  sync()
end

function onIpc()
  sync()
end

function onConfigChanged()
  sync()
end

function onOutputsChanged()
  sync()
end
