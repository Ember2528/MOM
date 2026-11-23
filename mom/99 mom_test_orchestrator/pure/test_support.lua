-- Minimal assertions and case execution shared by pure suites.
local M = {}

function M.traceback(message)
  if type(debug) == 'table' and type(debug.traceback) == 'function' then
    return debug.traceback(tostring(message), 2)
  end
  return tostring(message)
end

function M.fail(message)
  error(message or 'expectation failed', 2)
end

function M.expect(condition, message)
  if not condition then
    error(message or 'expectation failed', 2)
  end
end

function M.runCases(label, cases)
  if M.stressOnly then
    local selected = {}
    for i = 1, #cases do
      local metadata = cases[i][3]
      if type(metadata) == 'table' and metadata.stress then
        selected[#selected + 1] = cases[i]
      end
    end
    cases = selected
    if #cases == 0 then return 0 end
  end
  for i = 1, #cases do
    local case = cases[i]
    if M.stressOnly then
      print('MOM_STRESS_CASE:' .. tostring(label) .. ': ' .. tostring(case[1]))
    end
    local ok, caseError = pcall(case[2])
    if not ok then
      error(string.format(
        '%s case failed: %s: %s',
        tostring(label),
        tostring(case[1]),
        tostring(caseError)
      ), 0)
    end
  end
  return #cases
end

return M
