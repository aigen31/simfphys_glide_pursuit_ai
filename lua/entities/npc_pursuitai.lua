include("includes/modules/pursuitai_entity_search.lua")

list.Set("NPC", "npc_pursuitai", {
	Name = "Pursuit AI Enabler",
	Class = "npc_pursuitai",
	Category = "Pursuit AI"
})
AddCSLuaFile()

ENT.Base = "base_nextbot"

ENT.PrintName = "Pursuit AI Enabler"
ENT.Author = "LoveingLiamGuy"
ENT.Purpose = "Allows Simfphys or Glide vehicles to pursue players."
ENT.Instructions = "Spawn near a Simfphys or Glide vehicle."
ENT.Spawnable = false

local pursuitRange = CreateConVar("pursuitai_pursuitrange", 32768, { FCVAR_ARCHIVE, FCVAR_REPLICATED },
	"Any player within this distance from a pursuit AI will be pursued.", 0, 32768)

local detectionRange = CreateConVar("pursuitai_detectionrange", 250, { FCVAR_ARCHIVE, FCVAR_REPLICATED },
	"A Simfphys or Glide vehicle within this distance from a pursuit AI enabler's initial spawn point will have pursuit AI enabled.",
	0, 32768)

local spawnEffects = CreateConVar("pursuitai_spawneffects", 1, { FCVAR_ARCHIVE, FCVAR_REPLICATED },
	"Determines if a spawn effect should be made when a pursuit AI is initiated, and when a pursuit AI spawns an NPC.")

local npcsEnabled = CreateConVar("pursuitai_npcsenabled", 1, { FCVAR_ARCHIVE, FCVAR_REPLICATED },
	"Determines if pursuit AI's should spawn NPCs when they get close to a player.")

local npcAmount = CreateConVar("pursuitai_npcamount", 2, { FCVAR_ARCHIVE, FCVAR_REPLICATED },
	"The amount of NPCs spawned by a pursuit AI. For Simfphys vehicles, this is limited to a maximum of 2 at this time.", 1,
	8)

local npcClass = CreateConVar("pursuitai_npcclass", "npc_metropolice", { FCVAR_ARCHIVE, FCVAR_REPLICATED },
	"The NPC class spawned by a pursuit AI. You can get an NPC's class by right clicking on the target NPC in the spawn menu and then clicking \"Copy to clipboard\".")

local npcWeaponClass = CreateConVar("pursuitai_npcweaponclass", "", { FCVAR_ARCHIVE, FCVAR_REPLICATED },
	"The weapon class given to an NPC when spawned by a pursuit AI. Leave empty to use a random weapon from the NPC. You can get a weapon's class by right clicking on the target weapon in the spawn menu and then clicking \"Copy to clipboard\".")

local npcDespawnRange = CreateConVar("pursuitai_npcdespawnrange", 2000, { FCVAR_ARCHIVE, FCVAR_REPLICATED },
	"If a player goes beyond this range from a pursuit AI's NPC, the NPC will be despawned.", 0, 32768)

local aggressive = CreateConVar("pursuitai_aggressive", 0, { FCVAR_ARCHIVE, FCVAR_REPLICATED },
	"Determines if pursuit AI's should be more aggressive in direct pursuit.")

local settingsEnabled = CreateConVar("pursuitai_settings", 1, { FCVAR_ARCHIVE, FCVAR_REPLICATED },
	"Determines if pursuit AI ConVars can be changed from the pursuit AI settings tab in the spawnmenu. The visibility of the settings tab is also determined by this ConVar, but only when Lua starts.")

local derbyMode = CreateConVar("derby_mode", 0, { FCVAR_ARCHIVE, FCVAR_REPLICATED },
	"If enabled, the pursuit AI will be crash in the player and other vehicles with AI")

if SERVER then
	function setProperties(self)
		-- Make us invisible
		self:SetNoDraw(true)
		self:SetBloodColor(DONT_BLEED)

		-- Make us immovable
		self:SetMoveType(MOVETYPE_NONE)
		self.loco:SetDesiredSpeed(0)
		self.loco:SetAcceleration(10000)
		self.loco:SetDeceleration(10000)
		self.loco:SetJumpHeight(0)
		self.loco:SetClimbAllowed(false)

		-- Make us invulnerable
		self:SetHealth(1e8)
		self:AddFlags(FL_NOTARGET)
	end

	local function getDriver(vehicle)
		if vehicle.IsSimfphyscar then
			return vehicle:GetDriver()
		elseif vehicle.IsGlideVehicle then
			return vehicle:GetSeatDriver(1)
		end

		return NULL
	end

	function ENT:Initialize()
		setProperties(self)

		-- Find a Simfphys or Glide vehicle within detectionRange
		local entities = ents.FindInSphere(self:WorldSpaceCenter(), detectionRange:GetFloat())
		for _, vehicle in ipairs(entities) do
			if not vehicle.IsSimfphyscar and not vehicle.IsGlideVehicle then
				continue
			end

			if vehicle.IsSimfphyscar and not vehicle:IsInitialized() then
				continue
			end

			if not vehicle.IsGlideVehicle
					or vehicle.VehicleType == 1
					or vehicle.VehicleType == 2
					or vehicle.VehicleType == 5
			then
				-- Check for a driver and existing pursuit AI
				if not IsValid(getDriver(vehicle)) and not vehicle.PursuitAI then
					self.Vehicle = vehicle
					self.VehicleType = 1
					if self.Vehicle.IsGlideVehicle then
						self.VehicleType = 2
					end

					-- Start the vehicle
					if self.VehicleType == 1 then
						self.Vehicle:SetActive(true)
						self.Vehicle:StartEngine()
					elseif self.VehicleType == 2 then
						self.Vehicle:TurnOn()
					end

					-- Set some variables

					self.Vehicle.PursuitAI = self
					if self.VehicleType == 1 then
						self.LightsList = list.Get("simfphys_lights")[self.Vehicle.LightsTable]
					end

					self.MinBounds, self.MaxBounds = self.Vehicle:GetModelRenderBounds()

					self.SizeX = Vector(self.MinBounds.x, 0, 0):Distance(Vector(self.MaxBounds.x, 0, 0))
					self.SizeY = Vector(0, self.MinBounds.y, 0):Distance(Vector(0, self.MaxBounds.y, 0))
					self.SizeZ = Vector(0, 0, self.MinBounds.z):Distance(Vector(0, 0, self.MaxBounds.z))

					break
				end
			end
		end

		-- If there's no vehicle, remove ourselves
		if not IsValid(self.Vehicle) then
			SafeRemoveEntity(self)
			return
		end

		-- Perform a spawn effect
		if spawnEffects:GetBool() then
			local effectData = EffectData()
			effectData:SetEntity(self.Vehicle)
			util.Effect("propspawn", effectData)
		end

		-- Give a warning if the map doesn't have a navmesh
		if not navmesh.IsLoaded() then
			PrintMessage(HUD_PRINTTALK,
				"This map doesn't have a navmesh, which will prevent the pursuit AI's pathfinding functionality from working.")
		end

		-- Set some variables

		self.LastEnemySearchTime = nil
		self.CachedEnemy = nil

		self.Path = nil
		self.PathIndex = 1
		self.PathSegments = {}
		self.PathStatus = "failed"

		self.LastMovingTime = nil
		self.LastMovingTimeTeleport = nil

		self.Stopping = false
		self.LastNonStoppingTime = CurTime()

		self.Reversing = false
		self.ReversingSavedAngles = nil
		self.ReversingStuck = false

		self.LastPITTime = nil

		self.NPCClass = npcClass:GetString()
		self.NPCWeaponClass = npcWeaponClass:GetString()

		self.NPCs = {}
		self.RemovedNPCs = {}
		self.DeadNPCs = {}
		self.MaxNPCs = npcAmount:GetInt()

		self.Vehicle:DeleteOnRemove(self)
	end

	-- Removes all damage
	function ENT:OnInjured(damageInfo)
		damageInfo:SetDamage(0)
	end

	function ENT:OnRemove()
		if IsValid(self.Vehicle) then
			self.Vehicle.PursuitAI = nil

			if #self.DeadNPCs < self.MaxNPCs then
				spawnNPCs(self)
			end

			-- If there's no driver
			if not IsValid(getDriver(self.Vehicle)) then
				-- Turn off sirens
				if self.VehicleType == 1 then
					if self.LightsList and self.LightsList.ems_sounds then
						if self.Vehicle.ems and self.Vehicle.ems:IsPlaying() then
							self.Vehicle.ems:Stop()
						end
					end
				elseif self.VehicleType == 2 then
					if self.Vehicle.CanSwitchSiren then
						if self.Vehicle:GetSirenState() > 1 then
							self.Vehicle:ChangeSirenState(1)
						end
					end
				end
			end

			-- Reset inputs
			if self.VehicleType == 1 then
				self.Vehicle.PressedKeys["W"] = false
				self.Vehicle.PressedKeys["A"] = false
				self.Vehicle.PressedKeys["S"] = false
				self.Vehicle.PressedKeys["D"] = false
				self.Vehicle.PressedKeys["Shift"] = false
				self.Vehicle.PressedKeys["Space"] = false
			elseif self.VehicleType == 2 then
				self.Vehicle:SetInputFloat(1, "accelerate", 0)
				self.Vehicle:SetInputFloat(1, "brake", 0)
				self.Vehicle:SetInputBool(1, "handbrake", false)
			end
		end
	end

	function ENT:ValidateSelf()
		if not IsValid(self.Vehicle) then
			SafeRemoveEntity(self)
			return false
		end

		-- If our vehicle has a driver
		if IsValid(getDriver(self.Vehicle)) then
			SafeRemoveEntity(self)
			return false
		end

		-- If our vehicle is fully submerged in water
		if self.Vehicle:WaterLevel() >= 3 then
			SafeRemoveEntity(self)
			return false
		end

		-- If our vehicle is destroyed
		if (self.VehicleType == 1 and self.Vehicle:GetCurHealth() <= 0)
				or (self.VehicleType == 2 and self.Vehicle:GetEngineHealth() <= 0)
		then
			SafeRemoveEntity(self)
			return false
		end

		-- If all NPCs have died
		if #self.DeadNPCs >= self.MaxNPCs then
			SafeRemoveEntity(self)
			return false
		end

		return true
	end

	-- Only returns amount of non-NULL entities in a table
	function countTableValid(tab)
		local count = 0
		for _, value in ipairs(tab) do
			if IsValid(value) then
				count = count + 1
			end
		end

		return count
	end

	-- NPC spawning management
	function spawnNPCs(self, dirVector)
		if countTableValid(self.NPCs) <= 0 and npcsEnabled:GetBool() then
			local npcList = list.Get("NPC")
			if not npcList[self.NPCClass] then
				self.NPCClass = "npc_metropolice"
			end

			-- Get the NPC's default weapons
			local npcWeapons = { "weapon_pistol" }
			if npcList[self.NPCClass].Weapons then
				npcWeapons = npcList[self.NPCClass].Weapons
			end

			if self.NPCWeaponClass ~= "" then
				npcWeapons = { self.NPCWeaponClass }
			end

			local function createNPC(seatIndex)
				local npc = ents.Create(self.NPCClass)
				if npc then
					-- Should make metrocops "arrest" players, which means that they will hold off on shooting for a short period, but it hasn't worked in testing
					if self.NPCClass == "npc_metropolice" then
						npc:AddSpawnFlags(2097152)
					end

					-- Give the NPC a random weapon from the weapon list
					npc:Give(npcWeapons[math.floor(math.Rand(1, #npcWeapons))])

					npc:Spawn()

					if self.VehicleType == 1 then
						local npcMin, npcMax = npc:GetModelRenderBounds()

						local npcSizeY = Vector(0, npcMin.y, 0):Distance(Vector(0, npcMax.y, 0))
						local npcSizeZ = Vector(0, 0, npcMin.z):Distance(Vector(0, 0, npcMax.z))

						local addedVector = Vector(0, (self.SizeY * 0.75) + npcSizeY, 0)
						if seatIndex >= 2 then
							addedVector = addedVector * -1
						end
						addedVector:Rotate(self.Vehicle:GetAngles())

						local traceHitPos = util.TraceLine({
							start = self.VehicleCenter + addedVector,
							endpos = (self.VehicleCenter + addedVector) - (vector_up * npcSizeZ),
							filter = traceFilter
						}).HitPos

						npc:SetPos(traceHitPos + Vector(0, 0, npcSizeZ * 0.25))
					elseif self.VehicleType == 2 then
						npc:SetPos(self.Vehicle:GetSeatExitPos(seatIndex))
					end

					if dirVector then
						npc:SetAngles((dirVector * -1):Angle())
					else
						npc:SetAngles(self.Vehicle:GetAngles())
					end

					-- Perform a spawn effect
					if spawnEffects:GetBool() then
						local effectData = EffectData()
						effectData:SetEntity(npc)
						util.Effect("propspawn", effectData)
					end

					table.insert(self.NPCs, npc)
				end
			end

			local seatIndex = 0
			local allowed = self.MaxNPCs
			if self.VehicleType == 1 then
				allowed = math.Clamp(allowed, 1, 2)
			end
			for i = 1, allowed do
				if #self.DeadNPCs >= i then
					continue
				end
				seatIndex = seatIndex + 1
				createNPC(seatIndex)
			end
		end
	end

	-- Moves segment positions if they're too close to walls
	function validateSegments(self, segments)
		local newSegments = {}

		local length = self.SizeY * 2
		local extraHeight = 10

		local northVector = Vector(length, 0, extraHeight)
		local southVector = Vector(-length, 0, extraHeight)

		local eastVector = Vector(0, length, extraHeight)
		local westVector = Vector(0, -length, extraHeight)

		local function newDir(pos, offset)
			local trace = util.TraceLine({
				start = pos + Vector(0, 0, extraHeight),
				endpos = pos + offset,
				mask = MASK_SOLID_BRUSHONLY
			})
			if trace.Hit then
				return (trace.HitPos - Vector(0, 0, extraHeight)) + (trace.HitNormal * length)
			end
		end

		local function newDirLerped(pos, offset1, offset2)
			local trace1 = util.TraceLine({
				start = pos + Vector(0, 0, extraHeight),
				endpos = pos + offset1,
				mask = MASK_SOLID_BRUSHONLY
			})
			local trace2 = util.TraceLine({
				start = pos + Vector(0, 0, extraHeight),
				endpos = pos + offset2,
				mask = MASK_SOLID_BRUSHONLY
			})
			if trace1.Hit and trace2.Hit then
				local lerpedVector = LerpVector(
					0.5,
					(trace1.HitPos - Vector(0, 0, extraHeight)) + (trace1.HitNormal * length),
					(trace2.HitPos - Vector(0, 0, extraHeight)) + (trace2.HitNormal * length)
				)
				return lerpedVector
			end
		end

		for _, segment in ipairs(segments) do
			local pos = Vector(segment.pos.x, segment.pos.y,
				segment.area:GetCenter().z + (segment.area:GetExtentInfo().SizeZ * 0.5))

			local north = newDir(pos, northVector)
			local south = newDir(pos, southVector)
			if north and not south then
				pos = north
			elseif not north and south then
				pos = south
			elseif north and south then
				pos = newDirLerped(pos, northVector, southVector)
			end

			local east = newDir(pos, eastVector)
			local west = newDir(pos, westVector)
			if east and not west then
				pos = east
			elseif not east and west then
				pos = west
			elseif east and west then
				pos = newDirLerped(pos, eastVector, westVector)
			end

			table.insert(newSegments, {
				area = segment.area,
				pos = Vector(pos.x, pos.y, segment.pos.z)
			})
		end

		return newSegments
	end

	-- Uses NextBot pathfinding
	function pathfind(self, goal)
		if not self.Path then
			self.Path = Path("Follow")
		end
		if not IsValid(self.Path) or self.Path:GetAge() >= 2.5 or (self.PathSegments and self.PathIndex >= #self.PathSegments) then
			local targetPos = self.EnemyCenter
			local nearestArea = navmesh.GetNearestNavArea(targetPos)
			if IsValid(nearestArea) then
				targetPos = nearestArea:GetClosestPointOnArea(targetPos) or targetPos
			end
			self.Path:Compute(self, targetPos, function(area, fromArea, ladder, elevator, length)
				if not IsValid(fromArea) then
					return 0
				else
					if IsValid(ladder) or IsValid(elevator) then
						return -1
					end

					if area:IsUnderwater() then
						return -1
					end

					if not self.loco:IsAreaTraversable(area) then
						return -1
					end

					local deltaZ = fromArea:ComputeAdjacentConnectionHeightChange(area)

					if deltaZ >= self.loco:GetStepHeight() then
						return -1
					end

					if deltaZ > self.loco:GetMaxJumpHeight() then
						return -1
					end

					if deltaZ <= -self.loco:GetDeathDropHeight() then
						return -1
					end

					--[[if area:GetSizeX() < self.SizeY or area:GetSizeY() < self.SizeY then
						return -1
					end]]

					local dist = (length > 0 and length) or (area:GetCenter() - fromArea:GetCenter()):Length()

					local cost = dist + fromArea:GetCostSoFar()

					return cost
				end
			end)
			self.PathIndex = 1
			if IsValid(self.Path) then
				self.PathStatus = "success"
				self.PathSegments = validateSegments(self, self.Path:GetAllSegments())
			else
				self.PathStatus = "failed"
			end
		end
	end

	-- Determines the furthest visible segment within the specified path
	function getFurthestSegment(self)
		local furthest = 1
		for i, segment in ipairs(table.Reverse(self.PathSegments)) do
			local trace = util.TraceHull({
				start = self.VehicleCenter,
				endpos = segment.pos + Vector(0, 0, 10),
				mins = Vector(-self.SizeY * 0.25, -self.SizeY * 0.25, 0),
				maxs = Vector(self.SizeY * 0.25, self.SizeY * 0.25, 0),
				mask = MASK_SOLID_BRUSHONLY
			})

			-- Check for empty space or water between us and the segment
			local lerpedVector1 = LerpVector(
				0.25,
				self.VehicleCenter,
				segment.pos + Vector(0, 0, 10)
			)
			local lerpedVector2 = LerpVector(
				0.5,
				self.VehicleCenter,
				segment.pos + Vector(0, 0, 10)
			)
			local lerpedVector3 = LerpVector(
				0.75,
				self.VehicleCenter,
				segment.pos + Vector(0, 0, 10)
			)
			local spaceTrace1 = util.TraceLine({
				start = lerpedVector1,
				endpos = lerpedVector1 - Vector(0, 0, self.loco:GetDeathDropHeight()),
				mask = MASK_ALL
			})
			local spaceTrace2 = util.TraceLine({
				start = lerpedVector2,
				endpos = lerpedVector2 - Vector(0, 0, self.loco:GetDeathDropHeight()),
				mask = MASK_ALL
			})
			local spaceTrace3 = util.TraceLine({
				start = lerpedVector3,
				endpos = lerpedVector3 - Vector(0, 0, self.loco:GetDeathDropHeight()),
				mask = MASK_ALL
			})

			if not trace.Hit
					and spaceTrace1.Hit and spaceTrace1.MatType ~= MAT_SLOSH
					and spaceTrace2.Hit and spaceTrace2.MatType ~= MAT_SLOSH
					and spaceTrace3.Hit and spaceTrace3.MatType ~= MAT_SLOSH
			then
				furthest = #self.PathSegments - i + 1
				furthest = math.Clamp(furthest, 1, #self.PathSegments)
				break
			end
		end

		return furthest
	end

	function ENT:RunBehaviour()
		while true do
			-- Check overall validity
			if not self:ValidateSelf() then
				return
			end

			setProperties(self)

			local enemyValidated = PursuitAiPlayer:Validate(self.Enemy, self.Vehicle, pursuitRange)

			self.VehicleCenter = self.Vehicle:WorldSpaceCenter()
			self.EnemyCenter = enemyValidated and self.Enemy:WorldSpaceCenter()

			self:SetPos(self.Vehicle:GetPos())
			self:SetAngles(self.Vehicle:GetAngles())

			local addedVector1 = Vector(self.SizeX * 0.5, 0, 0)
			local addedVector2 = Vector(-self.SizeX * 0.5, 0, 0)

			addedVector1:Rotate(self.Vehicle:GetAngles())
			addedVector2:Rotate(self.Vehicle:GetAngles())

			self.VehicleFront = self.VehicleCenter + addedVector1
			self.VehicleBack = self.VehicleCenter + addedVector2

			local function addToDead(npc)
				local inDeadNPCs = false
				for _, deadNPC in ipairs(self.DeadNPCs) do
					if npc == deadNPC then
						inDeadNPCs = true
						break
					end
				end
				if not inDeadNPCs then
					table.insert(self.DeadNPCs, npc)
				end
			end

			-- NPC death/despawning management
			if enemyValidated then
				local count = 0
				for i, npc in ipairs(self.NPCs) do
					if IsValid(npc) then
						if self.EnemyCenter:Distance2DSqr(npc:WorldSpaceCenter()) >= npcDespawnRange:GetFloat() ^ 2 then
							count = count + 1
						else
							if not npc:Alive() then
								addToDead(npc)
							end
						end
					else
						local inRemovedNPCs = false
						for _, removedNPC in ipairs(self.RemovedNPCs) do
							if npc == removedNPC then
								inRemovedNPCs = true
								break
							end
						end
						if not inRemovedNPCs then
							addToDead(npc)
						end
					end
				end
				if count >= countTableValid(self.NPCs) then
					for i, npc in ipairs(self.NPCs) do
						if IsValid(npc) then
							table.insert(self.RemovedNPCs, npc)
							SafeRemoveEntity(npc)
						end
					end
				end
			end

			-- If we don't have an enemy or we have NPCs spawned
			if not enemyValidated or countTableValid(self.NPCs) > 0 then
				-- Stop moving
				if self.VehicleType == 1 then
					self.Vehicle.PressedKeys["W"] = false
					self.Vehicle.PressedKeys["A"] = false
					self.Vehicle.PressedKeys["S"] = false
					self.Vehicle.PressedKeys["D"] = false
					self.Vehicle.PressedKeys["Shift"] = false
					self.Vehicle.PressedKeys["Space"] = true
				elseif self.VehicleType == 2 then
					self.Vehicle:SetInputFloat(1, "accelerate", 0)
					self.Vehicle:SetInputFloat(1, "brake", 0)
					self.Vehicle:SetInputBool(1, "handbrake", true)
				end

				-- Reset moving variables so we don't reverse when we pursue again
				self.LastMovingTime = CurTime()
				self.LastMovingTimeTeleport = CurTime()
				self.LastNonStoppingTime = CurTime()

				-- Turn off ELS and/or sirens
				if self.VehicleType == 1 then
					if self.LightsList and self.LightsList.ems_sounds then
						if not enemyValidated then
							if self.Vehicle:GetEMSEnabled() then
								self.Vehicle.emson = false
								self.Vehicle:SetEMSEnabled(false)
							end
						end
						if self.Vehicle.ems and self.Vehicle.ems:IsPlaying() then
							self.Vehicle.ems:Stop()
						end
					end
				elseif self.VehicleType == 2 then
					if self.Vehicle.CanSwitchSiren then
						local newSirenState = 0
						if enemyValidated then
							newSirenState = 1
						end
						if self.Vehicle:GetSirenState() ~= newSirenState then
							self.Vehicle:ChangeSirenState(newSirenState)
						end
					end
				end

				-- Look for another enemy
				if not enemyValidated then
					local enemy = PursuitAiEntSearch:TargetEnemy({
						lastEnemySearchTime = self.LastEnemySearchTime,
						cachedEnemy = self.CachedEnemy,
						vehicle = self.Vehicle,
						vehicleCenter = self.VehicleCenter,
						pursuitRange = pursuitRange
					})
					if IsValid(enemy) then
						self.Enemy = enemy
					end
				end
			else
				-- Turn on ELS/sirens
				if self.VehicleType == 1 then
					if self.LightsList and self.LightsList.ems_sounds then
						if not self.Vehicle:GetEMSEnabled() then
							self.Vehicle.emson = true
							self.Vehicle:SetEMSEnabled(true)
						end
						if not self.Vehicle.ems or not self.Vehicle.ems:IsPlaying() then
							self.Vehicle.cursound = math.floor(math.Rand(1, table.Count(self.LightsList.ems_sounds)))
							self.Vehicle.ems = CreateSound(self.Vehicle, self.LightsList.ems_sounds[self.Vehicle.cursound])
							self.Vehicle.ems:Play()
						end
					end
				elseif self.VehicleType == 2 then
					if self.Vehicle.CanSwitchSiren then
						if self.Vehicle:GetSirenState() ~= 2 then
							self.Vehicle:ChangeSirenState(2)
						end
					end
				end

				-- Some movement variables
				local goal = self.EnemyCenter
				local PIT = false
				local maxSpeed = math.huge
				local enemyVisible = true

				-- Vehicle's forward vector
				local forward = nil
				if self.VehicleType == 1 then
					forward = self.Vehicle:LocalToWorldAngles(self.Vehicle.VehicleData.LocalAngForward):Forward() * -1
				elseif self.VehicleType == 2 then
					forward = self.Vehicle:GetForward() * -1
				end

				-- Distance between the vehicle and the enemy
				local distance = self.VehicleCenter - self.EnemyCenter

				-- If there isn't a navmesh, assume the enemy is always visible
				if navmesh.IsLoaded() then
					-- Check for any worldspawn collisions
					local worldTrace = util.TraceHull({
						start = self.VehicleCenter,
						endpos = self.EnemyCenter,
						mins = Vector(-self.SizeY * 0.75, -self.SizeY * 0.75, 0),
						maxs = Vector(self.SizeY * 0.75, self.SizeY * 0.75, 0),
						mask = MASK_SOLID_BRUSHONLY
					})

					-- Check for empty space or water between us and the target
					local lerpedVector1 = LerpVector(
						0.25,
						self.VehicleCenter,
						self.EnemyCenter
					)
					local lerpedVector2 = LerpVector(
						0.5,
						self.VehicleCenter,
						self.EnemyCenter
					)
					local lerpedVector3 = LerpVector(
						0.75,
						self.VehicleCenter,
						self.EnemyCenter
					)
					local spaceTrace1 = util.TraceLine({
						start = lerpedVector1,
						endpos = lerpedVector1 - Vector(0, 0, self.loco:GetDeathDropHeight()),
						mask = MASK_ALL
					})
					local spaceTrace2 = util.TraceLine({
						start = lerpedVector2,
						endpos = lerpedVector2 - Vector(0, 0, self.loco:GetDeathDropHeight()),
						mask = MASK_ALL
					})
					local spaceTrace3 = util.TraceLine({
						start = lerpedVector3,
						endpos = lerpedVector3 - Vector(0, 0, self.loco:GetDeathDropHeight()),
						mask = MASK_ALL
					})

					-- Check all traces
					if worldTrace.Hit
							or not spaceTrace1.Hit or spaceTrace1.MatType == MAT_SLOSH
							or not spaceTrace2.Hit or spaceTrace2.MatType == MAT_SLOSH
							or not spaceTrace3.Hit or spaceTrace3.MatType == MAT_SLOSH
					then
						enemyVisible = false
					end
				end

				if not enemyVisible then
					-- DEBUG: Show vehicle's hitbox
					debugoverlay.BoxAngles(self.Vehicle:GetPos(), self.MinBounds, self.MaxBounds, self.Vehicle:GetAngles(), 1 / 30,
						Color(255, 0, 0, 127), true)

					pathfind(
						self,
						goal
					)

					if self.PathStatus == "success" then
						-- DEBUG: Highlight entire path
						if GetConVar("developer"):GetFloat() == 1 then
							self.Path:Draw()
							for _, segment in ipairs(self.PathSegments) do
								segment.area:Draw()
							end
						end

						-- Change our PathIndex to the furthest visible segment within the path
						local furthestSegment = getFurthestSegment(self)
						if furthestSegment > self.PathIndex then
							self.PathIndex = furthestSegment
						end

						goal = self.PathSegments[self.PathIndex].pos
					end
				else
					if IsValid(self.Path) then
						self.Path:Invalidate()
					end
				end

				-- Determine if the enemy is in a vehicle
				local enemyVehicle = false
				local vehicleSpeed = 0
				if isfunction(self.Enemy.GetVehicle) and IsValid(self.Enemy:GetVehicle()) then
					enemyVehicle = self.Enemy:GetVehicle()
					vehicleSpeed = enemyVehicle:GetVelocity():Length2D()
				end
				if isfunction(self.Enemy.GetSimfphys) and IsValid(self.Enemy:GetSimfphys()) then
					enemyVehicle = self.Enemy:GetSimfphys()
					vehicleSpeed = enemyVehicle:GetVelocity():Length2D()
				end
				if isfunction(self.Enemy.GlideGetVehicle) and IsValid(self.Enemy:GlideGetVehicle()) then
					enemyVehicle = self.Enemy:GlideGetVehicle()
					vehicleSpeed = enemyVehicle:GetVelocity():Length2D()
				end

				-- Vehicle braking and PIT behavior
				if not enemyVehicle then
					if not npcsEnabled:GetBool() or distance:Length2DSqr() >= npcDespawnRange:GetFloat() ^ 2 then
						self.Stopping = false
					end
				else
					self.Stopping = false
				end
				if not aggressive:GetBool() or not enemyVehicle then
					if math.abs(vehicleSpeed) < 600 then
						if distance:LengthSqr() <= math.Clamp(math.abs(self.Vehicle:GetVelocity():Length2D() * 2), self.SizeX + 500, math.huge) ^ 2 then
							self.Stopping = false
						end
					else
						if enemyVisible and distance:Length2DSqr() <= 1000 ^ 2 then
							PIT = true

							-- Get a position on the side of the enemy's vehicle
							local enemyMin, enemyMax = enemyVehicle:GetModelRenderBounds()

							local enemySizeX = Vector(enemyMin.x, 0, 0):Distance(Vector(enemyMax.x, 0, 0))
							local enemySizeY = Vector(0, enemyMin.y, 0):Distance(Vector(0, enemyMax.y, 0))

							local addedVector1 = Vector(-enemySizeX * 0.25, ((enemySizeY * 0.5) + (self.SizeY * 0.625)), 0)
							local addedVector2 = Vector(-enemySizeX * 0.25, -((enemySizeY * 0.5) + (self.SizeY * 0.625)), 0)

							addedVector1:Rotate(enemyVehicle:GetAngles())
							addedVector2:Rotate(enemyVehicle:GetAngles())

							local newGoal1 = enemyVehicle:WorldSpaceCenter() + addedVector1
							local newGoal2 = enemyVehicle:WorldSpaceCenter() + addedVector2

							local newGoal = nil

							if self.VehicleCenter:Distance2DSqr(newGoal1) <= self.VehicleCenter:Distance2DSqr(newGoal2) then
								newGoal = newGoal1
							else
								newGoal = newGoal2
							end

							if self.VehicleCenter:Distance2DSqr(newGoal) > self.SizeY ^ 2 then
								local secondsSinceLastPIT = (self.LastPITTime and CurTime() - self.LastPITTime) or math.huge
								if secondsSinceLastPIT > 5 then
									goal = newGoal
								elseif secondsSinceLastPIT <= 2.5 then
									if newGoal == newGoal1 then
										newGoal = newGoal2
									else
										newGoal = newGoal1
									end
									goal = newGoal
								end
							else
								self.LastPITTime = CurTime()
								if newGoal == newGoal1 then
									newGoal = newGoal2
								else
									newGoal = newGoal1
								end
								goal = newGoal
							end
							maxSpeed = vehicleSpeed + 200

							-- DEBUG: Show PIT position
							debugoverlay.Sphere(newGoal, 10, 1 / 30, nil, true)
						end
					end
				else
					if math.abs(vehicleSpeed) < 300 then
						if distance:LengthSqr() <= (self.SizeX + 100) ^ 2 then
							self.Stopping = true
						end
					end
				end

				-- Slam on the brakes if we're too close to another AI
				local nearPursuitAI = false
				for _, targetPursuitAI in ipairs(ents.FindByClass("npc_pursuitai")) do
					if targetPursuitAI ~= self
							and not (targetPursuitAI.NearPursuitAI and targetPursuitAI.NearPursuitAI == self)
							and not targetPursuitAI.ObstacleInFront
							and targetPursuitAI.Vehicle
							and ((targetPursuitAI.VehicleType == 1 and targetPursuitAI.Vehicle:EngineActive()) or (targetPursuitAI.VehicleType == 2 and targetPursuitAI.Vehicle:IsEngineOn()))
					then
						local targetVehicleCenter = targetPursuitAI.Vehicle:WorldSpaceCenter()
						local distanceToTarget = self.VehicleCenter:Distance2DSqr(targetVehicleCenter)
						if distanceToTarget <= math.Clamp(math.abs(self.Vehicle:GetVelocity():Length2D() * 2), self.SizeX + 100, math.huge) ^ 2 then
							local otherVector = (self.VehicleCenter - Vector(targetVehicleCenter.x, targetVehicleCenter.y, self.VehicleCenter.z))
									:GetNormalized()
							if forward:Dot(otherVector) >= 0.75 then
								nearPursuitAI = targetPursuitAI
								break
							end
						end
					end
				end
				self.NearPursuitAI = nearPursuitAI
				if nearPursuitAI then
					self.Stopping = true
				end

				-- Enemy direction vector
				local dirVector = (self.VehicleCenter - Vector(goal.x, goal.y, self.VehicleCenter.z)):GetNormalized()

				local throttle = 1
				local rightSide = dirVector:Cross(forward)
				local steerAmount = rightSide:Length()
				local steer = (rightSide.z < 0 and -steerAmount) or steerAmount

				-- Turn around if the enemy is behind us
				if forward:Dot(dirVector) < 0 then
					if rightSide.z < 0 then
						steer = -1
					else
						steer = 1
					end
				end

				-- Reverse if there's something in front of us using a hull trace
				self.ObstacleInFront = false

				local addedVector = Vector(self.SizeX * 0.5, 0, 0)
				local traceMins = Vector(-self.SizeY * 0.5, -self.SizeY * 0.5, 0)
				local traceMaxs = Vector(self.SizeY * 0.5, self.SizeY * 0.5, 0)

				addedVector:Rotate(self.Vehicle:GetAngles())

				local trace = util.TraceHull({
					start = self.VehicleCenter + addedVector,
					endpos = self.VehicleCenter + addedVector + forward * -25,
					mins = traceMins,
					maxs = traceMaxs,
					mask = MASK_SOLID_BRUSHONLY
				})
				if trace.Hit then
					self.ObstacleInFront = true
					self.Reversing = true
					self.ReversingSavedAngles = self.Vehicle:GetAngles()
				end

				-- Also reverse if we're stuck
				if math.abs(self.Vehicle:GetVelocity():Length2D()) >= 25 or self.Stopping or (not enemyVisible and self.PathStatus == "failed") then
					self.LastMovingTime = CurTime()
					self.LastMovingTimeTeleport = CurTime()
				end
				if self.LastMovingTime and CurTime() - self.LastMovingTime >= 3 and not self.ReversingStuck then
					self.ReversingStuck = true
					timer.Simple(2, function()
						self.ReversingStuck = false
						self.LastMovingTime = CurTime()
					end)
				end

				-- If we're extra stuck, then teleport
				--[[if self.LastMovingTimeTeleport and CurTime() - self.LastMovingTimeTeleport >= 6 then
					local vehicleNavArea = navmesh.GetNearestNavArea(self.VehicleCenter)
					if vehicleNavArea then
						local teleportPos = vehicleNavArea:GetCenter() + Vector(0, 0, self.SizeZ)
						local wheelOffsets = {}
						local wheelAngles = {}
						for i, wheel in ipairs(self.Vehicle.Wheels) do
							wheelOffsets[i] = wheel:GetPos() - self.Vehicle:GetPos()
							wheelAngles[i] = wheel:GetAngles()
						end
						self.Vehicle:SetPos(teleportPos)
						self.Vehicle:SetLocalVelocity(vector_origin)
						self.Vehicle:SetLocalAngularVelocity(angle_zero)
						self.Vehicle.MassOffset:SetPos(teleportPos)
						self.Vehicle.MassOffset:SetLocalVelocity(vector_origin)
						for i, wheel in ipairs(self.Vehicle.Wheels) do
							wheel:SetPos(teleportPos + wheelOffsets[i])
							wheel:SetAngles(wheelAngles[i])
							wheel:SetLocalVelocity(vector_origin)
							wheel:SetLocalAngularVelocity(angle_zero)
						end
						self.LastMovingTimeTeleport = CurTime()
					end
				end]]

				-- If we're reversing, modify the throttle and keep checking for when to stop
				if self.Reversing or self.ReversingStuck then
					throttle = -1
					steer = steer * -1
					if self.Reversing then
						local trace = util.TraceHull({
							start = self.VehicleCenter + addedVector,
							endpos = self.VehicleCenter + addedVector + forward * (-self.SizeX * 0.5),
							mins = traceMins,
							maxs = traceMaxs,
							mask = MASK_SOLID_BRUSHONLY
						})

						if not trace.Hit then
							self.Reversing = false
							self.ReversingSavedAngles = nil
						end
					end
				end

				-- Slow down when not in direct pursuit or when reversing
				if not enemyVisible then
					maxSpeed = 600
				end

				-- If we are above a max speed, slow down
				if math.abs(self.Vehicle:GetVelocity():Length2D()) > maxSpeed then
					throttle = 0
				end

				-- If the vehicle is damaged, and the engine keeps shutting down, restart it
				if self.VehicleType == 1 then
					if not self.Vehicle:EngineActive() then
						self.Vehicle:SetActive(true)
						self.Vehicle:StartEngine()
					end
				elseif self.VehicleType == 2 then
					if not self.Vehicle:IsEngineOn() then
						self.Vehicle:TurnOn()
					end
				end

				-- Actually set the throttle
				if self.VehicleType == 1 then
					self.Vehicle.PressedKeys["Shift"] = true
					if self.Stopping or (not enemyVisible and self.PathStatus == "failed") then
						self.Vehicle.PressedKeys["W"] = false
						self.Vehicle.PressedKeys["S"] = false
						self.Vehicle.PressedKeys["Space"] = true
					else
						self.Vehicle.PressedKeys["W"] = throttle > 0
						self.Vehicle.PressedKeys["S"] = throttle < 0
						-- Use the handbrake if we won't make the turn (also for dramatic effect)
						if math.abs(self.Vehicle:GetVelocity():Length2D()) >= 600 and math.abs(steer) >= 0.75 then
							self.Vehicle.PressedKeys["Space"] = true
						else
							self.Vehicle.PressedKeys["Space"] = false
						end
					end
				elseif self.VehicleType == 2 then
					if self.Stopping or (not enemyVisible and self.PathStatus == "failed") then
						self.Vehicle:SetInputFloat(1, "accelerate", 0)
						self.Vehicle:SetInputFloat(1, "brake", 0)
						self.Vehicle:SetInputBool(1, "handbrake", true)
					else
						if throttle > 0 then
							self.Vehicle:SetInputFloat(1, "accelerate", 1)
							self.Vehicle:SetInputFloat(1, "brake", 0)
						elseif throttle < 0 then
							self.Vehicle:SetInputFloat(1, "accelerate", 0)
							self.Vehicle:SetInputFloat(1, "brake", 1)
						else
							self.Vehicle:SetInputFloat(1, "accelerate", 0)
							self.Vehicle:SetInputFloat(1, "brake", 0)
						end
						-- Use the handbrake if we won't make the turn (also for dramatic effect)
						if math.abs(self.Vehicle:GetVelocity():Length2D()) >= 600 and math.abs(steer) >= 0.75 then
							self.Vehicle:SetInputBool(1, "handbrake", true)
						else
							self.Vehicle:SetInputBool(1, "handbrake", false)
						end
					end
				end

				-- If the vehicle is spinning, don't change steering
				local physicsObject = self.Vehicle:GetPhysicsObject()
				if IsValid(physicsObject) and physicsObject:GetAngleVelocity().y > 120 then
					coroutine.yield()
				end

				-- If steer is close to 0, set steer to 0
				if math.abs(steer) <= 0.05 then
					steer = 0
				end

				-- If we're stopping, set steer to 0 to prevent tire weirdness
				if self.Stopping or (not enemyVisible and self.PathStatus == "failed") then
					steer = 0
				end

				-- Actually steer the vehicle
				if self.VehicleType == 1 then
					local leftSteer = (steer < 0 and math.abs(steer)) or 0
					local rightSteer = (steer > 0 and math.abs(steer)) or 0
					self.Vehicle:PlayerSteerVehicle(
						self,
						leftSteer,
						rightSteer
					)
				elseif self.VehicleType == 2 then
					self.Vehicle:SetInputFloat(1, "steer", steer)
				end

				-- Check for NPC spawning
				if not self.Stopping then
					self.LastNonStoppingTime = CurTime()
				end
				if CurTime() - self.LastNonStoppingTime >= 2.5 and distance:Length2DSqr() < npcDespawnRange:GetFloat() ^ 2 then
					spawnNPCs(self, dirVector)
				end
			end

			coroutine.yield()
		end
	end

	util.AddNetworkString("PursuitAI_ReplicateSettings")

	-- Prevents admins from setting random ConVars
	local whitelistedConVars = {
		"pursuitai_pursuitrange",
		"pursuitai_detectionrange",
		"pursuitai_spawneffects",
		"pursuitai_npcsenabled",
		"pursuitai_npcamount",
		"pursuitai_npcclass",
		"pursuitai_npcweaponclass",
		"pursuitai_npcdespawnrange",
		"pursuitai_aggressive"
	}

	net.Receive("PursuitAI_ReplicateSettings", function(length, plr)
		if not settingsEnabled:GetBool() then
			plr:ChatPrint("The ability to change pursuit AI settings from the spawnmenu has been disabled.")
			return
		end
		if not plr:IsAdmin() then
			plr:ChatPrint("You must be an admin to modify these settings.")
			return
		end
		local conVar = net.ReadString()
		if not conVar or conVar == "" then
			return
		end
		local whitelisted = false
		for _, whitelistedConVar in ipairs(whitelistedConVars) do
			if conVar == whitelistedConVar then
				whitelisted = true
				break
			end
		end
		if not whitelisted then
			return
		end
		local newValue = net.ReadString()
		if not newValue then
			return
		end
		GetConVar(conVar):SetString(newValue)
	end)
end

-- For Simfphys vehicles; returns default values because of a bug in :PlayerSteerVehicle()
function ENT:GetInfoNum(key, default)
	if key == "cl_simfphys_ctenable" then
		return 1
	elseif key == "cl_simfphys_ctmul" then
		return 0.7
	elseif key == "cl_simfphys_ctang" then
		return 15
	end

	return 0
end

-- Settings within the spawnmenu
hook.Add("PopulateToolMenu", "PursuitAISettings", function()
	if not settingsEnabled:GetBool() then
		return
	end
	spawnmenu.AddToolMenuOption("Options", "Pursuit AI", "Pursuit_AI_Settings", "Settings", "", "", function(panel)
		panel:Clear()

		panel:Help("You must be an admin to modify these settings.")

		local function createOption(data)
			if data.Type == "CheckBox" then
				local option = panel:CheckBox(data.Label, data.ConVar)
				function option:OnChange(value)
					if value == GetConVar(data.ConVar):GetBool() then
						return
					end
					net.Start("PursuitAI_ReplicateSettings")
					net.WriteString(data.ConVar)
					if not value then
						net.WriteString("0")
					else
						net.WriteString("1")
					end
					net.SendToServer()
				end
			elseif data.Type == "NumSlider" then
				local option = panel:NumSlider(data.Label, data.ConVar, data.Min, data.Max, data.Decimals)
				function option:OnValueChanged(value)
					if value == GetConVar(data.ConVar):GetFloat() then
						return
					end
					net.Start("PursuitAI_ReplicateSettings")
					net.WriteString(data.ConVar)
					net.WriteString(tostring(value))
					net.SendToServer()
				end
			elseif data.Type == "TextEntry" then
				local option = panel:TextEntry(data.Label, data.ConVar)
				function option:OnEnter(value)
					if value == GetConVar(data.ConVar):GetString() then
						return
					end
					net.Start("PursuitAI_ReplicateSettings")
					net.WriteString(data.ConVar)
					net.WriteString(value)
					net.SendToServer()
				end
			end
			local default = GetConVar(data.ConVar):GetDefault()
			if data.Type == "CheckBox" then
				default = (default == "1" and "true") or "false"
			end
			panel:ControlHelp("Default: " .. default .. "\n")
			panel:ControlHelp(data.HelpText)
		end

		createOption({
			Type = "NumSlider",
			Label = "Pursuit range",
			ConVar = "pursuitai_pursuitrange",
			Min = 0,
			Max = 32768,
			Decimals = 0,
			HelpText = "Any player within this distance from a pursuit AI will qe pursued."
		})

		createOption({
			Type = "NumSlider",
			Label = "Detection range",
			ConVar = "pursuitai_detectionrange",
			Min = 0,
			Max = 32768,
			Decimals = 0,
			HelpText =
			"A Simfphys or Glide vehicle within this distance from a pursuit AI enabler's initial spawn point will have pursuit AI enabled."
		})

		createOption({
			Type = "CheckBox",
			Label = "Spawn effects",
			ConVar = "pursuitai_spawneffects",
			HelpText =
			"Determines if a spawn effect should be made when a pursuit AI is initiated, and when a pursuit AI spawns an NPC."
		})

		createOption({
			Type = "CheckBox",
			Label = "NPCs enabled",
			ConVar = "pursuitai_npcsenabled",
			HelpText = "Determines if pursuit AI's should spawn NPCs when they get close to a player."
		})

		createOption({
			Type = "NumSlider",
			Label = "Amount of NPCs",
			ConVar = "pursuitai_npcamount",
			Min = 1,
			Max = 8,
			Decimals = 0,
			HelpText =
			"The amount of NPCs spawned by a pursuit AI.\n\nFor Simfphys vehicles, this is limited to a maximum of 2 at this time."
		})

		createOption({
			Type = "TextEntry",
			Label = "NPC",
			ConVar = "pursuitai_npcclass",
			HelpText =
			"The NPC class spawned by a pursuit AI.\n\nYou can get an NPC's class by right clicking on the target NPC in the spawn menu and then clicking \"Copy to clipboard\"."
		})

		createOption({
			Type = "TextEntry",
			Label = "NPC weapon",
			ConVar = "pursuitai_npcweaponclass",
			HelpText =
			"The weapon class given to an NPC when spawned by a pursuit AI. Leave empty to use a random weapon from the NPC.\n\nYou can get a weapon's class by right clicking on the target weapon in the spawn menu and then clicking \"Copy to clipboard\"."
		})

		createOption({
			Type = "NumSlider",
			Label = "NPC despawn range",
			ConVar = "pursuitai_npcdespawnrange",
			Min = 0,
			Max = 32768,
			Decimals = 0,
			HelpText = "If a player goes beyond this range from a pursuit AI's NPC, the NPC will be despawned."
		})

		createOption({
			Type = "CheckBox",
			Label = "Aggressive",
			ConVar = "pursuitai_aggressive",
			HelpText = "Determines if pursuit AI's should be more aggressive in direct pursuit."
		})
	end)
end)
