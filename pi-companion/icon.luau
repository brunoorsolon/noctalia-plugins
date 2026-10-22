-- A small pixel-display robot. Every lit pixel is an uncolored native glyph,
-- so Noctalia applies Icon Color, then widget Color, then the theme default.
local icon = { interval = 125, size = 20, pixelSize = 2 }

local head = {
  "                    ",
  "         ##         ",
  "         ##         ",
  "         ##         ",
  "    ############    ",
  "  ################  ",
  "  ##            ##  ",
  "  ##            ##  ",
  "####            ####",
  "####            ####",
  "####            ####",
  "####            ####",
  "  ##            ##  ",
  "  ##            ##  ",
  "  ##            ##  ",
  "  ##            ##  ",
  "  ################  ",
  "    ############    ",
  "                    ",
  "                    ",
}
local pi = {
  " ########## ",
  "   #   #    ",
  "   #   #    ",
  "   #   #    ",
  "   #   #    ",
  "   #   #    ",
  "   #   #    ",
  "  #     ##  ",
}
local heartbeat = {
  "     #      ",
  "     ##     ",
  "   # # #    ",
  "### #  # ###",
  "       # #  ",
  "       # #  ",
  "        #   ",
  "            ",
}
local bell = {
  "     ##     ",
  "    #  #    ",
  "   #    #   ",
  "   #    #   ",
  "   #    #   ",
  "  #      #  ",
  "  ########  ",
  "     ##     ",
}
local unknown = {
  "     ##     ",
  "     ##     ",
  "     ##     ",
  "     ##     ",
  "     ##     ",
  "            ",
  "     ##     ",
  "     ##     ",
}

function icon.frame(state, time)
  local phase = math.floor(time / icon.interval)
  local face = state == "unknown" and unknown or pi
  local rows = table.clone(head)
  for y = 1, 8 do
    local line = ""
    for x = 1, 12 do
      local lit
      if state == "working" then
        -- One heartbeat travels left through the display, wrapping at its edge.
        local column = (x + phase - 1) % 12 + 1
        lit = heartbeat[y]:sub(column, column) == "#"
      elseif state == "waiting" then
        -- Sway the bell's body around its top; pause between pairs of rings.
        local sway = ({ 0, -1, 0, 1, 0, -1, 0, 1, 0, 0, 0, 0 })[phase % 12 + 1]
        local offset = y > 2 and sway or 0
        local column = x - offset
        lit = column >= 1 and column <= 12 and bell[y]:sub(column, column) == "#"
      else
        lit = face[y]:sub(x, x) == "#"
      end
      line ..= lit and "#" or " "
    end
    rows[y + 7] = rows[y + 7]:sub(1, 4) .. line .. rows[y + 7]:sub(17)
  end
  return rows
end

function icon.render(state, time)
  local rows = {}
  for y, line in ipairs(icon.frame(state, time)) do
    local pixels = {}
    for x = 1, icon.size do
      -- Overscan each cell: the font's rounded corners, alpha fringe and snapped
      -- positions otherwise leave dotted seams, especially at fractional scales.
      pixels[x] = ui.row({ key = tostring(x), width = 1, height = 1, justify = "center", align = "center" }, {
        ui.glyph({ name = "square-filled", size = icon.pixelSize, opacity = line:sub(x, x) == "#" and 1 or 0 }),
      })
    end
    rows[y] = ui.row({ key = tostring(y), gap = 0, width = icon.size, height = 1 }, pixels)
  end
  return ui.column({ gap = 0, width = icon.size, height = icon.size }, rows)
end

return icon
