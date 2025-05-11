PursuitAiPlayer = PursuitAiPlayer or {}

function PursuitAiPlayer:Validate(player, vehicle, pursuitRange)
  if not IsValid(player) then
    return false
  end

  if not player:Alive() then
    return false
  end

  -- If AI is disabled or we ignore players
  if GetConVar("ai_disabled"):GetBool() or GetConVar("ai_ignoreplayers"):GetBool() then
    return false
  end

  -- If the player has the NoTarget flag
  if player:IsFlagSet(FL_NOTARGET) then
    return false
  end

  -- If the player is out of range
  if vehicle:WorldSpaceCenter():Distance2DSqr(player:WorldSpaceCenter()) > pursuitRange:GetFloat() ^ 2 then
    return false
  end

  return true
end
