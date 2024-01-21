local RunService = game:GetService("RunService")
local ProjectileSniper = {}
ProjectileSniper.__index = ProjectileSniper

local path = game.ReplicatedFirst.Packages.Chickynoid
local EffectsModule = require(path.Client.Effects)
local WriteBuffer = require(path.Shared.Vendor.WriteBuffer)
local ReadBuffer = require(path.Shared.Vendor.ReadBuffer)
local Enums = require(path.Shared.Enums)


local isServer = false
if (game:GetService("RunService"):IsServer()) then
    isServer = true
end
local ServerFastProjectiles = nil
local ClientFastProjectiles = nil
local ServerMods = nil
if (isServer) then
	ServerFastProjectiles = require(game.ServerScriptService.Examples.ServerMods.ServerFastProjectiles)
	ServerMods = require(game.ServerScriptService.Packages.Chickynoid.Server.ServerMods)
end
if (isServer ~= true) then
    ClientFastProjectiles = require(game.ReplicatedFirst.Examples.ClientMods.ClientFastProjectiles)
end


function ProjectileSniper.new()
    local self = setmetatable({
		rateOfFire = 0.5,
		bulletDrop = -0.2,
		bulletSpeed = 600, 
        bulletMaxDistance = 600,
        serial = nil,
        name = nil,
        client = nil,
        weaponModule = nil,
        clientState = nil,
        serverState = nil,
        preservePredictedStateTimer = 0,
        serverStateDirty = false,
        playerRecord = nil,
        state = {},
        previousState = {},
    }, ProjectileSniper)
    return self
end

--This module is cloned per player on client/server
function ProjectileSniper:ClientThink(_deltaTime)
    local gui = self.client:GetGui()
    local state = self.clientState

    local counter = gui:FindFirstChild("AmmoCounter", true)
    if counter then
        counter.Text = state.ammo .. " / " .. state.maxAmmo
    end
end

function ProjectileSniper:ClientProcessCommand(command)
    local currentTime = self.totalTime
    local state = self.clientState

    --Predict firing a bullet
    if command.f and command.f > 0 and command.fa then
        if state.ammo > 0 and currentTime > state.nextFire then
            --put weapon on cooldown
            state.ammo -= 1
            state.nextFire = currentTime + state.fireDelay
            self:SetPredictedState() --Flag that we predicted the state, this will stop the server value from overriding it for a moment (eg: firing rapidly)

            local clientChickynoid = self.client:GetClientChickynoid()
            if clientChickynoid then
                local origin = clientChickynoid.simulation.state.pos
                local dest = command.fa

                local vec = (dest - origin).Unit

                --Do some local effects
                local clone = EffectsModule:SpawnEffect("Tracer", origin + vec * 2)
                clone.CFrame = CFrame.lookAt(origin, origin + vec)

                local bulletRecord = ClientFastProjectiles:FireBullet(origin, vec, self.bulletSpeed, self.bulletMaxDistance, self.bulletDrop, -1)

                --on the client, do an approximate collision check for our own bullets (not *required* but its here for completeness)
                bulletRecord.DoCollisionCheck = function(record, old, new)
                    return self:DoClientBulletCheck(record, old, new)
                end
            end
        end
    end
end

function ProjectileSniper:DoClientBulletCheck(_bulletRecord, old, new)
    local ray = RaycastParams.new()
    ray.FilterType = Enum.RaycastFilterType.Include
    ray.FilterDescendantsInstances = { game.Workspace.GameArea }
    local vec = (new-old)
    local results = game.Workspace:Raycast(old, vec, ray)
    if (results ~= nil) then
        return results
    end
    return nil
end

function ProjectileSniper:ClientSetup() end

function ProjectileSniper:ClientEquip() end

function ProjectileSniper:ClientDequip() end

--Warning! - you might not have this weapon locally
--This is far more akin to a static method, and is provided so you can render client effects
function ProjectileSniper:ClientOnBulletImpact(_client, event) 

   --WeaponModule
   if event.normal then
        if event.surface == 0 then
            local effect = EffectsModule:SpawnEffect("ImpactWorld", event.position)
            local cframe = CFrame.lookAt(event.position, event.position + event.normal)
            effect.CFrame = cframe
        end
        if event.surface == 1 then
            local effect = EffectsModule:SpawnEffect("ImpactPlayer", event.position)
            local cframe = CFrame.lookAt(event.position, event.position + event.normal)
            effect.CFrame = cframe
        end
    end
    ClientFastProjectiles:TerminateBullet(event.bulletId)

end


function ProjectileSniper:ClientOnBulletFire(_client, event) 
    --Fired a bullet

    if (event.player.userId ~= game.Players.LocalPlayer.UserId) then
        local clone = EffectsModule:SpawnEffect("Tracer", event.origin + event.vec * 2)
        clone.CFrame = CFrame.lookAt(event.origin, event.origin + event.vec)
        
        ClientFastProjectiles:FireBullet(event.origin, event.vec, event.speed, event.maxDistance, event.drop, event.bulletId)
    end

    
end


function ProjectileSniper:ServerSetup()
    self.state.maxAmmo = 10
    self.state.ammo = self.state.maxAmmo
    self.state.fireDelay = self.rateOfFire
    self.state.nextFire = 0 --Questionable about wether client needs this

    self.timeOfLastShot = 0 --Not part of state, doesnt need to go to client
end

function ProjectileSniper:ServerThink(_deltaTime)
    --update cooldowns

    local currentTime = self.totalTime
    local state = self.state

    --Auto reload
    if state.ammo == 0 and currentTime > self.timeOfLastShot + 2 then
        state.ammo = state.maxAmmo
    end
end

function ProjectileSniper:ServerProcessCommand(command)
    --actually Fire a bullet
    local currentTime = self.totalTime
    local state = self.state

    if command.f and command.f > 0 and command.fa then
        if state.ammo > 0 and currentTime > state.nextFire then
            --put weapon on cooldown
            state.ammo -= 1
            state.nextFire = currentTime + state.fireDelay

            self.timeOfLastShot = currentTime
 
            local serverChickynoid = self.playerRecord.chickynoid
            if serverChickynoid then
                local origin = serverChickynoid.simulation.state.pos
                local dest = command.fa
                local vec = (dest - origin).Unit
              
                local speed = self.bulletSpeed
                local maxDistance = self.bulletMaxDistance
                local drop = self.bulletDrop -- units per second
                

                local raycastParams = nil

                --Make the thing that does the thing
                local bulletRecord = ServerFastProjectiles:FireBullet(origin, vec, speed, maxDistance, drop, command.serverTime)
                
                bulletRecord.DoCollisionCheck = function(bulletRecord, old, new)
                    --Math to do the collision check
                    local vec = (new - old).Unit
                    local range = (new - old).Magnitude
                    local pos, normal, otherPlayer = self.weaponModule:QueryBullet(
                        self.playerRecord,
                        self.server,
                        old,
                        vec,
                        bulletRecord.serverTime,
                        nil,
                        raycastParams, 
                        range
                    )
             
                    if (normal ~= nil) then --hit something
                    
                        local surface = 0 --Surface type
                        if otherPlayer then
                            surface = 1 --(blood!)
                        end          
                        bulletRecord.die = true
                        bulletRecord.surface = surface
                        bulletRecord.position = pos
                        bulletRecord.normal = normal
						bulletRecord.otherPlayer = otherPlayer
                    end
                end
                bulletRecord.OnBulletDie = function(bulletRecord)
                    local event = {}
                    event.t = Enums.EventType.BulletImpact
                    event.b = self:BuildImpactPacketString(bulletRecord.position, bulletRecord.normal, bulletRecord.surface, bulletRecord.bulletId)
					
					self.playerRecord:SendEventToClients(event)
					
					--Do the damage
					if bulletRecord.otherPlayer then
						--Use the hitpoints mod to damage them!
						local HitPoints = ServerMods:GetMod("servermods", "Hitpoints")
						if HitPoints then
							HitPoints:DamagePlayer(bulletRecord.otherPlayer, 50)
						end
					end
                end

                --Send an event to render this firing
                local event = {}
                event.t = Enums.EventType.BulletFire
                event.b = self:BuildFirePacketString(origin, vec, speed, maxDistance, drop, bulletRecord.bulletId)

                self.playerRecord:SendEventToClients(event)
            end
        end
    end
end

function ProjectileSniper:BuildImpactPacketString(position, normal, surface, bulletId)
    local buf = WriteBuffer.new()
    
    --these two first always
    buf:WriteI16(self.weaponId)
	buf:WriteU8(self.playerRecord.slot)
    
    
    buf:WriteVector3(position)
    buf:WriteI16(bulletId)


    if (normal) then
        buf:WriteU8(1)
		buf:WriteVector3(normal)
		buf:WriteU8(surface)
    else
        buf:WriteU8(0)
    end
    return buf:GetBuffer()
end

function ProjectileSniper:BuildFirePacketString(origin, vec, speed, maxDistance, drop, bulletId)
    local buf = WriteBuffer.new()
    
	--these two first always
	buf:WriteI16(self.weaponId)
	buf:WriteU8(self.playerRecord.slot)
    
	buf:WriteVector3(origin)
	buf:WriteVector3(vec)
	buf:WriteFloat16(speed)
	buf:WriteFloat16(maxDistance)
	buf:WriteFloat16(drop)
	buf:WriteI16(bulletId)
    
    return buf:GetBuffer()
end

function ProjectileSniper:UnpackPacket(event)

    if (event.t == Enums.EventType.BulletImpact) then
		
		local buf = ReadBuffer.new(event.b)
        
        --these two first always
		event.weaponID = buf:ReadI16()
		event.slot = buf:ReadU8()

		event.position = buf:ReadVector3()
		event.bulletId = buf:ReadI16()
      

		local hasNormal = buf:ReadU8()
        if (hasNormal > 0) then
			event.normal = buf:ReadVector3()
			event.surface = buf:ReadU8()
        end

        return event
    elseif (event.t == Enums.EventType.BulletFire) then
		local buf = ReadBuffer.new(event.b)
        
        --these two first always
        event.weaponID = buf:ReadI16()
		event.slot = buf:ReadU8()
        
		event.origin = buf:ReadVector3()
		event.vec = buf:ReadVector3()
		event.speed = buf:ReadFloat16()
		event.maxDistance = buf:ReadFloat16()
		event.drop = buf:ReadFloat16()
		event.bulletId = buf:ReadI16()
        return event
    end
end

 

function ProjectileSniper:ServerEquip() end

function ProjectileSniper:ServerDequip() end

function ProjectileSniper:ClientRemoved() end

function ProjectileSniper:ServerRemoved() end


return ProjectileSniper