include("pursuitai_player.lua")

PursuitAiEntSearch = {}

function PursuitAiEntSearch:TargetEnemy(args)
  -- If we've looked for an enemy recently, return the cached result
  if args["lastEnemySearchTime"] and CurTime() - args["lastEnemySearchTime"] < 1 then
    return args["cachedEnemy"]
  end
  args["lastEnemySearchTime"] = CurTime()

  -- Find all enemies within pursuitRange
  local nearest, distance = nil, math.huge
  local plrs = player.GetAll()
  for _, plr in ipairs(plrs) do
    if PursuitAiPlayer:Validate(plr, args["vehicle"], args["pursuitRange"]) then
      local newDistance = plr:WorldSpaceCenter():Distance2DSqr(args["vehicleCenter"])
      if distance > newDistance then
        nearest = plr
        distance = newDistance
      end
    end
  end

  -- Cache the result for later
  args["cachedEnemy"] = nearest

  return nearest
end
