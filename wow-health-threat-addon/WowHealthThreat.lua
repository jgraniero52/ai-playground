-- WowHealthThreat.lua
-- Flashes the screen red when any party/raid member (or yourself) drops below 20% health.
-- Flashes the screen orange when a hostile mob targets you.
-- Compatible with World of Warcraft: Midnight (Interface 120000+)

local ADDON_NAME      = "WowHealthThreat"
local HEALTH_THRESHOLD = 0.20   -- trigger at < 20% hp
local HEALTH_COOLDOWN  = 5      -- seconds before re-alerting for the same unit
local THREAT_COOLDOWN  = 3      -- seconds before re-alerting for targeting

-- Per-unit timestamps for health alert spam prevention
local healthAlertTimers = {}
local threatAlertTimer  = 0

-- ============================================================
-- Screen Flash Frame
-- A fullscreen alpha-animated overlay, WeakAuras-style.
-- Red pulse = health critical  |  Orange pulse = mob targeting you
-- ============================================================
local flashFrame = CreateFrame("Frame", ADDON_NAME .. "FlashFrame", UIParent)
flashFrame:SetAllPoints(UIParent)
flashFrame:SetFrameStrata("FULLSCREEN_DIALOG")
flashFrame:SetFrameLevel(100)
flashFrame:Hide()

local flashTexture = flashFrame:CreateTexture(nil, "BACKGROUND")
flashTexture:SetAllPoints(flashFrame)
flashTexture:SetColorTexture(1, 0, 0, 0)  -- colour is set per-trigger

-- AnimationGroup: quick fade-in -> brief hold -> fade-out
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
fadeOut:SetDuration(0.40)
fadeOut:SetOrder(3)

flashAnim:SetScript("OnFinished", function()
    flashFrame:Hide()
end)

--- Trigger a full-screen colour pulse.
-- @param r,g,b  RGB components (0-1) for the flash colour
local function FlashScreen(r, g, b)
    flashTexture:SetColorTexture(r, g, b, 0)
    flashFrame:Show()
    if flashAnim:IsPlaying() then
        flashAnim:Stop()
    end
    flashAnim:Play()
end

-- ============================================================
-- Sound Helpers
-- ALARM_CLOCK_WARNING_3  – DBM's signature "something is dying" alarm
-- UI_RAID_WARNING        – the raid-warning horn, sharp and distinct
-- ============================================================
local function PlayHealthSound()
    PlaySound(SOUNDKIT.ALARM_CLOCK_WARNING_3, "Master")
end

local function PlayThreatSound()
    PlaySound(SOUNDKIT.UI_RAID_WARNING, "Master")
end

-- ============================================================
-- Alert Triggers
-- ============================================================
local function TriggerHealthAlert(unit)
    local name = UnitName(unit) or unit
    local hp   = math.floor((UnitHealth(unit) / UnitHealthMax(unit)) * 100)
    -- Red screen flash
    FlashScreen(1, 0.08, 0.08)
    -- Error-frame message (top-centre of screen)
    UIErrorsFrame:AddMessage(
        string.format("|cffff2020[!] %s is at %d%% health!|r", name, hp),
        1, 0.12, 0.12
    )
    PlayHealthSound()
end

local function TriggerThreatAlert()
    -- Orange screen flash (visually distinct from the red health flash)
    FlashScreen(1, 0.45, 0)
    UIErrorsFrame:AddMessage("|cffffff00[!] A mob is targeting YOU!|r", 1, 1, 0)
    PlayThreatSound()
end

-- ============================================================
-- Health Check
-- Called on UNIT_HEALTH for any unit we care about.
-- ============================================================
local function CheckUnitHealth(unit)
    if not UnitExists(unit) then return end

    local maxHp = UnitHealthMax(unit)
    if maxHp <= 0 then return end

    local pct = UnitHealth(unit) / maxHp

    if pct > 0 and pct < HEALTH_THRESHOLD then
        local now = GetTime()
        if not healthAlertTimers[unit] or (now - healthAlertTimers[unit]) >= HEALTH_COOLDOWN then
            healthAlertTimers[unit] = now
            TriggerHealthAlert(unit)
        end
    else
        -- Unit recovered above threshold – reset so the next drop fires again
        healthAlertTimers[unit] = nil
    end
end

-- ============================================================
-- Threat / Targeting Check
-- Iterates visible nameplate units to see if any hostile mob
-- has the player as its current target.
-- Also checks targettarget as a cheap fallback when applicable.
-- ============================================================
local function CheckIfTargeted()
    local now = GetTime()
    if (now - threatAlertTimer) < THREAT_COOLDOWN then return end

    -- Primary: scan nameplate units (covers all nearby enemies with nameplates)
    for i = 1, 40 do
        local unit = "nameplate" .. i
        if UnitExists(unit) and UnitIsEnemy("player", unit) then
            if UnitIsUnit(unit .. "target", "player") then
                threatAlertTimer = now
                TriggerThreatAlert()
                return
            end
        end
    end

    -- Fallback: if the player's current target is a hostile mob, check its target
    if UnitExists("target") and UnitIsEnemy("player", "target") then
        if UnitIsUnit("targettarget", "player") then
            threatAlertTimer = now
            TriggerThreatAlert()
        end
    end
end

-- ============================================================
-- Event Registration
-- ============================================================
local eventFrame = CreateFrame("Frame", ADDON_NAME .. "EventFrame", UIParent)

eventFrame:RegisterEvent("ADDON_LOADED")
eventFrame:RegisterEvent("UNIT_HEALTH")
eventFrame:RegisterEvent("UNIT_TARGET")
eventFrame:RegisterEvent("PLAYER_TARGET_CHANGED")
eventFrame:RegisterEvent("NAME_PLATE_UNIT_ADDED")

eventFrame:SetScript("OnEvent", function(self, event, arg1)

    if event == "ADDON_LOADED" and arg1 == ADDON_NAME then
        print("|cff00cc88[HealthThreat]|r Loaded. Watching health & threats.")

    elseif event == "UNIT_HEALTH" then
        local unit = arg1
        -- Only process units we actively monitor to avoid unnecessary work
        if unit == "player"
            or unit == "target"
            or unit == "focus"
            or unit:find("^party%d")
            or unit:find("^raid%d")
        then
            CheckUnitHealth(unit)
        end

    elseif event == "UNIT_TARGET"
        or event == "PLAYER_TARGET_CHANGED"
        or event == "NAME_PLATE_UNIT_ADDED"
    then
        CheckIfTargeted()
    end
end)
