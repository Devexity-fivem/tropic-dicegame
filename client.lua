QBCore = exports['qb-core']:GetCoreObject()

local spawnedNPCs = {} 
local rollCounter = 0 

-- Helper function to load a model
local function loadModel(model)
    local modelHash = GetHashKey(model)
    if not IsModelValid(modelHash) then
        print("Invalid model: " .. tostring(model))
        return nil
    end
    RequestModel(modelHash)
    while not HasModelLoaded(modelHash) do
        Wait(10)
    end
    return modelHash
end

-- Helper function to load an animation dictionary
local function loadAnimDict(dict)
    RequestAnimDict(dict)
    while not HasAnimDictLoaded(dict) do
        Wait(10)
    end
end

-- Helper function to create a blip for an NPC
local function createBlip(coords, blipData)
    local blip = AddBlipForCoord(coords.x, coords.y, coords.z)
    SetBlipSprite(blip, blipData.sprite)
    SetBlipDisplay(blip, 4)
    SetBlipScale(blip, blipData.scale)
    SetBlipColour(blip, blipData.color)
    SetBlipAsShortRange(blip, true)
    BeginTextCommandSetBlipName("STRING")
    AddTextComponentString(blipData.label)
    EndTextCommandSetBlipName(blip)
end

-- Helper function to reset all NPCs to their default animations
local function resetNPCsToAnimation()
    for _, npcData in pairs(spawnedNPCs) do
        if npcData and npcData.ped and DoesEntityExist(npcData.ped) then
            TaskStartScenarioInPlace(npcData.ped, npcData.animation, 0, true)
        end
    end
end

-- Spawn all configured NPCs
Citizen.CreateThread(function()
    if not Config.NPCs then
        print("No NPC configuration found!")
        return
    end

    for _, npc in ipairs(Config.NPCs) do
        local pedHash = loadModel(npc.model)
        if pedHash then
            local ped = CreatePed(4, pedHash, npc.coords.x, npc.coords.y, npc.coords.z, npc.coords.w or 0.0, false, true)
            TaskStartScenarioInPlace(ped, npc.animation, 0, true)

            FreezeEntityPosition(ped, true)
            SetEntityInvincible(ped, true)
            SetBlockingOfNonTemporaryEvents(ped, true)
            SetPedFleeAttributes(ped, 0, 0)
            SetPedCombatAttributes(ped, 46, true)
            
            table.insert(spawnedNPCs, {ped = ped, animation = npc.animation})

            if npc.blip and npc.blip.enabled then
                createBlip(npc.coords, npc.blip)
            end

            if npc.targetable then
                exports.ox_target:addLocalEntity(ped, {
                    {
                        name = "dice_gamble",
                        label = "Play Dice",
                        icon = "fas fa-dice",
                        distance = 3.0,
                        onSelect = function()
                            openBetMenu(ped)
                        end
                    }
                })
            end
        end
    end
end)

AddEventHandler('onResourceStop', function(resource)
    if resource == GetCurrentResourceName() then
        for _, npcData in pairs(spawnedNPCs) do
            if npcData and npcData.ped and DoesEntityExist(npcData.ped) then
                DeleteEntity(npcData.ped)
            end
        end
        spawnedNPCs = {}
    end
end)

function openBetMenu(npcPed)
    local input = lib.inputDialog('Place Your Bet', {
        {type = 'number', label = 'Bet Amount', min = Config.minBet, max = Config.maxBet}
    })

    if input and input[1] then
        local betAmount = tonumber(input[1])
        if betAmount and betAmount >= Config.minBet and betAmount <= Config.maxBet then
            QBCore.Functions.TriggerCallback('tropic-dicegame:checkBet', function(canBet)
                if canBet then
                    startDiceGame(betAmount, npcPed)
                else
                    lib.notify({title = 'Not enough money!', type = 'error'})
                end
            end, betAmount)
        else
            lib.notify({title = 'Invalid Bet Amount!', type = 'error'})
        end
    else
        lib.notify({title = 'Bet was not placed!', type = 'error'})
    end
end

function rollDice()
    -- Simple dice roll: sum of two six-sided dice (2-12)
    return math.random(2, 12)
end

function startDiceGame(betAmount, npcPed)
    rollCounter = rollCounter + 1

    if rollCounter >= Config.maxRolls then
        -- If max rolls reached, randomly decide outcome
        local randomOutcome = math.random(1, 2)
        if randomOutcome == 1 then
            winGame(betAmount)
        else
            loseGame(betAmount)
        end
        return
    end

    playRollAnimation(PlayerPedId())
    Wait(Config.animation.duration)

    local playerRoll = rollDice()
    lib.notify({title = "You rolled a " .. playerRoll})

    if playerRoll == 7 or playerRoll == 11 then
        winGame(betAmount)
    else
        Wait(Config.rollDelay)
        npcRoll(betAmount, playerRoll, npcPed)
    end
end

function npcRoll(betAmount, playerRoll, npcPed)
    playRollAnimation(npcPed)
    Wait(Config.animation.duration)

    local npcRoll = rollDice()

    -- Give the NPC a certain probability to force a winning roll (7 or 11).
    -- For example, a 30% chance to turn the roll into a guaranteed win:
    if math.random(1, 100) <= 35 then
        local forcedWinningRolls = {7, 11}
        npcRoll = forcedWinningRolls[math.random(#forcedWinningRolls)]
    end

    lib.notify({title = "Opponent rolled a " .. npcRoll})

    if npcRoll == 7 or npcRoll == 11 then
        loseGame(betAmount) -- NPC wins here.
    else
        Wait(Config.rollDelay)
        startDiceGame(betAmount, npcPed)
    end
end


function winGame(betAmount)
    rollCounter = 0 
    local payout = betAmount * 2
    TriggerServerEvent('tropic-dicegame:payPlayer', payout)
    lib.notify({title = "You won! $" .. payout .. "!", type = "success"})
    resetNPCsToAnimation()

    if Config.enableJumped and math.random(1, 100) <= Config.jumpedChance then
        triggerNPCFight()
    end
end

function loseGame(betAmount)
    rollCounter = 0
    -- Don't remove money here because it's already taken from the player before the game started
    lib.notify({title = "You lost $" .. betAmount .. ".", type = "error"})
    resetNPCsToAnimation()
end


function triggerNPCFight()
    local playerPed = PlayerPedId()
    local playerCoords = GetEntityCoords(playerPed)
    local npcModels = {"g_m_y_ballaorig_01", "csb_ballasog"}

    for i = 1, 2 do
        local chosenModel = npcModels[math.random(#npcModels)]
        local npcHash = loadModel(chosenModel)
        if npcHash then
            local xOffset = math.random(-5, 5)
            local yOffset = math.random(-5, 5)
            local ped = CreatePed(4, npcHash, playerCoords.x + xOffset, playerCoords.y + yOffset, playerCoords.z, 0.0, true, true)
            TaskCombatPed(ped, playerPed, 0, 16)
        end
    end
    lib.notify({title = "You're getting jumped!"})
end

function playRollAnimation(ped)
    loadAnimDict(Config.animation.dict)
    TaskPlayAnim(ped, Config.animation.dict, Config.animation.clip, 8.0, -8.0, Config.animation.duration, 0, 0, false, false, false)
end
