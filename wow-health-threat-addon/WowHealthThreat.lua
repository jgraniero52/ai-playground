-- WowHealthThreat.lua
-- Flashes screen red when a party/raid member drops below 20% health.
-- Flashes screen orange when a hostile mob targets you.
-- Compatible with World of Warcraft: Midnight (Interface 120000+)
--
-- References:
--   AnimationGroup flash pattern: warcraft.wiki.gg/wiki/AnimationGroup
--   Nameplate API: C_NamePlate.GetNamePlates(), warcraft.wiki.gg/wiki/API_C_NamePlate_GetNamePlates
--   UIFrameFlash avoided (known taint source since patch 5.2)

local ADDON_NAME       = "WowHealthThreat"
local HEALTH_THRESHOLD = 0.20  -- alert below this fraction (20%)
local HEALTH_COOLDOWN  = 5     -- seconds before re-alerting the same unit
local THREAT_COOLDOWN  = 3     -- seconds between targeting alerts

local healthAlertTimers = {}   -- [unitToken] = last alert timestamp
local threatAlertTimer  = 0    -- last targeting alert timestamp

-- ============================================================
-- Screen Flash
--
-- Full-screen overlay using AnimationGroup (taint-safe).
-- UIFrameFlash is intentionally avoided — it is a taint source
-- in restricted environments since patch 5.2.
--
-- KEY: the texture alpha stays at 1 (fully opaque per its colour).
--      The FRAME alpha is what we animate (0 → 0.45 → 0.45 → 0).
--      Animating the texture's colour-alpha instead would give
--      effective alpha = frame_alpha * tex_alpha = 1 * 0 = invisible.
-- ============================================================
local flashFrame = CreateFrame("Frame", ADDON_NAME .. "FlashFrame", UIParent)
flashFrame:SetAllPoints(UIParent)
flashFrame:SetFrameStrata("FULLSCREEN_DIALOG")
flashFrame:SetFrameLevel(100)
flashFrame:SetAlpha(0)  -- start hidden; animation drives visibility

local flashTexture = flashFrame:CreateTexture(nil, "OVERLAY")
flashTexture:SetAllPoints(flashFrame)
flashTexture:SetColorTexture(1, 0, 0, 1)  -- colour changed per-trigger; alpha kept at 1

local flashAnim = flashFrame:CreateAnimationGroup()
flashAnim:SetLooping("NONE")

local fadeIn = flashAnim:CreateAnimation("Alpha")
fadeIn:SetFromAlpha(0)
fadeIn:SetToAlpha(0.45)
fadeIn:SetDuration(0.15)
fadeIn:SetOrder(1)

local hold = flashAnim:CreateAnimation("Alpha")
hold:SetFromAlpha(0.45)
hold:SetToAlpha(0.45)
hold:SetDuration(0.20)
hold:SetOrder(2)

local fadeOut = flashAnim:CreateAnimation("Alpha")
fadeOut:SetFromAlpha(0.45)
fadeOut:SetToAlpha(0)
fadeOut:SetDuration(0.50)
fadeOut:SetOrder(3)

flashAnim:SetScript("OnFinished", function()
    flashFrame:SetAlpha(0)
end)

--- Trigger a full-screen colour pulse.
-- @param r, g, b  Colour components 0-1
local function FlashScreen(r, g, b)
    flashTexture:SetColorTexture(r, g, b, 1)
    flashFrame:SetAlpha(0)       -- reset before playing so interrupting a flash restarts cleanly
    flashAnim:Stop()
    flashAnim:Play()
end

-- ============================================================
-- Sounds
-- ALARM_CLOCK_WARNING_3  → DBM's signature "something is dying" alarm (8960-range)
-- RAID_WARNING (8959)    → the raid warning horn; sharp, distinct from health alarm
-- ============================================================
local function PlayHealthSound()
    PlaySound(SOUNDKIT.ALARM_CLOCK_WARNING_3, "Master")
end

local function PlayThreatSound()
    PlaySound(SOUNDKIT.RAID_WARNING, "Master")
end

-- ============================================================
-- Alert display
-- ============================================================
local function TriggerHealthAlert(unit)
    local name  = UnitName(unit) or unit
    local maxHp = UnitHealthMax(unit)
    local pct   = (maxHp > 0) and math.floor(UnitHealth(unit) / maxHp * 100) or 0

    FlashScreen(1, 0.08, 0.08)  -- red
    UIErrorsFrame:AddMessage(
        string.format("|cffff2020[!] %s is at %d%% health!|r", name, pct),
        1, 0.12, 0.12
    )
    PlayHealthSound()
end

local function TriggerThreatAlert(mobName)
    FlashScreen(1, 0.45, 0)     -- orange (visually distinct from red health flash)
    UIErrorsFrame:AddMessage(
        string.format("|cffffff00[!] %s is targeting YOU!|r", mobName or "A mob"),
        1, 1, 0
    )
    PlayThreatSound()
end

-- ============================================================
-- Health check
-- ============================================================
local function IsMonitoredUnit(unit)
    return unit == "player"
        or unit == "target"
        or unit == "focus"
        or unit:match("^party%d$") ~= nil
        or unit:match("^raid%d+$") ~= nil
end

local function CheckUnitHealth(unit)
    if not UnitExists(unit) then return end

    local maxHp = UnitHealthMax(unit)
    if maxHp <= 0 then return end

    local pct = UnitHealth(unit) / maxHp

    if pct > 0 and pct < HEALTH_THRESHOLD then
        local now  = GetTime()
        local last = healthAlertTimers[unit]
        if not last or (now - last) >= HEALTH_COOLDOWN then
            healthAlertTimers[unit] = now
            TriggerHealthAlert(unit)
        end
    else
        -- Unit recovered — reset so the next drop triggers again
        healthAlertTimers[unit] = nil
    end
end

-- ============================================================
-- Threat / targeting detection
--
-- Uses C_NamePlate.GetNamePlates() — the correct API for iterating
-- visible nameplate units. Do NOT manually iterate nameplate1-40;
-- GetNamePlates() returns only currently active plates and provides
-- the namePlateUnitToken field for API calls.
--
-- Also checks targettarget as a cheap fallback when nameplates
-- may not cover the targeting mob (e.g. it has nameplates hidden).
-- ============================================================
local function CheckIfTargeted()
    local now = GetTime()
    if (now - threatAlertTimer) < THREAT_COOLDOWN then return end

    -- Primary: scan all visible nameplate units
    local plates = C_NamePlate.GetNamePlates(false)  -- false = include out-of-combat plates
    for _, plate in ipairs(plates) do
        local unit = plate.namePlateUnitToken
        if unit and UnitExists(unit) and UnitIsEnemy("player", unit) then
            if UnitIsUnit(unit .. "target", "player") then
                threatAlertTimer = now
                TriggerThreatAlert(UnitName(unit))
                return
            end
        end
    end

    -- Fallback: player's current target has player as its target
    if UnitExists("target") and UnitIsEnemy("player", "target") then
        if UnitIsUnit("targettarget", "player") then
            threatAlertTimer = now
            TriggerThreatAlert(UnitName("target"))
        end
    end
end

-- ============================================================
-- Event registration and handling
-- ============================================================
local eventFrame = CreateFrame("Frame", ADDON_NAME .. "EventFrame", UIParent)

-- UNIT_HEALTH / UNIT_MAXHEALTH: fires when a unit's current or max HP changes.
-- UNIT_MAXHEALTH added alongside UNIT_HEALTH so percentage stays accurate
-- when max health changes (e.g. stamina buff/debuff during combat).
eventFrame:RegisterEvent("ADDON_LOADED")
eventFrame:RegisterEvent("PLAYER_ENTERING_WORLD")   -- fires on login + every zone transition
eventFrame:RegisterEvent("PLAYER_REGEN_ENABLED")    -- leaving combat — good time to clear stale timers
eventFrame:RegisterEvent("UNIT_HEALTH")
eventFrame:RegisterEvent("UNIT_MAXHEALTH")
eventFrame:RegisterEvent("GROUP_ROSTER_UPDATE")     -- party/raid comp changed (joins, leaves, wipes)
eventFrame:RegisterEvent("UNIT_TARGET")             -- a unit's target changed
eventFrame:RegisterEvent("PLAYER_TARGET_CHANGED")   -- player switched targets (targettarget fallback)
eventFrame:RegisterEvent("NAME_PLATE_UNIT_ADDED")   -- new nameplate appeared — check immediately

eventFrame:SetScript("OnEvent", function(self, event, arg1)

    if event == "ADDON_LOADED" then
        if arg1 == ADDON_NAME then
            print("|cff00cc88[HealthThreat]|r Loaded. Monitoring health & threats.")
        end

    elseif event == "PLAYER_ENTERING_WORLD" then
        -- Re-sync on login and zone transitions; stale unit tokens become invalid
        wipe(healthAlertTimers)
        threatAlertTimer = 0

    elseif event == "PLAYER_REGEN_ENABLED" then
        -- Left combat — clear per-unit cooldowns so the next pull starts fresh
        wipe(healthAlertTimers)

    elseif event == "GROUP_ROSTER_UPDATE" then
        -- Party/raid composition changed; old unit tokens may be stale
        wipe(healthAlertTimers)

    elseif event == "UNIT_HEALTH" or event == "UNIT_MAXHEALTH" then
        if IsMonitoredUnit(arg1) then
            CheckUnitHealth(arg1)
        end

    elseif event == "UNIT_TARGET"
        or event == "PLAYER_TARGET_CHANGED"
        or event == "NAME_PLATE_UNIT_ADDED"
    then
        CheckIfTargeted()
    end
end)
