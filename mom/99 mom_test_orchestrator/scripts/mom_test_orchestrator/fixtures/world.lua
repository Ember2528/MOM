-- Shared timing, cell, travel, quest, and faction fixtures.

local M = {}

M.AUTO_START = true
M.DEFAULT_TIMEOUT_FRAMES = 240
M.LONG_TIMEOUT_FRAMES = 420
M.EXTERIOR_REVERT_TIMEOUT_FRAMES = M.LONG_TIMEOUT_FRAMES * 2
M.EXTERIOR_REVERT_TIMEOUT_SECONDS = 10
M.EXTERIOR_CELL_SIZE = 8192

-- Cells

M.GUILD_OF_MAGES = 'Balmora, Guild of Mages'
M.EIGHT_PLATES = 'Balmora, Eight Plates'
M.VASSAMSI_GROTTO = 'Vassamsi Grotto'

M.BALMORA_EXTERIOR = {
  gridX = -3,
  gridY = -2,
}

-- Safe teleport positions

M.GUILD_SAFE_POSITION = {
  x = 36,
  y = -161,
  z = 28,
}

M.EIGHT_PLATES_SAFE_POSITION = {
  x = 960.696,
  y = 1020.348,
  z = -256.0,
}

M.VASSAMSI_GROTTO_SAFE_POSITION = {
  x = -2112.0,
  y = 3840.0,
  z = -32.0,
}

M.KNIGHT_AKAY_QUEST = 'FG_RatHunt'

return M
