-- ============================================
-- HowManyMobs: Grinding Tracker for Classic Era
-- Track how many mobs you need to kill to level up
-- ============================================
-- VERSION 2.1
-- NEW IN 2.1:
--   • PLAYER_LEVEL_UP: automatically resets rolling XP average
--   • Optional "Avg: XXX XP/kill" line (toggleable like Estimated Time)
--   • Version number displayed on load, tooltip and menu
-- ============================================

local ADDON_NAME = "HowManyMobs"
local VERSION = "2.1"

local HowManyMobs = CreateFrame("Frame")
HowManyMobs:RegisterEvent("COMBAT_LOG_EVENT_UNFILTERED")
HowManyMobs:RegisterEvent("PLAYER_LOGIN")
HowManyMobs:RegisterEvent("PLAYER_ENTERING_WORLD")
HowManyMobs:RegisterEvent("PLAYER_XP_UPDATE")
HowManyMobs:RegisterEvent("PLAYER_TARGET_CHANGED")
HowManyMobs:RegisterEvent("PLAYER_LEVEL_UP")

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
HowManyMobs.sessionStartTime = nil
HowManyMobs.firstKillTime = nil
HowManyMobs.sessionXP = 0
HowManyMobs.sessionKills = 0

-- Session mob tracking with REAL XP gained
HowManyMobs.sessionMobKills = {}

-- Target tracking
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

-- ============================================
-- TARGET TRACKING
-- ============================================
function HowManyMobs:UpdateTargetCache()
    local targetName = UnitName("target")
    local targetLevel = UnitLevel("target")
    if targetName and targetLevel then
        self.targetCache.name = targetName
        self.targetCache.level = targetLevel
        self.targetCache.lastUpdated = GetTime()
    end
end

function HowManyMobs:GetCachedMobLevel(mobName)
    if self.targetCache.name == mobName then
        local timeSinceUpdate = GetTime() - (self.targetCache.lastUpdated or 0)
        if timeSinceUpdate < 12 then
            return self.targetCache.level
        end
    end
    return nil
end

-- ============================================
-- ROLLING XP AVERAGE + LEVEL-UP RESET
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
    -- Reset session stats on level up for accurate next-level tracking
    self.sessionXP = 0
    self.sessionKills = 0
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
    if not self.sessionMobKills or #self.sessionMobKills == 0 then return 0 end
    local totalXP = 0
    local count = 0
    for _, kill in ipairs(self.sessionMobKills) do
        if kill.xpGained and kill.xpGained > 0 then
            totalXP = totalXP + kill.xpGained
            count = count + 1
        end
    end
    if count == 0 then return 0 end
    return math.floor(totalXP / count + 0.5)
end

function HowManyMobs:GetAverageMobXP()
    if not HowManyMobsDB.lastMobs or #HowManyMobsDB.lastMobs == 0 then return 0 end
    local totalXP = 0
    local count = 0
    local playerLevel = UnitLevel("player")
    for _, mob in ipairs(HowManyMobsDB.lastMobs) do
        local xp = self:EstimateMobXP(mob.level, playerLevel)
        if xp > 0 then totalXP = totalXP + xp; count = count + 1 end
    end
    if count == 0 then return 0 end
    return math.floor(totalXP / count + 0.5)
end

function HowManyMobs:GetSessionStats()
    if not self.firstKillTime then return 0, 0 end
    local timeElapsed = GetTime() - self.firstKillTime
    if timeElapsed <= 0 then return 0, 0 end
    
    -- Calculate XP only from kills that had XP linked to them
    local totalSessionXP = 0
    if self.sessionMobKills and #self.sessionMobKills > 0 then
        for _, kill in ipairs(self.sessionMobKills) do
            totalSessionXP = totalSessionXP + (kill.xpGained or 0)
        end
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
    -- Use real session XP if available (most accurate)
    if self.sessionMobKills and #self.sessionMobKills >= 2 and self.firstKillTime then
        local oldest, newest = self.sessionMobKills[#self.sessionMobKills], self.sessionMobKills[1]
        if oldest.time and newest.time and newest.time > oldest.time then
            local timeElapsed = newest.time - oldest.time
            if timeElapsed >= 5 then
                local totalXP = 0
                for _, kill in ipairs(self.sessionMobKills) do
                    totalXP = totalXP + (kill.xpGained or 0)
                end
                if totalXP > 0 then
                    local xpPerSecond = totalXP / timeElapsed
                    if xpPerSecond > 0 then
                        local xpNeeded = UnitXPMax("player") - UnitXP("player")
                        if xpNeeded <= 0 then return 0 end
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
                end
            end
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
    local playerLevel = UnitLevel("player")
    for _, mob in ipairs(mobs) do
        totalXP = totalXP + self:EstimateMobXP(mob.level, playerLevel)
    end
    if totalXP <= 0 then return nil end
    local xpPerSecond = totalXP / timeElapsed
    if xpPerSecond <= 0 then return nil end
    local xpNeeded = UnitXPMax("player") - UnitXP("player")
    if xpNeeded <= 0 then return 0 end
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
        self.lastKilledText:SetText("|cffffd700Last killed:|r |cff1eff00" .. latest.name .. levelPart .. "|r")
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

    -- Use session tracked XP first (most accurate), then rolling, then estimates
    local avg = self:GetSessionAverageRealXP()
    if avg == 0 then
        avg = self:GetRollingAverageRealXP()
    end
    if avg == 0 then
        avg = self:GetAverageMobXP()
    end

    if avg > 0 then
        self.averageXPText:SetText("|cffffd700Avg:|r |cff00ff00" .. avg .. " XP/kill|r")
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
        -- Fall back to estimates as last resort
        if averageXP == 0 then
            averageXP = self:GetAverageMobXP()
        end

        if averageXP > 0 then
            local mobsNeeded = math.ceil(xpNeeded / averageXP)
            self.mobsNeededText:SetText("|cffff9900" .. mobsNeeded .. "|r mobs to level up")
        else
            self.mobsNeededText:SetText("|cff99ccffKill a mob to start tracking|r")
        end
    end

    self:UpdateLastKilledText()
    self:UpdateAverageXPText()
    self:UpdateEfficiencyText()
    self:UpdateEstimatedTimeText()
    self:UpdateUILayout()

    local xpHour, killsHour = self:GetSessionStats()
    if self.sessionStatsText then
        self.sessionStatsText:SetText(
            string.format("|cffffd700Session:|r |cff00ff00%.0f XP/hr|r |cff00ccff%.1f kills/hr|r", xpHour, killsHour)
        )
    end
end

-- XP CALCULATION (Classic Era accurate)
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

function HowManyMobs:EstimateMobXP(mobLevel, playerLevel)
    if not mobLevel or mobLevel < 1 then mobLevel = playerLevel end
    local baseXP = 5 * playerLevel + 45
    local levelDiff = playerLevel - mobLevel
    if levelDiff >= 5 then
        return 0
    elseif levelDiff >= 0 then
        local zd = self:GetZD(playerLevel)
        local factor = 1 - (levelDiff / zd)
        if factor <= 0 then return 0 end
        return math.floor(baseXP * factor + 0.5)
    else
        local higherDiff = math.min(-levelDiff, 4)
        return math.floor(baseXP * (1 + 0.05 * higherDiff) + 0.5)
    end
end

function HowManyMobs:GetKillEfficiency(mobLevel, playerLevel)
    if not mobLevel then mobLevel = playerLevel end
    local mobXP = self:EstimateMobXP(mobLevel, playerLevel)
    local maxXP = self:EstimateMobXP(playerLevel, playerLevel)
    if mobXP <= 0 then return "|cff999999", 0 end
    local efficiency = math.floor((mobXP / maxXP) * 100)
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
    if not self.efficiencyText or not HowManyMobsDB.showEfficiency then return end
    if HowManyMobsDB.lastMobs and #HowManyMobsDB.lastMobs > 0 then
        local latest = HowManyMobsDB.lastMobs[1]
        if latest and latest.level then
            local playerLevel = UnitLevel("player")
            local colorCode, efficiency = self:GetKillEfficiency(latest.level, playerLevel)
            self.efficiencyText:SetText("|cffffd700Efficiency:|r " .. colorCode .. efficiency .. "%|r efficiency")
        else
            self.efficiencyText:SetText("|cffffd700Efficiency:|r |cff99ccffNo data|r")
        end
    else
        self.efficiencyText:SetText("|cffffd700Efficiency:|r |cff99ccffKill a mob|r")
    end
end

-- ============================================
-- EVENTS
-- ============================================
function HowManyMobs:OnCombatLogEvent()
    if not HowManyMobsDB or not HowManyMobsDB.trackingEnabled then return end
    local _, eventType, _, _, _, _, _, _, destName, destFlags = CombatLogGetCurrentEventInfo()
    if eventType ~= "UNIT_DIED" or not destName then return end

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
        end
    end
    if not mobLevel then
        mobLevel = (HowManyMobsDB.lastMobs and HowManyMobsDB.lastMobs[1] and HowManyMobsDB.lastMobs[1].level) or UnitLevel("player")
    end

    self:AddMobToHistory(destName, mobLevel)
    self:UpdateMobCount()
end

function HowManyMobs:OnXPUpdate()
    local currentXP = UnitXP("player")
    local gained = currentXP - (self.lastXP or currentXP)

    if gained < 0 then
        self.lastXP = currentXP
        return
    end

    if gained > 0 then
        -- Only track XP if we have recent kills (filters out non-combat XP)
        if self.sessionMobKills and #self.sessionMobKills > 0 then
            -- Link XP to the most recent kill (within 10 seconds for group content delays)
            local recentKill = self.sessionMobKills[1]
            local timeSinceKill = GetTime() - recentKill.time
            if timeSinceKill < 10 then
                recentKill.xpGained = (recentKill.xpGained or 0) + gained
                self.sessionXP = (self.sessionXP or 0) + gained
                
                -- Add to real XP gains tracking
                table.insert(HowManyMobsDB.recentRealXPGains, 1, gained)
                if #HowManyMobsDB.recentRealXPGains > 8 then
                    table.remove(HowManyMobsDB.recentRealXPGains, 9)
                end
            end
        end
    end

    self.lastXP = currentXP

    if HowManyMobsDB.lastMobs and #HowManyMobsDB.lastMobs > 0 then
        self:UpdateMobCount()
    end
end

function HowManyMobs:OnPlayerLogin()
    print("|cff00ff00" .. ADDON_NAME .. "|r v" .. VERSION .. " - Grinding Tracker loaded!")
    
    -- Reset session tracking for fresh session on login
    self.firstKillTime = nil
    self.sessionXP = 0
    self.sessionKills = 0
    self.sessionMobKills = {}

    if HowManyMobsDB.lastMobName and (not HowManyMobsDB.lastMobs or #HowManyMobsDB.lastMobs == 0) then
        HowManyMobsDB.lastMobs = {{name = HowManyMobsDB.lastMobName, level = HowManyMobsDB.lastMobLevel or UnitLevel("player"), time = GetTime()}}
        HowManyMobsDB.lastMobName = nil
        HowManyMobsDB.lastMobLevel = nil
    end

    self:CreateUI()
    self:RegisterSettingsPanel()

    self:UpdateMobCount()
end

function HowManyMobs:OnPlayerEnteringWorld()
    C_Timer.After(2, function() self:CreateMinimapButton() end)
end

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
    local panel = CreateFrame("Frame", "HowManyMobsSettingsPanel")
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
    lockCheck:SetChecked(HowManyMobsDB.uiLocked or false)
    lockCheck:SetScript("OnClick", function(self)
        HowManyMobsDB.uiLocked = self:GetChecked()
    end)
    AddTooltip(lockCheck, "When locked, you won't be able to drag the window around")

    local showLastCheck = CreateFrame("CheckButton", "HowManyMobsShowLastCheck", panel, "UICheckButtonTemplate")
    showLastCheck:SetPoint("TOPLEFT", 16, -220)
    showLastCheck.text = showLastCheck:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    showLastCheck.text:SetPoint("LEFT", showLastCheck, "RIGHT", 4, 0)
    showLastCheck.text:SetText("Show \"Last killed\" line")
    showLastCheck:SetChecked(HowManyMobsDB.showLastKilled or true)
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
    showLevelCheck:SetChecked(HowManyMobsDB.showMobLevel or true)
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
    showAvgXPCheck:SetChecked(HowManyMobsDB.showAverageXP or false)
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
    showEfficiencyCheck:SetChecked(HowManyMobsDB.showEfficiency or true)
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
    showTimeCheck:SetChecked(HowManyMobsDB.showEstimatedTime or false)
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
    showSessionCheck:SetChecked(HowManyMobsDB.showSessionStats or true)
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
    
    local efficiencyFormula = panel:CreateFontString(nil, "OVERLAY", "GameFontSmall")
    efficiencyFormula:SetPoint("TOPLEFT", 16, -515)
    efficiencyFormula:SetText("(XP from current mob / XP from same-level mob) × 100%")
    efficiencyFormula:SetTextColor(0.7, 0.7, 1)

    local efficiencyExample = panel:CreateFontString(nil, "OVERLAY", "GameFontSmall")
    efficiencyExample:SetPoint("TOPLEFT", 16, -535)
    efficiencyExample:SetText("Example: Level 20 grinding Level 20 mobs = 100% efficient")
    efficiencyExample:SetTextColor(0.7, 0.7, 1)

    local efficiencyTip = panel:CreateFontString(nil, "OVERLAY", "GameFontSmall")
    efficiencyTip:SetPoint("TOPLEFT", 16, -555)
    efficiencyTip:SetText("Green (80%+) = Optimal grind spot | Yellow (50-79%) = Good")
    efficiencyTip:SetTextColor(0.7, 0.7, 1)

    local efficiencyTip2 = panel:CreateFontString(nil, "OVERLAY", "GameFontSmall")
    efficiencyTip2:SetPoint("TOPLEFT", 16, -570)
    efficiencyTip2:SetText("Orange (1-49%) = Low XP | Red (0%) = Gray mobs (no XP)")
    efficiencyTip2:SetTextColor(0.7, 0.7, 1)

    return panel
end

function HowManyMobs:RegisterSettingsPanel()
    local panel = self:CreateSettingsPanel()
    if Settings and Settings.RegisterCanvasLayoutCategory then
        local category = Settings.RegisterCanvasLayoutCategory(panel, panel.name)
        Settings.RegisterAddOnCategory(category)
    elseif InterfaceOptions_AddCategory then
        InterfaceOptions_AddCategory(panel)
    end
end

print("|cff00ff00HowManyMobs|r v" .. VERSION .. " - Grinding Tracker loaded! Use |cffffff00/hmm help|r")