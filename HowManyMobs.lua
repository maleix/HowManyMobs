-- ============================================
-- HowManyMobs: Grinding Tracker for Classic Era
-- Track how many mobs you need to kill to level up
-- ============================================
-- VERSION 1.0
-- ============================================

local ADDON_NAME = "HowManyMobs"
local VERSION = "1.0"

local HowManyMobs = CreateFrame("Frame")
HowManyMobs:RegisterEvent("COMBAT_LOG_EVENT_UNFILTERED")
HowManyMobs:RegisterEvent("PLAYER_LOGIN")
HowManyMobs:RegisterEvent("PLAYER_ENTERING_WORLD")
HowManyMobs:RegisterEvent("PLAYER_XP_UPDATE")
HowManyMobs:RegisterEvent("PLAYER_TARGET_CHANGED")
HowManyMobs:RegisterEvent("PLAYER_LEVEL_UP")

-- ============================================
-- ARCHITECTURE OVERVIEW
-- State is split into two areas:
--   HowManyMobs.*   — session data (in-memory only, reset on login/level-up)
--   HowManyMobsDB.* — SavedVariables (persists across sessions and /reload)
--
-- Kill tracking data flow:
--   COMBAT_LOG_EVENT_UNFILTERED
--     → OnCombatLogEvent:
--         damage events  → populate damagedMobs{GUID} (phase 1: prove we hit it)
--         UNIT_DIED      → AddMobToHistory() then UpdateMobCount() (phase 2: credit kill)
--   PLAYER_XP_UPDATE
--     → OnXPUpdate: link XP gain to the most recent unmatched kill in sessionMobKills
--                   then call UpdateMobCount()
--
-- XP average priority (highest to lowest):
--   1. GetSessionAverageRealXP  — weighted avg of matched real XP this session (up to 10 kills)
--   2. GetRollingAverageRealXP  — simple avg of persisted real XP (up to 12, survives reload)
--   3. GetAverageMobXP          — formula estimate from mob levels (pure fallback, no real data)
-- ============================================

-- ============================================
-- UI FRAME REFERENCES
-- ============================================
HowManyMobs.UIFrame = nil
HowManyMobs.mobsNeededText = nil
HowManyMobs.lastKilledText = nil
HowManyMobs.averageXPText = nil
HowManyMobs.efficiencyText = nil
HowManyMobs.estimatedTimeText = nil
HowManyMobs.sessionStatsText = nil
HowManyMobs.MinimapButton = nil

HowManyMobs.lastXP = UnitXP("player")
HowManyMobs.firstKillTime = nil
HowManyMobs.sessionKills = 0
HowManyMobs.sessionTotalXP = 0  -- Running total of all matched kill XP this session

-- Session mob tracking with REAL XP gained.
-- Each entry is a table with the following fields:
--   name        (string)  mob name
--   level       (number)  mob level at time of kill
--   time        (number)  GetTime() timestamp of the kill
--   xpGained    (number)  raw XP gain linked to this kill (0 until linked via OnXPUpdate)
--   xpAssigned  (bool)    true once a PLAYER_XP_UPDATE event has been matched to this kill
--   rested      (bool)    true if the linked XP included a rested bonus (doubled XP)
--   baseXP      (number)  non-rested XP amount (≈ xpGained/2 when rested);
--                          used for predictions so estimates stay accurate after rested expires
-- Index 1 = newest kill (prepended via table.insert at position 1). Capped at 10 entries.
HowManyMobs.sessionMobKills = {}

-- Target tracking (multi-entry: stores level for multiple mob names)
HowManyMobs.targetCache = {}

-- ============================================
-- SAVED VARIABLES
-- ============================================
HowManyMobsDB = HowManyMobsDB or {
    lastMobs = {},
    recentRealXPGains = {},
    trackingEnabled = true,
    uiX = nil,
    uiY = nil,
    uiScale = 1.0,
    uiOpacity = 0.85,
    uiLocked = false,
    showLastKilled = true,
    showMobLevel = true,
    showAverageXP = false,
    showEfficiency = true,
    showEstimatedTime = false,
    showSessionStats = true,
    minimapAngle = 45,
}

local DEFAULTS = {
    lastMobs = {},
    recentRealXPGains = {},
    trackingEnabled = true,
    uiX = nil,
    uiY = nil,
    uiScale = 1.0,
    uiOpacity = 0.85,
    uiLocked = false,
    showLastKilled = true,
    showMobLevel = true,
    showAverageXP = false,
    showEfficiency = true,
    showEstimatedTime = false,
    showSessionStats = true,
    minimapAngle = 45,
}

local function CopyDefaults(src, dst)
    for k, v in pairs(src) do
        if type(v) == "table" then
            if type(dst[k]) ~= "table" then
                dst[k] = {}
            end
            CopyDefaults(v, dst[k])
        elseif dst[k] == nil then
            dst[k] = v
        end
    end
end

-- ============================================
-- TARGET TRACKING
-- ============================================
function HowManyMobs:UpdateTargetCache()
    local targetName = UnitName("target")
    local targetLevel = UnitLevel("target")
    if targetName and targetLevel and targetLevel > 0 then
        local now = GetTime()
        self.targetCache[targetName] = {
            level = targetLevel,
            lastUpdated = now
        }
        -- Prune old entries at most once every 60 seconds
        if not self.lastTargetCachePrune or now - self.lastTargetCachePrune > 60 then
            self.lastTargetCachePrune = now
            for name, data in pairs(self.targetCache) do
                if now - data.lastUpdated > 120 then
                    self.targetCache[name] = nil
                end
            end
        end
    end
end

function HowManyMobs:GetCachedMobLevel(mobName)
    local entry = self.targetCache[mobName]
    if entry then
        local timeSinceUpdate = GetTime() - (entry.lastUpdated or 0)
        if timeSinceUpdate < 120 then
            return entry.level
        else
            self.targetCache[mobName] = nil
        end
    end
    return nil
end

-- ============================================
-- ROLLING XP AVERAGE + LEVEL-UP RESET
-- Uses WEIGHTED average: recent kills matter more
-- ============================================
function HowManyMobs:GetRollingAverageRealXP()
    if not HowManyMobsDB.recentRealXPGains or #HowManyMobsDB.recentRealXPGains == 0 then
        return 0
    end
    local total = 0
    for _, xp in ipairs(HowManyMobsDB.recentRealXPGains) do
        total = total + xp
    end
    return math.floor(total / #HowManyMobsDB.recentRealXPGains + 0.5)
end

function HowManyMobs:OnPlayerLevelUp()
    HowManyMobsDB.recentRealXPGains = {}

    -- Sync lastXP so the next PLAYER_XP_UPDATE doesn't see a negative/bogus gain
    self.lastXP = UnitXP("player")
    
    -- Reset session stats on level up for accurate next-level tracking
    self.sessionKills = 0
    self.sessionTotalXP = 0
    self.sessionMobKills = {}
    self.firstKillTime = nil
    if self.mobsNeededText then
        self:UpdateMobCount()
    end
end

-- ============================================
-- MINIMAP BUTTON
-- ============================================
function HowManyMobs:CreateMinimapButton()
    if self.MinimapButton then
        self.MinimapButton:Show()
        return
    end

    local button = CreateFrame("Button", "HowManyMobsMinimapButton", Minimap)
    button:SetSize(31, 31)
    button:SetFrameStrata("MEDIUM")
    button:SetMovable(true)
    button:EnableMouse(true)
    button:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    button:RegisterForDrag("LeftButton")

    local overlay = button:CreateTexture(nil, "OVERLAY")
    overlay:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
    overlay:SetSize(54, 54)
    overlay:SetPoint("TOPLEFT")

    local icon = button:CreateTexture(nil, "ARTWORK")
    icon:SetSize(20, 20)
    icon:SetPoint("CENTER")
    icon:SetTexture("Interface\\Icons\\Ability_Hunter_SniperShot")
    button.icon = icon

    button:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")
    local highlight = button:GetHighlightTexture()
    highlight:SetBlendMode("ADD")
    highlight:SetAllPoints()

    button:SetPushedTexture("Interface\\Buttons\\UI-Quickslot-Depress")
    local pushed = button:GetPushedTexture()
    pushed:SetAllPoints()

    if not HowManyMobsDB.minimapAngle then
        HowManyMobsDB.minimapAngle = 45
    end

    local function UpdatePosition()
        local angle = math.rad(HowManyMobsDB.minimapAngle)
        local radius = 80
        local x = math.cos(angle) * radius
        local y = math.sin(angle) * radius
        button:ClearAllPoints()
        button:SetPoint("CENTER", Minimap, "CENTER", x, y)
    end

    button:SetScript("OnDragStart", function(self) self.dragging = true end)
    button:SetScript("OnDragStop", function(self) self.dragging = false end)
    button:SetScript("OnUpdate", function(self)
        if not self.dragging then return end
        local mx, my = Minimap:GetCenter()
        local px, py = GetCursorPosition()
        local scale = Minimap:GetEffectiveScale()
        px, py = px / scale, py / scale
        local dx = px - mx
        local dy = py - my
        local angle = math.deg(math.atan2(dy, dx))
        HowManyMobsDB.minimapAngle = angle
        UpdatePosition()
    end)

    button:SetScript("OnClick", function(self, mouseButton)
        if mouseButton == "LeftButton" then
            if HowManyMobs.UIFrame then
                if HowManyMobs.UIFrame:IsShown() then
                    HowManyMobs.UIFrame:Hide()
                else
                    HowManyMobs.UIFrame:Show()
                    HowManyMobs:UpdateMobCount()
                end
            else
                HowManyMobs:CreateUI()
            end
        elseif mouseButton == "RightButton" then
            HowManyMobs:CreateMinimapMenu()
            ToggleDropDownMenu(1, nil, HowManyMobs.MinimapMenu, self, 0, -5)
        end
    end)

    button:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_LEFT")
        GameTooltip:AddLine("|cff00ff00HowManyMobs|r v" .. VERSION)
        GameTooltip:AddLine("Grinding tracker - shows mobs to level", 1, 1, 1)
        GameTooltip:AddLine("Left-click to toggle window", 1, 1, 1)
        GameTooltip:AddLine("Right-click for options", 1, 1, 1)
        GameTooltip:Show()
        self.icon:SetDesaturated(false)
    end)

    button:SetScript("OnLeave", function(self)
        GameTooltip:Hide()
        self.icon:SetDesaturated(true)
    end)

    button.icon:SetDesaturated(true)
    button:Show()
    self.MinimapButton = button
    C_Timer.After(0, UpdatePosition)
end

function HowManyMobs:CreateMinimapMenu()
    if self.MinimapMenu then return end

    local menu = CreateFrame("Frame", "HowManyMobs_MinimapMenu", UIParent, "UIDropDownMenuTemplate")

    local function MenuHandler(_, level)
        if not level then return end
        local info = UIDropDownMenu_CreateInfo()

        info.isTitle = true
        info.text = "HowManyMobs v" .. VERSION .. " - Grinding"
        info.notCheckable = true
        UIDropDownMenu_AddButton(info, level)

        wipe(info)
        info.text = "Show/Hide Window"
        info.func = function()
            if HowManyMobs.UIFrame then
                if HowManyMobs.UIFrame:IsShown() then
                    HowManyMobs.UIFrame:Hide()
                else
                    HowManyMobs.UIFrame:Show()
                end
            else
                HowManyMobs:CreateUI()
            end
            HowManyMobs:UpdateMobCount()
        end
        info.notCheckable = true
        UIDropDownMenu_AddButton(info, level)

        wipe(info)
        info.text = "Enable Tracking"
        info.checked = HowManyMobsDB.trackingEnabled
        info.func = function()
            HowManyMobsDB.trackingEnabled = not HowManyMobsDB.trackingEnabled
        end
        UIDropDownMenu_AddButton(info, level)

        wipe(info)
        info.text = "Show Last Killed"
        info.checked = HowManyMobsDB.showLastKilled
        info.func = function()
            HowManyMobsDB.showLastKilled = not HowManyMobsDB.showLastKilled
            HowManyMobs:UpdateLastKilledText()
            HowManyMobs:UpdateUILayout()
        end
        UIDropDownMenu_AddButton(info, level)

        wipe(info)
        info.text = "Show Mob Level"
        info.checked = HowManyMobsDB.showMobLevel
        info.func = function()
            HowManyMobsDB.showMobLevel = not HowManyMobsDB.showMobLevel
            HowManyMobs:UpdateLastKilledText()
        end
        UIDropDownMenu_AddButton(info, level)

        wipe(info)
        info.text = "Show Average XP per Kill"
        info.checked = HowManyMobsDB.showAverageXP
        info.func = function()
            HowManyMobsDB.showAverageXP = not HowManyMobsDB.showAverageXP
            HowManyMobs:UpdateAverageXPText()
            HowManyMobs:UpdateUILayout()
        end
        UIDropDownMenu_AddButton(info, level)

        wipe(info)
        info.text = "Show Efficiency"
        info.checked = HowManyMobsDB.showEfficiency
        info.func = function()
            HowManyMobsDB.showEfficiency = not HowManyMobsDB.showEfficiency
            HowManyMobs:UpdateEfficiencyText()
            HowManyMobs:UpdateUILayout()
        end
        UIDropDownMenu_AddButton(info, level)

        wipe(info)
        info.text = "Show Estimated Time"
        info.checked = HowManyMobsDB.showEstimatedTime
        info.func = function()
            HowManyMobsDB.showEstimatedTime = not HowManyMobsDB.showEstimatedTime
            HowManyMobs:UpdateEstimatedTimeText()
            HowManyMobs:UpdateUILayout()
        end
        UIDropDownMenu_AddButton(info, level)

        wipe(info)
        info.text = "Show Session Stats"
        info.checked = HowManyMobsDB.showSessionStats
        info.func = function()
            HowManyMobsDB.showSessionStats = not HowManyMobsDB.showSessionStats
            if HowManyMobs.sessionStatsText then
                if HowManyMobsDB.showSessionStats then
                    HowManyMobs.sessionStatsText:Show()
                else
                    HowManyMobs.sessionStatsText:Hide()
                end
            end
            HowManyMobs:UpdateUILayout()
        end
        UIDropDownMenu_AddButton(info, level)

        wipe(info)
        info.text = "Lock Frame"
        info.checked = HowManyMobsDB.uiLocked
        info.func = function()
            HowManyMobsDB.uiLocked = not HowManyMobsDB.uiLocked
        end
        UIDropDownMenu_AddButton(info, level)

        wipe(info)
        info.disabled = true
        info.notCheckable = true
        UIDropDownMenu_AddButton(info, level)

        wipe(info)
        info.text = "Reset All Data"
        info.func = function()
            HowManyMobsDB.lastMobs = {}
            HowManyMobsDB.recentRealXPGains = {}
            HowManyMobs.sessionMobKills = {}
            HowManyMobs.sessionKills = 0
            HowManyMobs.sessionTotalXP = 0
            HowManyMobs.firstKillTime = nil
            HowManyMobs.damagedMobs = {}
            HowManyMobs:UpdateMobCount()
        end
        info.notCheckable = true
        UIDropDownMenu_AddButton(info, level)
    end

    UIDropDownMenu_Initialize(menu, MenuHandler, "MENU")
    self.MinimapMenu = menu
end

-- ==================== UI ====================
function HowManyMobs:CreateUI()
    if self.UIFrame then 
        self.UIFrame:Show()
        return 
    end

    local UIFrame = CreateFrame("Frame", "HowManyMobsFrame", UIParent, "BackdropTemplate")
    UIFrame:SetFrameStrata("MEDIUM")
    UIFrame:SetFrameLevel(100)
    UIFrame:SetSize(255, 62)

    if HowManyMobsDB.uiX and HowManyMobsDB.uiY then
        UIFrame:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", HowManyMobsDB.uiX, HowManyMobsDB.uiY)
    else
        UIFrame:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
    end
    
    UIFrame:SetBackdrop({
        bgFile = "Interface/Tooltips/UI-Tooltip-Background",
        edgeFile = "Interface/Tooltips/UI-Tooltip-Border",
        tile = true,
        tileSize = 16,
        edgeSize = 12,
        insets = {left = 4, right = 4, top = 4, bottom = 4}
    })
    
    UIFrame:EnableMouse(true)
    UIFrame:SetMovable(true)
    UIFrame:RegisterForDrag("LeftButton")
    UIFrame:SetScript("OnDragStart", function(self)
        if not HowManyMobsDB.uiLocked then self:StartMoving() end
    end)
    UIFrame:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        HowManyMobsDB.uiX = self:GetLeft()
        HowManyMobsDB.uiY = self:GetTop()
    end)

    self.mobsNeededText = UIFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    self.mobsNeededText:SetPoint("TOPLEFT", UIFrame, "TOPLEFT", 12, -11)
    self.mobsNeededText:SetWidth(231)
    self.mobsNeededText:SetJustifyH("LEFT")

    self.lastKilledText = UIFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    self.lastKilledText:SetPoint("TOPLEFT", UIFrame, "TOPLEFT", 12, -31)
    self.lastKilledText:SetWidth(231)
    self.lastKilledText:SetJustifyH("LEFT")

    self.averageXPText = UIFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    self.averageXPText:SetPoint("TOPLEFT", UIFrame, "TOPLEFT", 12, -52)
    self.averageXPText:SetWidth(231)
    self.averageXPText:SetJustifyH("LEFT")

    self.efficiencyText = UIFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    self.efficiencyText:SetPoint("TOPLEFT", UIFrame, "TOPLEFT", 12, -73)
    self.efficiencyText:SetWidth(231)
    self.efficiencyText:SetJustifyH("LEFT")

    -- ============================================
    -- EFFICIENCY TOOLTIP (direct & reliable version)
    -- ============================================
    self.efficiencyText:EnableMouse(true)

    self.efficiencyText:SetScript("OnEnter", function()
        GameTooltip:SetOwner(HowManyMobs.UIFrame, "ANCHOR_RIGHT")
        GameTooltip:ClearLines()

        GameTooltip:AddLine("|cffffd700Efficiency Rating|r")
        GameTooltip:AddLine(" ")
        GameTooltip:AddLine("How optimal your mob choice is for your level.", 0.8, 1, 1)
        GameTooltip:AddLine(" ")
        GameTooltip:AddLine("Formula:", 1, 1, 0)
        GameTooltip:AddLine("(XP from mob / XP from same-level mob) × 100%", 0.7, 0.7, 1)
        GameTooltip:AddLine(" ")
        GameTooltip:AddLine("|cff00ff00Green (80-100%):|r Optimal grind spot")
        GameTooltip:AddLine("|cffffff00Yellow (50-79%):|r Good but could find harder mobs")
        GameTooltip:AddLine("|cffff9900Orange (1-49%):|r Low XP - find harder mobs")
        GameTooltip:AddLine("|cffff0000Red (0%):|r Gray mobs - no XP gained")
        GameTooltip:Show()
    end)

    self.efficiencyText:SetScript("OnLeave", function()
        GameTooltip:Hide()
    end)

    self.estimatedTimeText = UIFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    self.estimatedTimeText:SetPoint("TOPLEFT", UIFrame, "TOPLEFT", 12, -94)
    self.estimatedTimeText:SetWidth(231)
    self.estimatedTimeText:SetJustifyH("LEFT")

    self.sessionStatsText = UIFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    self.sessionStatsText:SetPoint("TOPLEFT", UIFrame, "TOPLEFT", 12, -115)
    self.sessionStatsText:SetWidth(231)
    self.sessionStatsText:SetJustifyH("LEFT")

    self.UIFrame = UIFrame
    self:ApplyUISettings()
    self:UpdateUILayout()

    -- Force initial text so the box is never empty on login/reload
    self:UpdateMobCount()

    UIFrame:Show()
end

function HowManyMobs:UpdateUILayout()
    if not self.UIFrame then return end

    local lineHeight = 21
    local topPadding = 11
    local y = -topPadding
    local visibleLines = 1

    self.mobsNeededText:SetPoint("TOPLEFT", self.UIFrame, "TOPLEFT", 12, y)
    self.mobsNeededText:Show()
    y = y - lineHeight

    if HowManyMobsDB.showLastKilled then
        self.lastKilledText:SetPoint("TOPLEFT", self.UIFrame, "TOPLEFT", 12, y)
        self.lastKilledText:Show()
        y = y - lineHeight
        visibleLines = visibleLines + 1
    else
        self.lastKilledText:Hide()
    end

    if HowManyMobsDB.showAverageXP then
        self.averageXPText:SetPoint("TOPLEFT", self.UIFrame, "TOPLEFT", 12, y)
        self.averageXPText:Show()
        y = y - lineHeight
        visibleLines = visibleLines + 1
    else
        self.averageXPText:Hide()
    end

    if HowManyMobsDB.showEfficiency then
        self.efficiencyText:SetPoint("TOPLEFT", self.UIFrame, "TOPLEFT", 12, y)
        self.efficiencyText:Show()
        y = y - lineHeight
        visibleLines = visibleLines + 1
    else
        self.efficiencyText:Hide()
    end

    if HowManyMobsDB.showEstimatedTime then
        self.estimatedTimeText:SetPoint("TOPLEFT", self.UIFrame, "TOPLEFT", 12, y)
        self.estimatedTimeText:Show()
        y = y - lineHeight
        visibleLines = visibleLines + 1
    else
        self.estimatedTimeText:Hide()
    end

    if HowManyMobsDB.showSessionStats then
        self.sessionStatsText:SetPoint("TOPLEFT", self.UIFrame, "TOPLEFT", 12, y)
        self.sessionStatsText:Show()
        visibleLines = visibleLines + 1
    else
        if self.sessionStatsText then self.sessionStatsText:Hide() end
    end

    local newHeight = topPadding + (visibleLines * lineHeight) + 10
    self.UIFrame:SetHeight(newHeight)
end

function HowManyMobs:ApplyUISettings()
    if not self.UIFrame then return end
    self.UIFrame:SetScale(HowManyMobsDB.uiScale or 1.0)
    self:ApplyBoxOpacity()
end

function HowManyMobs:ApplyBoxOpacity()
    if not self.UIFrame then return end
    local alpha = HowManyMobsDB.uiOpacity or 0.85
    self.UIFrame:SetBackdropColor(0.05, 0.05, 0.12, alpha)
    self.UIFrame:SetBackdropBorderColor(1, 0.84, 0, alpha)
end

-- ============================================
-- CORE FUNCTIONS
-- ============================================
function HowManyMobs:GetSessionAverageRealXP()
    -- Weighted average: recent kills count more than older ones.
    -- Weight formula: newest kill = N, second newest = N-1, ..., oldest = 1
    -- (N = number of kills that have real XP data, up to 10).
    -- Two-pass approach: pass 1 counts valid kills to determine N (the weight scale),
    -- pass 2 computes the weighted sum using baseXP (non-rested) for accurate predictions.
    if not self.sessionMobKills or #self.sessionMobKills == 0 then return 0 end
    local totalWeightedXP = 0
    local totalWeight = 0
    local count = 0
    -- Pass 1: count kills with real XP data to establish the weight scale
    for _, kill in ipairs(self.sessionMobKills) do
        if kill.xpGained and kill.xpGained > 0 then
            count = count + 1
        end
    end
    if count == 0 then return 0 end
    local idx = 0
    -- Pass 2: compute weighted sum (newest kill gets weight=count, oldest gets weight=1)
    for _, kill in ipairs(self.sessionMobKills) do
        if kill.xpGained and kill.xpGained > 0 then
            idx = idx + 1
            local weight = count - idx + 1  -- newest = count, oldest = 1
            -- Use non-rested base XP for predictions (more accurate when rested runs out)
            local xp = kill.baseXP or kill.xpGained
            totalWeightedXP = totalWeightedXP + xp * weight
            totalWeight = totalWeight + weight
        end
    end
    if totalWeight == 0 then return 0 end
    return math.floor(totalWeightedXP / totalWeight + 0.5)
end

function HowManyMobs:GetAverageMobXP()
    if not HowManyMobsDB.lastMobs or #HowManyMobsDB.lastMobs == 0 then return 0 end
    
    local totalXP = 0
    local count = 0
    local playerLevel = UnitLevel("player")
    
    for _, mob in ipairs(HowManyMobsDB.lastMobs) do
        -- Only use mobs with valid levels
        if mob.level and mob.level >= 1 then
            local xp = self:EstimateMobXP(mob.level, playerLevel)
            if xp > 0 then 
                totalXP = totalXP + xp
                count = count + 1 
            end
        end
    end
    
    if count == 0 then 
        -- If no valid mob data, estimate based on player level
        return self:EstimateMobXP(playerLevel, playerLevel)
    end
    
    return math.floor(totalXP / count + 0.5)
end

function HowManyMobs:GetSessionStats()
    if not self.firstKillTime then return 0, 0 end
    local timeElapsed = GetTime() - self.firstKillTime
    -- Require at least 30s of data to avoid wild initial spikes
    if timeElapsed < 30 then return 0, 0 end
    
    -- Use running total (not capped by sessionMobKills size)
    local totalSessionXP = self.sessionTotalXP or 0
    
    -- Fall back to estimate if no real XP tracked yet
    if totalSessionXP == 0 and self.sessionKills and self.sessionKills > 0 then
        local avgXP = self:GetRollingAverageRealXP()
        if avgXP > 0 then
            totalSessionXP = avgXP * self.sessionKills
        else
            avgXP = self:GetAverageMobXP()
            if avgXP > 0 then
                totalSessionXP = avgXP * self.sessionKills
            end
        end
    end
    
    if totalSessionXP <= 0 then
        return 0, 0
    end
    
    local xpHour = totalSessionXP / timeElapsed * 3600
    local killsHour = (self.sessionKills or 0) / timeElapsed * 3600
    return xpHour, killsHour
end

function HowManyMobs:AddMobToHistory(destName, destLevel)
    if not destName then return end
    self.sessionKills = (self.sessionKills or 0) + 1
    
    -- Initialize first kill time on first kill
    if not self.firstKillTime then
        self.firstKillTime = GetTime()
    end

    -- Track kill for real XP linking
    table.insert(self.sessionMobKills, 1, {name = destName, level = destLevel or UnitLevel("player"), time = GetTime(), xpGained = 0})
    
    -- Keep last 10 kills for tracking
    if #self.sessionMobKills > 10 then table.remove(self.sessionMobKills, 11) end

    -- Also add to lastMobs for display
    table.insert(HowManyMobsDB.lastMobs, 1, {name = destName, level = destLevel or UnitLevel("player"), time = GetTime()})
    if #HowManyMobsDB.lastMobs > 3 then table.remove(HowManyMobsDB.lastMobs, 4) end
end

function HowManyMobs:GetEstimatedTimeToLevel()
    local avgKillTime = self:GetAverageKillTime()
    local avgXP = self:GetSessionAverageRealXP()
    
    if avgKillTime and avgXP and avgXP > 0 then
        local xpNeeded = UnitXPMax("player") - UnitXP("player")
        if xpNeeded <= 0 then return nil end
    
        local mobsNeeded = xpNeeded / avgXP
        local secondsNeeded = mobsNeeded * avgKillTime
    
        local minutes = math.floor(secondsNeeded / 60 + 0.5)
    
        if minutes < 60 then
            return minutes .. " min"
        else
            local hours = math.floor(minutes / 60)
            local mins = minutes % 60
            return hours .. "h " .. (mins > 0 and mins .. "m" or "")
        end
    end
    
    -- Fall back to estimates from last mobs if session tracking insufficient
    local mobs = HowManyMobsDB.lastMobs
    if not mobs or #mobs < 2 then return nil end
    local oldest, newest = mobs[#mobs], mobs[1]
    if not oldest.time or not newest.time or newest.time <= oldest.time then return nil end
    local timeElapsed = newest.time - oldest.time
    if timeElapsed < 5 then return nil end
    local totalXP = 0
    -- Prefer persisted real XP average over formula estimates
    local rollingAvg = self:GetRollingAverageRealXP()
    if rollingAvg > 0 then
        totalXP = rollingAvg * #mobs
    else
        local playerLevel = UnitLevel("player")
        for _, mob in ipairs(mobs) do
            totalXP = totalXP + self:EstimateMobXP(mob.level, playerLevel)
        end
    end
    if totalXP <= 0 then return nil end
    local xpPerSecond = totalXP / timeElapsed
    if xpPerSecond <= 0 then return nil end
    local xpNeeded = UnitXPMax("player") - UnitXP("player")
    if xpNeeded <= 0 then return nil end
    local secondsNeeded = xpNeeded / xpPerSecond
    local minutes = math.floor(secondsNeeded / 60 + 0.5)
    if minutes < 60 then
        return minutes .. " min"
    else
        local hours = math.floor(minutes / 60)
        local mins = minutes % 60
        return hours .. "h " .. (mins > 0 and mins .. "m" or "")
    end
end

function HowManyMobs:UpdateLastKilledText()
    if not self.lastKilledText or not HowManyMobsDB.showLastKilled then
        if self.lastKilledText then self.lastKilledText:SetText("") end
        return
    end
    if HowManyMobsDB.lastMobs and #HowManyMobsDB.lastMobs > 0 then
        local latest = HowManyMobsDB.lastMobs[1]
        local levelPart = HowManyMobsDB.showMobLevel and latest.level and " (Lvl " .. latest.level .. ")" or ""
        -- Show real XP gained if available from session tracking
        local xpPart = ""
        if self.sessionMobKills then
            for _, kill in ipairs(self.sessionMobKills) do
                if kill.name == latest.name and kill.xpGained and kill.xpGained > 0 then
                    xpPart = " |cff00ccff" .. kill.xpGained .. " XP|r"
                    break
                end
            end
        end
        self.lastKilledText:SetText("|cffffd700Last killed:|r |cff1eff00" .. latest.name .. levelPart .. "|r" .. xpPart)
    else
        self.lastKilledText:SetText("|cff99ccffKill a mob to start|r")
    end
end

function HowManyMobs:UpdateAverageXPText()
    if not self.averageXPText then return end
    if not HowManyMobsDB.showAverageXP then
        self.averageXPText:SetText("")
        return
    end

    local avg = self:GetSessionAverageRealXP()
    local source = "session"

    if avg == 0 then
        avg = self:GetRollingAverageRealXP()
        source = "rolling"
    end
    if avg == 0 then
        avg = self:GetAverageMobXP()
        source = "estimate"
    end

    if avg > 0 then
        self.averageXPText:SetText("|cffffd700Avg:|r |cff00ff00" .. avg .. " XP/kill|r |cff888888(" .. source .. ")")
    else
        self.averageXPText:SetText("|cffffd700Avg:|r |cff99ccffNo data yet|r")
    end
end

function HowManyMobs:UpdateEstimatedTimeText()
    if not self.estimatedTimeText or not HowManyMobsDB.showEstimatedTime then return end
    local timeStr = self:GetEstimatedTimeToLevel()
    if timeStr then
        self.estimatedTimeText:SetText("|cffffd700Est. time:|r |cff00ff00" .. timeStr .. "|r")
    else
        self.estimatedTimeText:SetText("|cffffd700Est. time:|r |cff99ccffKill more mobs...|r")
    end
end

function HowManyMobs:UpdateMobCount()
    -- MAIN UPDATE FUNCTION - Updates all displays
    -- Uses WEIGHTED average for XP (recent kills matter more)
    -- Shows VARIANCE RANGE (±N) when 3+ kills tracked (improvement #3)
    -- Color-coded using ROLLING EFFICIENCY (improvement #2)
    if not self.mobsNeededText then return end
    local playerLevel = UnitLevel("player")
    local currentXP = UnitXP("player")
    local maxXP = UnitXPMax("player")
    local xpNeeded = maxXP - currentXP

    if xpNeeded <= 0 then
        self.mobsNeededText:SetText("|cffff9900MAX LEVEL|r")
    else
        -- Get real average XP from tracked session kills first
        local averageXP = self:GetSessionAverageRealXP()
        
        -- Fall back to rolling average from XP events if session tracking insufficient
        if averageXP == 0 then
            averageXP = self:GetRollingAverageRealXP()
        end
        
        -- Fall back to estimates as last resort (improved with better validation)
        if averageXP == 0 then
            averageXP = self:GetAverageMobXP()
        end

        if averageXP > 0 then
            local mobsNeeded = math.ceil(xpNeeded / averageXP)
            local xpPct = math.floor(currentXP / maxXP * 100)
            
            -- Calculate variance to show confidence range
            local variance = self:GetXPVariance()
            local displayText = "|cffff9900" .. mobsNeeded .. "|r mobs to level up |cff888888(" .. xpPct .. "%)|r"
            
            if variance > 0 and self.sessionKills >= 3 then
                -- Show ±variance range for confidence
                local lowXP = averageXP - variance
                local highXP = averageXP + variance
                if lowXP > 0 then
                    local mobsLow = math.ceil(xpNeeded / highXP)   -- High XP = fewer mobs
                    local mobsHigh = math.ceil(xpNeeded / lowXP)   -- Low XP = more mobs
                    if mobsLow ~= mobsNeeded or mobsHigh ~= mobsNeeded then
                        displayText = displayText .. " |cff888888(±" .. math.ceil(mobsHigh - mobsNeeded) .. ")|r"
                    end
                end
            end
            
            self.mobsNeededText:SetText(displayText)
        else
            self.mobsNeededText:SetText("|cff99ccffKill a mob to start tracking|r")
        end
    end

    self:UpdateLastKilledText()
    self:UpdateAverageXPText()
    self:UpdateEfficiencyText()
    self:UpdateEstimatedTimeText()
    self:UpdateUILayout()

    -- Session stats with improved calculation
    if self.sessionStatsText then
        if not self.firstKillTime or self.sessionKills == 0 then
            self.sessionStatsText:SetText("|cffffd700Session:|r |cff99ccffNo data yet|r")
        else
            local xpHour, killsHour = self:GetSessionStats()
            if xpHour > 0 or killsHour > 0 then
                self.sessionStatsText:SetText(
                    string.format("|cffffd700Session:|r |cff00ff00%.0f XP/hr|r |cff00ccff%.1f kills/hr|r", xpHour, killsHour)
                )
            else
                self.sessionStatsText:SetText("|cffffd700Session:|r |cff99ccffGathering data...|r")
            end
        end
    end
end

-- ============================================
-- XP CALCULATION (Classic Era accurate)
-- ============================================

-- GetZD: returns the "Zone Difference" gray-mob threshold for a given player level.
-- A mob that is ZD or more levels BELOW the player gives 0 XP.
-- Values match the original WoW 1.x server formula.
-- Example: level 30 → ZD=11, so mobs level ≤19 yield no XP.
function HowManyMobs:GetZD(playerLevel)
    if playerLevel <= 7 then return 5 end
    if playerLevel <= 9 then return 6 end
    if playerLevel <= 11 then return 7 end
    if playerLevel <= 15 then return 8 end
    if playerLevel <= 19 then return 9 end
    if playerLevel <= 29 then return 11 end
    if playerLevel <= 39 then return 12 end
    if playerLevel <= 44 then return 13 end
    if playerLevel <= 49 then return 14 end
    if playerLevel <= 54 then return 15 end
    if playerLevel <= 59 then return 16 end
    return 17
end

-- Classic Era XP formula:
--   baseXP = 5 * playerLevel + 45  (XP for a perfectly same-level kill)
--   mob below player: scales linearly down to 0 at the ZD cutoff
--   mob above player: +5% per level above, capped at +4 levels (+20% max)
function HowManyMobs:EstimateMobXP(mobLevel, playerLevel)
    if not mobLevel or mobLevel < 1 then mobLevel = playerLevel end
    local baseXP = 5 * playerLevel + 45
    local levelDiff = playerLevel - mobLevel
    local zd = self:GetZD(playerLevel)
    -- Gray mobs give 0 XP when levelDiff >= ZD (not hardcoded to 5)
    if levelDiff >= zd then
        return 0
    elseif levelDiff >= 0 then
        local factor = 1 - (levelDiff / zd)
        if factor <= 0 then return 0 end
        return math.floor(baseXP * factor + 0.5)
    else
        local higherDiff = math.min(-levelDiff, 4)
        return math.floor(baseXP * (1 + 0.05 * higherDiff) + 0.5)
    end
end

function HowManyMobs:GetKillEfficiency(mobLevel, playerLevel)
    if not mobLevel or mobLevel < 1 then mobLevel = playerLevel end
    local mobXP = self:EstimateMobXP(mobLevel, playerLevel)
    local maxXP = self:EstimateMobXP(playerLevel, playerLevel)
    
    if maxXP <= 0 then return "|cff999999", 0 end  -- Protect against divide by zero
    
    if mobXP <= 0 then 
        return "|cffff0000", 0  -- Red for gray mobs
    end
    
    local efficiency = math.floor((mobXP / maxXP) * 100 + 0.5)
    
    if efficiency >= 80 then
        return "|cff00ff00", efficiency
    elseif efficiency >= 50 then
        return "|cffffff00", efficiency
    elseif efficiency > 0 then
        return "|cffff9900", efficiency
    else
        return "|cffff0000", 0
    end
end

function HowManyMobs:UpdateEfficiencyText()
    -- Display efficiency using real XP data when available, falling back to estimates
    if not self.efficiencyText or not HowManyMobsDB.showEfficiency then return end
    
    if HowManyMobsDB.lastMobs and #HowManyMobsDB.lastMobs > 0 then
        local avgEfficiency = self:GetRollingEfficiency()
        
        local colorCode
        if avgEfficiency >= 80 then
            colorCode = "|cff00ff00"
        elseif avgEfficiency >= 50 then
            colorCode = "|cffffff00"
        elseif avgEfficiency > 0 then
            colorCode = "|cffff9900"
        else
            colorCode = "|cffff0000"
        end
        
        local efficiencyDisplay = ""
        if avgEfficiency == 0 then
            efficiencyDisplay = colorCode .. "0% (Gray)|r"
        else
            efficiencyDisplay = colorCode .. avgEfficiency .. "%|r avg (3-mob rolling)"
        end
        
        self.efficiencyText:SetText("|cffffd700Efficiency:|r " .. efficiencyDisplay)
    else
        self.efficiencyText:SetText("|cffffd700Efficiency:|r |cff99ccffKill a mob|r")
    end
end

function HowManyMobs:GetRollingEfficiency()
    -- Uses real XP from session kills when available for accurate efficiency
    -- Falls back to level-based estimates otherwise
    local playerLevel = UnitLevel("player")
    local baseXP = self:EstimateMobXP(playerLevel, playerLevel)
    if baseXP <= 0 then return 0 end
    local efficiencies = {}
    
    -- Check last 3 kills - prefer real XP from session data
    for i = 1, math.min(3, #HowManyMobsDB.lastMobs) do
        local mob = HowManyMobsDB.lastMobs[i]
        if mob and mob.level and mob.level >= 1 then
            -- Try to find real XP from session tracking first
            local realXP = nil
            if self.sessionMobKills then
                for _, kill in ipairs(self.sessionMobKills) do
                    if kill.name == mob.name and kill.xpGained and kill.xpGained > 0 then
                        -- Use base (non-rested) XP for accurate efficiency
                        realXP = kill.baseXP or kill.xpGained
                        break
                    end
                end
            end
            
            if realXP then
                -- Real XP efficiency is more accurate than estimates
                local eff = math.floor((realXP / baseXP) * 100 + 0.5)
                table.insert(efficiencies, math.min(eff, 120))  -- Cap at 120% (higher-level mobs)
            else
                local _, eff = self:GetKillEfficiency(mob.level, playerLevel)
                table.insert(efficiencies, eff)
            end
        end
    end
    
    if #efficiencies == 0 then return 0 end
    
    -- Return average of last 3 efficiencies
    local total = 0
    for _, eff in ipairs(efficiencies) do
        total = total + eff
    end
    return math.floor(total / #efficiencies + 0.5)
end

function HowManyMobs:GetXPVariance()
    -- XP VARIANCE CALCULATION (improvement #3)
    -- Calculates standard deviation of recent XP gains
    -- Used to show confidence range: "10 mobs (±2)" means expect 8-12 mobs
    -- Helps players understand prediction accuracy
    -- Only shows when variance is significant and enough kills tracked (3+)
    if not self.sessionMobKills or #self.sessionMobKills < 3 then return 0 end
    
    local xpValues = {}
    for _, kill in ipairs(self.sessionMobKills) do
        if kill.xpGained and kill.xpGained > 0 then
            -- Use base (non-rested) XP for consistent variance
            table.insert(xpValues, kill.baseXP or kill.xpGained)
        end
    end
    
    if #xpValues < 2 then return 0 end
    
    -- Calculate mean
    local mean = 0
    for _, xp in ipairs(xpValues) do
        mean = mean + xp
    end
    mean = mean / #xpValues
    
    -- Calculate standard deviation
    local sumSquaredDiff = 0
    for _, xp in ipairs(xpValues) do
        sumSquaredDiff = sumSquaredDiff + (xp - mean) ^ 2
    end
    local variance = sumSquaredDiff / #xpValues
    local stdDev = math.sqrt(variance)
    
    return stdDev
end

-- Track mobs the player/party has damaged (to filter out other players' kills)
HowManyMobs.damagedMobs = {}
HowManyMobs.lastDamagedMobsPrune = 0

-- ============================================
-- EVENTS
-- ============================================
function HowManyMobs:OnCombatLogEvent()
    if not HowManyMobsDB or not HowManyMobsDB.trackingEnabled then return end
    local _, eventType, _, _, sourceName, sourceFlags, _, destGUID, destName, destFlags = CombatLogGetCurrentEventInfo()
    
    -- Track mobs we (or our group) have damaged
    if destName and destGUID and (
        eventType == "SWING_DAMAGE" or eventType == "SPELL_DAMAGE" or 
        eventType == "RANGE_DAMAGE" or eventType == "SPELL_PERIODIC_DAMAGE"
    ) then
        local isPlayerSource = bit.band(sourceFlags, COMBATLOG_OBJECT_AFFILIATION_MINE) ~= 0
                            or bit.band(sourceFlags, COMBATLOG_OBJECT_AFFILIATION_PARTY) ~= 0
                            or bit.band(sourceFlags, COMBATLOG_OBJECT_AFFILIATION_RAID) ~= 0
        if isPlayerSource then
            local now = GetTime()
            self.damagedMobs[destGUID] = { name = destName, time = now }
            -- Prune old entries at most once every 60 seconds
            if now - self.lastDamagedMobsPrune > 60 then
                self.lastDamagedMobsPrune = now
                for guid, data in pairs(self.damagedMobs) do
                    if now - data.time > 300 then
                        self.damagedMobs[guid] = nil
                    end
                end
            end
        end
    end
    
    if eventType ~= "UNIT_DIED" or not destName then return end

    -- Only count mobs we've actually damaged (filters out other players' kills)
    if destGUID and not self.damagedMobs[destGUID] then return end
    if destGUID then self.damagedMobs[destGUID] = nil end

    local isPlayer = bit.band(destFlags, COMBATLOG_OBJECT_TYPE_PLAYER) ~= 0
    local isAlly = bit.band(destFlags, COMBATLOG_OBJECT_AFFILIATION_MINE) ~= 0 
                or bit.band(destFlags, COMBATLOG_OBJECT_AFFILIATION_PARTY) ~= 0 
                or bit.band(destFlags, COMBATLOG_OBJECT_AFFILIATION_RAID) ~= 0
    if isPlayer or isAlly then return end

    local mobLevel = self:GetCachedMobLevel(destName)
    if not mobLevel then
        local currentTargetName = UnitName("target") or ""
        if currentTargetName == destName then
            mobLevel = UnitLevel("target")
            if mobLevel and mobLevel > 0 then
                -- Cache this valid mob level using multi-entry cache
                self.targetCache[destName] = {
                    level = mobLevel,
                    lastUpdated = GetTime()
                }
            end
        end
    end
    if not mobLevel or mobLevel < 1 then
        -- Improved fallback: only use previous mob level if current is invalid
        mobLevel = (HowManyMobsDB.lastMobs and HowManyMobsDB.lastMobs[1] and HowManyMobsDB.lastMobs[1].level) or UnitLevel("player")
    end

    self:AddMobToHistory(destName, mobLevel)
    self:UpdateMobCount()
end

function HowManyMobs:OnXPUpdate()
    local currentXP = UnitXP("player")
    local gained = currentXP - (self.lastXP or currentXP)

    if gained <= 0 then
        self.lastXP = currentXP
        return
    end

    -- Improved real XP linking: more forgiving window + better detection
    -- Increased from 20s to 45s to handle looting, delays between kills
    local now = GetTime()
    local matched = false

    if self.sessionMobKills and #self.sessionMobKills > 0 then
        for _, kill in ipairs(self.sessionMobKills) do
            local dt = now - kill.time

            if dt >= 0 and dt < 45 then
                if not kill.xpAssigned then
                    -- Sanity check: reject XP gains that are too large to be a mob kill
                    -- (e.g. quest turn-ins). Max mob XP at +4 levels is ~1.2x base XP;
                    -- with rested that doubles to ~2.4x. Use 3x as a safe ceiling.
                    local maxMobXP = (5 * UnitLevel("player") + 45) * 3
                    if gained > maxMobXP then break end
                    kill.xpGained = gained
                    kill.xpAssigned = true
                    matched = true
                    break
                end
            end
        end
    end

    -- Only record XP for rolling average if it was matched to a kill
    -- This prevents quest turn-ins, exploration, and discovery XP from
    -- polluting the mob kill average and skewing "mobs to level" count
    if matched then
        self.sessionTotalXP = (self.sessionTotalXP or 0) + gained
        
        -- Detect rested XP using the API: if player has rested bonus, the kill XP
        -- includes a rested portion. Store the base (non-rested) XP for predictions
        -- so "mobs to level" stays accurate when rested runs out.
        local exhaustion = GetXPExhaustion()
        local isRested = exhaustion and exhaustion > 0
        local baseGained = isRested and math.floor(gained / 2 + 0.5) or gained
        
        if isRested then
            -- Player is rested: the gained XP is roughly 2x base for kill XP
            -- Find the kill we just assigned this XP to and store baseXP
            for _, kill in ipairs(self.sessionMobKills) do
                if kill.xpAssigned and kill.xpGained == gained and not kill.baseXP then
                    kill.rested = true
                    kill.baseXP = baseGained
                    break
                end
            end
        end
        
        -- Store base (non-rested) XP in rolling average so predictions
        -- stay accurate when rested runs out
        table.insert(HowManyMobsDB.recentRealXPGains, 1, baseGained)
        if #HowManyMobsDB.recentRealXPGains > 12 then
            table.remove(HowManyMobsDB.recentRealXPGains, 13)
        end
    end

    self.lastXP = currentXP
    self:UpdateMobCount()   -- always update now
end

function HowManyMobs:OnPlayerLogin()
    -- Ensure DB exists
    HowManyMobsDB = HowManyMobsDB or {}

    -- Fill missing values safely
    CopyDefaults(DEFAULTS, HowManyMobsDB)


    print("|cff00ff00" .. ADDON_NAME .. "|r |cff888888v" .. VERSION .. "|r loaded! |cffffff00/hmm help|r")
    
    -- Reset session tracking for fresh session on login
    self.firstKillTime = nil
    self.sessionKills = 0
    self.sessionTotalXP = 0
    self.sessionMobKills = {}

    -- Sync lastXP to current value to prevent bogus gain on first XP event
    self.lastXP = UnitXP("player")

    if HowManyMobsDB.lastMobName and (not HowManyMobsDB.lastMobs or #HowManyMobsDB.lastMobs == 0) then
        HowManyMobsDB.lastMobs = {{name = HowManyMobsDB.lastMobName, level = HowManyMobsDB.lastMobLevel or UnitLevel("player"), time = GetTime()}}
        HowManyMobsDB.lastMobName = nil
        HowManyMobsDB.lastMobLevel = nil
    end

    self:CreateUI()
    if not self.settingsRegistered then
        self:RegisterSettingsPanel()
        self.settingsRegistered = true
    end

    self:UpdateMobCount()
end

function HowManyMobs:OnPlayerEnteringWorld()
    C_Timer.After(2, function() self:CreateMinimapButton() end)
end

-- MAIN EVENT HANDLER - Central dispatcher for all tracked events
-- Flow: Combat kill → AddMobToHistory → OnXPUpdate → UpdateMobCount (displays all stats)
-- Real XP linking: Kill is recorded, XP event links the real XP to that kill (45s window)
-- Uses weighted averages for all calculations (see improvements #2, #3, #5, #8)
function HowManyMobs:OnEvent(event, ...)
    if event == "PLAYER_LOGIN" then
        self:OnPlayerLogin()
    elseif event == "PLAYER_ENTERING_WORLD" then
        self:OnPlayerEnteringWorld()
    elseif event == "COMBAT_LOG_EVENT_UNFILTERED" then
        self:OnCombatLogEvent()
    elseif event == "PLAYER_XP_UPDATE" then
        self:OnXPUpdate()
    elseif event == "PLAYER_TARGET_CHANGED" then
        self:UpdateTargetCache()
    elseif event == "PLAYER_LEVEL_UP" then
        self:OnPlayerLevelUp()
    end
end

HowManyMobs:SetScript("OnEvent", HowManyMobs.OnEvent)

-- Slash commands
function HowManyMobs:PrintHelp()
    print("|cff00ff00HowManyMobs v" .. VERSION .. "|r - Grinding Tracker")
    print("Commands: /hmm show | hide | toggle | reset | button | help")
    print("/hmm lock | unlock | scale <0.5-2.0> | opacity <0-1>")
end

SLASH_HOWMANYMOBS1 = "/hmm"
SLASH_HOWMANYMOBS2 = "/howmanymobs"

SlashCmdList["HOWMANYMOBS"] = function(msg)
    local cmd, arg = msg:match("^(%S*)%s*(.*)")
    cmd = cmd:lower()
    if cmd == "show" or cmd == "info" or cmd == "" then
        if HowManyMobs.UIFrame then HowManyMobs.UIFrame:Show() else HowManyMobs:CreateUI() end
        HowManyMobs:UpdateMobCount()
    elseif cmd == "hide" then
        if HowManyMobs.UIFrame then HowManyMobs.UIFrame:Hide() end
    elseif cmd == "button" then
        if HowManyMobs.MinimapButton then HowManyMobs.MinimapButton:Show() else HowManyMobs:CreateMinimapButton() end
    elseif cmd == "help" then
        HowManyMobs:PrintHelp()
    elseif cmd == "reset" then
        HowManyMobsDB.lastMobs = {}
        HowManyMobsDB.recentRealXPGains = {}
        HowManyMobs.sessionMobKills = {}
        HowManyMobs.sessionKills = 0
        HowManyMobs.sessionTotalXP = 0
        HowManyMobs.firstKillTime = nil
        HowManyMobs.damagedMobs = {}
        print("|cff00ff00HowManyMobs:|r All data reset.")
        if HowManyMobs.mobsNeededText then HowManyMobs:UpdateMobCount() end
    elseif cmd == "toggle" then
        HowManyMobsDB.trackingEnabled = not HowManyMobsDB.trackingEnabled
        print("|cff00ff00HowManyMobs:|r Tracking " .. (HowManyMobsDB.trackingEnabled and "enabled" or "disabled"))
    elseif cmd == "lock" then
        HowManyMobsDB.uiLocked = true
        print("|cff00ff00HowManyMobs:|r Frame locked")
    elseif cmd == "unlock" then
        HowManyMobsDB.uiLocked = false
        print("|cff00ff00HowManyMobs:|r Frame unlocked")
    elseif cmd == "scale" then
        local scale = tonumber(arg)
        if scale and scale >= 0.5 and scale <= 2.0 then
            HowManyMobsDB.uiScale = scale
            HowManyMobs:ApplyUISettings()
            print("|cff00ff00HowManyMobs:|r Scale set to " .. scale)
        end
    elseif cmd == "opacity" then
        local opacity = tonumber(arg)
        if opacity and opacity >= 0 and opacity <= 1 then
            HowManyMobsDB.uiOpacity = opacity
            HowManyMobs:ApplyBoxOpacity()
            print("|cff00ff00HowManyMobs:|r Opacity set to " .. math.floor(opacity*100) .. "%")
        end
    else
        HowManyMobs:PrintHelp()
    end
end

-- Full settings panel
function HowManyMobs:CreateSettingsPanel()
    local panel = CreateFrame("Frame", "HowManyMobsSettingsPanel", UIParent)
    panel.name = "How Many Mobs (Grinding Tracker)"

    local function AddTooltip(element, text)
        element:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:AddLine(text, 1, 1, 1, true)
            GameTooltip:Show()
        end)
        element:SetScript("OnLeave", function() GameTooltip:Hide() end)
    end

    local title = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", 16, -16)
    title:SetText("How Many Mobs - Grinding Tracker v" .. VERSION)

    local scaleLabel = panel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    scaleLabel:SetPoint("TOPLEFT", 16, -50)
    scaleLabel:SetText("UI Scale (0.5 - 2.0):")
    local scaleSlider = CreateFrame("Slider", "HowManyMobsScaleSlider", panel, "UISliderTemplate")
    scaleSlider:SetPoint("TOPLEFT", 16, -75)
    scaleSlider:SetSize(200, 17)
    scaleSlider:SetMinMaxValues(0.5, 2.0)
    scaleSlider:SetValue(HowManyMobsDB.uiScale or 1.0)
    scaleSlider:SetValueStep(0.1)
    local scaleValueText = panel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    scaleValueText:SetPoint("LEFT", scaleSlider, "RIGHT", 10, 0)
    scaleValueText:SetText(string.format("%.1f", HowManyMobsDB.uiScale or 1.0))
    scaleSlider:SetScript("OnValueChanged", function(self, value)
        HowManyMobsDB.uiScale = value
        if HowManyMobs.UIFrame then HowManyMobs.UIFrame:SetScale(value) end
        scaleValueText:SetText(string.format("%.1f", value))
    end)
    AddTooltip(scaleSlider, "Adjust the size of the HowManyMobs tracking window")

    local opacityLabel = panel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    opacityLabel:SetPoint("TOPLEFT", 16, -120)
    opacityLabel:SetText("Box Opacity (Background + Border):")
    local opacitySlider = CreateFrame("Slider", "HowManyMobsOpacitySlider", panel, "UISliderTemplate")
    opacitySlider:SetPoint("TOPLEFT", 16, -145)
    opacitySlider:SetSize(200, 17)
    opacitySlider:SetMinMaxValues(0, 1)
    opacitySlider:SetValue(HowManyMobsDB.uiOpacity or 0.85)
    opacitySlider:SetValueStep(0.05)
    local opacityValueText = panel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    opacityValueText:SetPoint("LEFT", opacitySlider, "RIGHT", 10, 0)
    opacityValueText:SetText(string.format("%d%%", (HowManyMobsDB.uiOpacity or 0.85) * 100))
    opacitySlider:SetScript("OnValueChanged", function(self, value)
        HowManyMobsDB.uiOpacity = value
        HowManyMobs:ApplyBoxOpacity()
        opacityValueText:SetText(string.format("%d%%", value * 100))
    end)
    AddTooltip(opacitySlider, "Controls the transparency of the UI window background")

    local lockCheck = CreateFrame("CheckButton", "HowManyMobsLockCheck", panel, "UICheckButtonTemplate")
    lockCheck:SetPoint("TOPLEFT", 16, -190)
    lockCheck.text = lockCheck:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    lockCheck.text:SetPoint("LEFT", lockCheck, "RIGHT", 4, 0)
    lockCheck.text:SetText("Lock Frame Position")
    lockCheck:SetChecked(HowManyMobsDB.uiLocked)
    lockCheck:SetScript("OnClick", function(self)
        HowManyMobsDB.uiLocked = self:GetChecked()
    end)
    AddTooltip(lockCheck, "When locked, you won't be able to drag the window around")

    local showLastCheck = CreateFrame("CheckButton", "HowManyMobsShowLastCheck", panel, "UICheckButtonTemplate")
    showLastCheck:SetPoint("TOPLEFT", 16, -220)
    showLastCheck.text = showLastCheck:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    showLastCheck.text:SetPoint("LEFT", showLastCheck, "RIGHT", 4, 0)
    showLastCheck.text:SetText("Show \"Last killed\" line")
    showLastCheck:SetChecked(HowManyMobsDB.showLastKilled)
    showLastCheck:SetScript("OnClick", function(self)
        HowManyMobsDB.showLastKilled = self:GetChecked()
        HowManyMobs:UpdateLastKilledText()
        HowManyMobs:UpdateUILayout()
    end)
    AddTooltip(showLastCheck, "Display the name and level of the last mob you killed")

    local showLevelCheck = CreateFrame("CheckButton", "HowManyMobsShowLevelCheck", panel, "UICheckButtonTemplate")
    showLevelCheck:SetPoint("TOPLEFT", 16, -250)
    showLevelCheck.text = showLevelCheck:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    showLevelCheck.text:SetPoint("LEFT", showLevelCheck, "RIGHT", 4, 0)
    showLevelCheck.text:SetText("Show mob level in \"Last killed\" line")
    showLevelCheck:SetChecked(HowManyMobsDB.showMobLevel)
    showLevelCheck:SetScript("OnClick", function(self)
        HowManyMobsDB.showMobLevel = self:GetChecked()
        HowManyMobs:UpdateLastKilledText()
    end)
    AddTooltip(showLevelCheck, "Displays the level of the last killed mob next to its name")

    local showAvgXPCheck = CreateFrame("CheckButton", "HowManyMobsShowAvgXPCheck", panel, "UICheckButtonTemplate")
    showAvgXPCheck:SetPoint("TOPLEFT", 16, -280)
    showAvgXPCheck.text = showAvgXPCheck:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    showAvgXPCheck.text:SetPoint("LEFT", showAvgXPCheck, "RIGHT", 4, 0)
    showAvgXPCheck.text:SetText("Show Average XP per Kill")
    showAvgXPCheck:SetChecked(HowManyMobsDB.showAverageXP)
    showAvgXPCheck:SetScript("OnClick", function(self)
        HowManyMobsDB.showAverageXP = self:GetChecked()
        HowManyMobs:UpdateAverageXPText()
        HowManyMobs:UpdateUILayout()
    end)
    AddTooltip(showAvgXPCheck, "Shows the average XP you get per mob kill (rolling real XP)")

    local showEfficiencyCheck = CreateFrame("CheckButton", "HowManyMobsShowEfficiencyCheck", panel, "UICheckButtonTemplate")
    showEfficiencyCheck:SetPoint("TOPLEFT", 16, -310)
    showEfficiencyCheck.text = showEfficiencyCheck:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    showEfficiencyCheck.text:SetPoint("LEFT", showEfficiencyCheck, "RIGHT", 4, 0)
    showEfficiencyCheck.text:SetText("Show Kill Efficiency Rating")
    showEfficiencyCheck:SetChecked(HowManyMobsDB.showEfficiency)
    showEfficiencyCheck:SetScript("OnClick", function(self)
        HowManyMobsDB.showEfficiency = self:GetChecked()
        HowManyMobs:UpdateEfficiencyText()
        HowManyMobs:UpdateUILayout()
    end)
    AddTooltip(showEfficiencyCheck, "Color-coded efficiency: green=80%+ (great), yellow=50-79% (good), orange=1-49% (poor), red=0% (gray mobs). Calculated as: (XP from mob / XP from same-level mob) × 100%")

    local showTimeCheck = CreateFrame("CheckButton", "HowManyMobsShowTimeCheck", panel, "UICheckButtonTemplate")
    showTimeCheck:SetPoint("TOPLEFT", 16, -340)
    showTimeCheck.text = showTimeCheck:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    showTimeCheck.text:SetPoint("LEFT", showTimeCheck, "RIGHT", 4, 0)
    showTimeCheck.text:SetText("Show Estimated Time to Level")
    showTimeCheck:SetChecked(HowManyMobsDB.showEstimatedTime)
    showTimeCheck:SetScript("OnClick", function(self)
        HowManyMobsDB.showEstimatedTime = self:GetChecked()
        HowManyMobs:UpdateEstimatedTimeText()
        HowManyMobs:UpdateUILayout()
    end)
    AddTooltip(showTimeCheck, "Estimates how long it will take to reach the next level")

    local showSessionCheck = CreateFrame("CheckButton", "HowManyMobsShowSessionCheck", panel, "UICheckButtonTemplate")
    showSessionCheck:SetPoint("TOPLEFT", 16, -370)
    showSessionCheck.text = showSessionCheck:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    showSessionCheck.text:SetPoint("LEFT", showSessionCheck, "RIGHT", 4, 0)
    showSessionCheck.text:SetText("Show Session Stats")
    showSessionCheck:SetChecked(HowManyMobsDB.showSessionStats)
    showSessionCheck:SetScript("OnClick", function(self)
        HowManyMobsDB.showSessionStats = self:GetChecked()
        if HowManyMobs.sessionStatsText then
            if HowManyMobsDB.showSessionStats then
                HowManyMobs.sessionStatsText:Show()
            else
                HowManyMobs.sessionStatsText:Hide()
            end
        end
        HowManyMobs:UpdateUILayout()
    end)
    AddTooltip(showSessionCheck, "Shows XP/hr and kills/hr for your current session")

    local resetBtn = CreateFrame("Button", "HowManyMobsResetBtn", panel, "GameMenuButtonTemplate")
    resetBtn:SetPoint("TOPLEFT", 16, -410)
    resetBtn:SetSize(120, 25)
    resetBtn:SetText("Reset All Data")
    resetBtn:SetScript("OnClick", function()
        HowManyMobsDB.lastMobs = {}
        HowManyMobsDB.recentRealXPGains = {}
        HowManyMobsDB.uiScale = 1.0
        HowManyMobsDB.uiOpacity = 0.85
        HowManyMobsDB.uiLocked = false
        HowManyMobsDB.showLastKilled = true
        HowManyMobsDB.showMobLevel = true
        HowManyMobsDB.showAverageXP = false
        HowManyMobsDB.showEfficiency = true
        HowManyMobsDB.showEstimatedTime = false
        HowManyMobsDB.showSessionStats = true
        HowManyMobs.sessionMobKills = {}
        HowManyMobs.sessionKills = 0
        HowManyMobs.sessionTotalXP = 0
        HowManyMobs.firstKillTime = nil
        HowManyMobs.damagedMobs = {}
        scaleSlider:SetValue(1.0)
        opacitySlider:SetValue(0.85)
        lockCheck:SetChecked(false)
        showLastCheck:SetChecked(true)
        showLevelCheck:SetChecked(true)
        showAvgXPCheck:SetChecked(false)
        showEfficiencyCheck:SetChecked(true)
        showTimeCheck:SetChecked(false)
        showSessionCheck:SetChecked(true)
        HowManyMobs:ApplyUISettings()
        HowManyMobs:UpdateUILayout()
        HowManyMobs:UpdateMobCount()
    end)
    AddTooltip(resetBtn, "Reset all settings and tracking data to defaults")

    -- Info section about efficiency
    local infoSeperator = panel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    infoSeperator:SetPoint("TOPLEFT", 16, -460)
    infoSeperator:SetText("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")

    local efficiencyInfo = panel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    efficiencyInfo:SetPoint("TOPLEFT", 16, -490)
    efficiencyInfo:SetText("Efficiency Calculation:")
    
    local efficiencyFormula = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    efficiencyFormula:SetPoint("TOPLEFT", 16, -515)
    efficiencyFormula:SetText("(XP from current mob / XP from same-level mob) × 100%")
    efficiencyFormula:SetTextColor(0.7, 0.7, 1)

    local efficiencyExample = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    efficiencyExample:SetPoint("TOPLEFT", 16, -535)
    efficiencyExample:SetText("Example: Level 20 grinding Level 20 mobs = 100% efficient")
    efficiencyExample:SetTextColor(0.7, 0.7, 1)

    local efficiencyTip = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    efficiencyTip:SetPoint("TOPLEFT", 16, -555)
    efficiencyTip:SetText("Green (80%+) = Optimal grind spot | Yellow (50-79%) = Good")
    efficiencyTip:SetTextColor(0.7, 0.7, 1)

    local efficiencyTip2 = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    efficiencyTip2:SetPoint("TOPLEFT", 16, -570)
    efficiencyTip2:SetText("Orange (1-49%) = Low XP | Red (0%) = Gray mobs (no XP)")
    efficiencyTip2:SetTextColor(0.7, 0.7, 1)

    return panel
end

function HowManyMobs:RegisterSettingsPanel()
    local panel = self:CreateSettingsPanel()

    panel.name = "How Many Mobs"

    local category = Settings.RegisterCanvasLayoutCategory(panel, panel.name)
    Settings.RegisterAddOnCategory(category)
end

function HowManyMobs:GetAverageKillTime()
    -- MEDIAN-BASED WITH OUTLIER REMOVAL (improvement #6)
    -- Uses MEDIAN instead of mean to resist single lucky/bad kills
    -- Filters out extreme kill times (>1.5x median) to ignore AFK or one-shots
    -- More accurate time estimates than simple average
    if not self.sessionMobKills or #self.sessionMobKills < 3 then
        return nil
    end

    local times = {}

    -- sessionMobKills[1] is the newest kill, [N] is the oldest (prepended in AddMobToHistory).
    -- For each adjacent pair: t1 = newer kill, t2 = older kill → t1 > t2 is always expected.
    -- dt = t1 - t2 gives the time between two consecutive kills (inter-kill interval).
    for i = 1, #self.sessionMobKills - 1 do
        local t1 = self.sessionMobKills[i].time
        local t2 = self.sessionMobKills[i + 1].time

        if t1 and t2 and t1 > t2 then
            local dt = t1 - t2

            -- Ignore weird gaps (AFK, long breaks)
            if dt > 0 and dt < 120 then
                table.insert(times, dt)
            end
        end
    end

    if #times == 0 then return nil end
    if #times == 1 then return times[1] end

    -- Sort times to find median and detect outliers
    table.sort(times)
    
    -- Use median for more stable average, resistant to outliers
    local medianIndex = math.ceil(#times / 2)
    local median = times[medianIndex]
    
    -- Filter outliers: keep times within 1.5x median
    local filtered = {}
    for _, t in ipairs(times) do
        if t <= median * 1.5 then
            table.insert(filtered, t)
        end
    end
    
    if #filtered == 0 then return median end
    
    -- Return median of filtered times
    table.sort(filtered)
    medianIndex = math.ceil(#filtered / 2)
    return filtered[medianIndex]
end
