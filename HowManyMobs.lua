-- ============================================
-- HowManyMobs: Track how many mobs you need to kill to level up
-- Classic Era Addon - Full Feature Set
-- ============================================

local ADDON_NAME = "HowManyMobs"
local HowManyMobs = CreateFrame("Frame")
HowManyMobs:RegisterEvent("COMBAT_LOG_EVENT_UNFILTERED")
HowManyMobs:RegisterEvent("PLAYER_LOGIN")
HowManyMobs:RegisterEvent("PLAYER_ENTERING_WORLD")
HowManyMobs:RegisterEvent("PLAYER_XP_UPDATE")
HowManyMobs:RegisterEvent("PLAYER_TARGET_CHANGED")

-- ============================================
-- UI FRAME REFERENCES
-- ============================================
HowManyMobs.UIFrame = nil
HowManyMobs.mobsNeededText = nil
HowManyMobs.lastKilledText = nil
HowManyMobs.efficiencyText = nil
HowManyMobs.estimatedTimeText = nil
HowManyMobs.MinimapButton = nil
HowManyMobs.lastXP = UnitXP("player")
HowManyMobs.lastXPGain = 0
HowManyMobs.sessionStartTime = GetTime()
HowManyMobs.sessionXP = 0
HowManyMobs.sessionKills = 0

-- Target tracking for accurate mob level detection
HowManyMobs.targetCache = {} -- Stores {name = "", level = 0, lastUpdated = 0}

-- ============================================
-- ERROR HANDLING & LOGGING
-- ============================================
HowManyMobs.debugMode = false

local function SafeLog(message)
    if HowManyMobs.debugMode then
        print("|cff00ff00[HMM-DEBUG]|r " .. tostring(message))
    end
end

local function SafeExecute(func, ...)
    if not func then
        SafeLog("SafeExecute called with nil function")
        return false
    end
    local success, result = pcall(func, ...)
    if not success then
        print("|cffff0000[HowManyMobs Error]|r " .. tostring(result))
    end
    return success, result
end

-- ============================================
-- TARGET TRACKING FOR MOB LEVEL DETECTION
-- ============================================

--- UpdateTargetCache: Tracks the current target's name and level
-- This ensures we capture the mob level BEFORE it dies
-- When a mob dies, we look up its level from this cache
function HowManyMobs:UpdateTargetCache()
    local targetName = UnitName("target")
    local targetLevel = UnitLevel("target")
    
    if targetName and targetLevel then
        self.targetCache.name = targetName
        self.targetCache.level = targetLevel
        self.targetCache.lastUpdated = GetTime()
        SafeLog("Target cached: " .. targetName .. " (Lvl " .. targetLevel .. ")")
    end
end

--- GetCachedMobLevel: Retrieves the mob level from cache
-- @param mobName string The name of the mob to look up
-- @return number The cached mob level, or nil if not found
function HowManyMobs:GetCachedMobLevel(mobName)
    if self.targetCache.name == mobName then
        local timeSinceUpdate = GetTime() - (self.targetCache.lastUpdated or 0)
        if timeSinceUpdate < 5 then  -- Cache valid for 5 seconds
            return self.targetCache.level
        end
    end
    return nil
end

-- ==================== MINIMAP BUTTON (maximum visibility fix) ====================
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

    -- Background (classic minimap button ring)
    local overlay = button:CreateTexture(nil, "OVERLAY")
    overlay:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
    overlay:SetSize(54, 54)
    overlay:SetPoint("TOPLEFT")

    -- Icon (properly padded)
    local icon = button:CreateTexture(nil, "ARTWORK")
    icon:SetSize(20, 20)
    icon:SetPoint("CENTER")

    -- 🔥 Pick a nicer icon here:
    icon:SetTexture("Interface\\Icons\\Ability_Hunter_SniperShot")
    -- alternatives:
    -- "Interface\\Icons\\INV_Sword_04"
    -- "Interface\\Icons\\Ability_Rogue_Ambush"
    -- "Interface\\Icons\\INV_Misc_Map_01"

    button.icon = icon

    -- Highlight
    button:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")
    local highlight = button:GetHighlightTexture()
    highlight:SetBlendMode("ADD")
    highlight:SetAllPoints()

    button:SetPushedTexture("Interface\\Buttons\\UI-Quickslot-Depress")
    local pushed = button:GetPushedTexture()
    pushed:SetAllPoints()

    -- Ensure saved variable exists
    if not HowManyMobsDB.minimapAngle then
        HowManyMobsDB.minimapAngle = 45
    end

    -- Position function (Blizzard-style circular minimap)
    local function UpdatePosition()
        local angle = math.rad(HowManyMobsDB.minimapAngle)
        local radius = 80

        local x = math.cos(angle) * radius
        local y = math.sin(angle) * radius

        button:ClearAllPoints()
        button:SetPoint("CENTER", Minimap, "CENTER", x, y)
    end

    -- Dragging
    button:SetScript("OnDragStart", function(self)
        self.dragging = true
    end)

    button:SetScript("OnDragStop", function(self)
        self.dragging = false
    end)

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

    -- Click behavior (UNCHANGED)
    button:SetScript("OnClick", function(self, mouseButton)
        if mouseButton == "LeftButton" then
            if HowManyMobs.UIFrame then
                if HowManyMobs.UIFrame:IsShown() then
                    HowManyMobs.UIFrame:Hide()
                else
                    HowManyMobs.UIFrame:Show()
                    if HowManyMobsDB.lastMobs and #HowManyMobsDB.lastMobs > 0 then
                        HowManyMobs:UpdateMobCount()
                    end
                end
            else
                HowManyMobs:CreateUI()
            end

        elseif mouseButton == "RightButton" then
            HowManyMobs:CreateMinimapMenu()

            ToggleDropDownMenu(1, nil, HowManyMobs.MinimapMenu, self, 0, -5)
        end
    end)

    -- Tooltip
    button:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_LEFT")
        GameTooltip:AddLine("|cff00ff00HowManyMobs|r")
        GameTooltip:AddLine("Left-click to toggle window", 1, 1, 1)
        GameTooltip:Show()

        self.icon:SetDesaturated(false)
    end)

    button:SetScript("OnLeave", function(self)
        GameTooltip:Hide()
        self.icon:SetDesaturated(true)
    end)

    -- Start slightly greyed out
    button.icon:SetDesaturated(true)

    button:Show()
    self.MinimapButton = button

    -- Ensure proper placement AFTER UI loads
    C_Timer.After(0, UpdatePosition)

    print("|cff00ff00HowManyMobs:|r Minimap button created")
end

function HowManyMobs:CreateMinimapMenu()
    if self.MinimapMenu then return end

    local menu = CreateFrame("Frame", "HowManyMobs_MinimapMenu", UIParent, "UIDropDownMenuTemplate")

    local function MenuHandler(_, level)
        if not level then return end

        local info = UIDropDownMenu_CreateInfo()

        -- Title
        info.isTitle = true
        info.text = "HowManyMobs"
        info.notCheckable = true
        UIDropDownMenu_AddButton(info, level)

        -- Show/Hide window
        wipe(info)
        info.text = "Show/Hide Window"
        info.func = function()
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
        end
        info.notCheckable = true
        UIDropDownMenu_AddButton(info, level)

        -- Toggle tracking
        wipe(info)
        info.text = "Enable Tracking"
        info.checked = HowManyMobsDB.trackingEnabled
        info.func = function()
            HowManyMobsDB.trackingEnabled = not HowManyMobsDB.trackingEnabled
        end
        UIDropDownMenu_AddButton(info, level)

        -- Show last killed
        wipe(info)
        info.text = "Show Last Killed"
        info.checked = HowManyMobsDB.showLastKilled
        info.func = function()
            HowManyMobsDB.showLastKilled = not HowManyMobsDB.showLastKilled
            HowManyMobs:UpdateLastKilledText()
            HowManyMobs:UpdateUILayout()
        end
        UIDropDownMenu_AddButton(info, level)

        -- Show mob level
        wipe(info)
        info.text = "Show Mob Level"
        info.checked = HowManyMobsDB.showMobLevel
        info.func = function()
            HowManyMobsDB.showMobLevel = not HowManyMobsDB.showMobLevel
            HowManyMobs:UpdateLastKilledText()
        end
        UIDropDownMenu_AddButton(info, level)

        -- Show estimated time
        wipe(info)
        info.text = "Show Estimated Time"
        info.checked = HowManyMobsDB.showEstimatedTime
        info.func = function()
            HowManyMobsDB.showEstimatedTime = not HowManyMobsDB.showEstimatedTime
            HowManyMobs:UpdateEstimatedTimeText()
            HowManyMobs:UpdateUILayout()
        end
        UIDropDownMenu_AddButton(info, level)

        -- Lock frame
        wipe(info)
        info.text = "Lock Frame"
        info.checked = HowManyMobsDB.uiLocked
        info.func = function()
            HowManyMobsDB.uiLocked = not HowManyMobsDB.uiLocked
        end
        UIDropDownMenu_AddButton(info, level)

        -- Divider
        wipe(info)
        info.disabled = true
        info.notCheckable = true
        UIDropDownMenu_AddButton(info, level)

        -- Reset data
        wipe(info)
        info.text = "Reset Data"
        info.func = function()
            HowManyMobsDB.lastMobs = {}
            HowManyMobs:UpdateMobCount()
        end
        info.notCheckable = true
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

    end

    UIDropDownMenu_Initialize(menu, MenuHandler, "MENU")
    self.MinimapMenu = menu
end

-- ==================== THE REST OF YOUR WORKING SCRIPT (UNCHANGED) ====================
function HowManyMobs:CreateUI()
    if self.UIFrame then 
        print("|cff00ff00HowManyMobs:|r UI already exists")
        self.UIFrame:Show()
        return 
    end
    
    print("|cff00ff00HowManyMobs:|r Creating UI frame...")

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

    local mobsNeededText = UIFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    mobsNeededText:SetPoint("TOPLEFT", UIFrame, "TOPLEFT", 12, -11)
    mobsNeededText:SetWidth(231)
    mobsNeededText:SetJustifyH("LEFT")
    mobsNeededText:SetText("")
    mobsNeededText:SetAlpha(1.0)

    local lastKilledText = UIFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    lastKilledText:SetPoint("TOPLEFT", UIFrame, "TOPLEFT", 12, -31)
    lastKilledText:SetWidth(231)
    lastKilledText:SetJustifyH("LEFT")
    lastKilledText:SetAlpha(1.0)

    local efficiencyText = UIFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    efficiencyText:SetPoint("TOPLEFT", UIFrame, "TOPLEFT", 12, -52)
    efficiencyText:SetWidth(231)
    efficiencyText:SetJustifyH("LEFT")
    efficiencyText:SetAlpha(1.0)

    local estimatedTimeText = UIFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    estimatedTimeText:SetPoint("TOPLEFT", UIFrame, "TOPLEFT", 12, -73)
    estimatedTimeText:SetWidth(231)
    estimatedTimeText:SetJustifyH("LEFT")
    estimatedTimeText:SetAlpha(1.0)

    local sessionStatsText = UIFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    sessionStatsText:SetPoint("TOPLEFT", UIFrame, "TOPLEFT", 12, -94)
    sessionStatsText:SetWidth(231)
    sessionStatsText:SetJustifyH("LEFT")

    self.UIFrame = UIFrame
    self.mobsNeededText = mobsNeededText
    self.lastKilledText = lastKilledText
    self.efficiencyText = efficiencyText
    self.estimatedTimeText = estimatedTimeText
    self.sessionStatsText = sessionStatsText
    self:ApplyUISettings()
    self:UpdateUILayout()
    
    UIFrame:Show()
    print("|cff00ff00HowManyMobs:|r UI frame created and shown successfully!")
end

function HowManyMobs:UpdateUILayout()
    if not self.UIFrame then return end

    local lineHeight = 21
    local topPadding = 11

    local y = -topPadding
    local visibleLines = 1

    -- ALWAYS: main line
    self.mobsNeededText:SetPoint("TOPLEFT", self.UIFrame, "TOPLEFT", 12, y)
    self.mobsNeededText:Show()

    y = y - lineHeight

    -- LAST KILLED
    if HowManyMobsDB.showLastKilled then
        self.lastKilledText:SetPoint("TOPLEFT", self.UIFrame, "TOPLEFT", 12, y)
        self.lastKilledText:Show()
        y = y - lineHeight
        visibleLines = visibleLines + 1
    else
        self.lastKilledText:Hide()
    end

    -- EFFICIENCY RATING
    if HowManyMobsDB.showEfficiency then
        self.efficiencyText:SetPoint("TOPLEFT", self.UIFrame, "TOPLEFT", 12, y)
        self.efficiencyText:Show()
        y = y - lineHeight
        visibleLines = visibleLines + 1
    else
        self.efficiencyText:Hide()
    end

    -- ESTIMATED TIME
    if HowManyMobsDB.showEstimatedTime then
        self.estimatedTimeText:SetPoint("TOPLEFT", self.UIFrame, "TOPLEFT", 12, y)
        self.estimatedTimeText:Show()
        y = y - lineHeight
        visibleLines = visibleLines + 1
    else
        self.estimatedTimeText:Hide()
    end

    -- SESSION STATS (NEW FIXED POSITIONING)
    if HowManyMobsDB.showSessionStats then
        self.sessionStatsText:SetPoint("TOPLEFT", self.UIFrame, "TOPLEFT", 12, y)
        self.sessionStatsText:Show()
        y = y - lineHeight
        visibleLines = visibleLines + 1
    else
        if self.sessionStatsText then
            self.sessionStatsText:Hide()
        end
    end

    -- FINAL HEIGHT (important buffer to prevent clipping)
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

HowManyMobsDB = HowManyMobsDB or {
    lastMobs = {},
    trackingEnabled = true,
    uiX = nil,
    uiY = nil,
    uiScale = 1.0,
    uiOpacity = 0.85,
    uiLocked = false,
    showLastKilled = true,
    showMobLevel = true,
    showEstimatedTime = false,
    showSessionStats = true,
    showEfficiency = true,
    minimapAngle = 45,
}

-- (All your calculation functions are exactly as in your working script)
function HowManyMobs:GetAverageRealXP()
    if not self.lastXPGain or self.lastXPGain <= 0 then
        return 0
    end
    return self.lastXPGain
end

function HowManyMobs:GetSessionStats()
    local timeElapsed = GetTime() - (self.sessionStartTime or GetTime())

    if timeElapsed <= 0 then
        return 0, 0
    end

    local xpHour = (self.sessionXP or 0) / timeElapsed * 3600
    local killsHour = (self.sessionKills or 0) / timeElapsed * 3600

    return xpHour, killsHour
end

function HowManyMobs:AddMobToHistory(destName, destLevel)
    if not destName then return end
    self.sessionKills = (self.sessionKills or 0) + 1

    if not HowManyMobsDB or not HowManyMobsDB.lastMobs then 
        HowManyMobsDB = HowManyMobsDB or {}
        HowManyMobsDB.lastMobs = {} 
    end
    table.insert(HowManyMobsDB.lastMobs, 1, {name = destName, level = destLevel or UnitLevel("player"), time = GetTime()})
    if #HowManyMobsDB.lastMobs > 3 then table.remove(HowManyMobsDB.lastMobs, 4) end
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

function HowManyMobs:GetEstimatedTimeToLevel()
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
    if not self.lastKilledText then return end
    if not HowManyMobsDB.showLastKilled then
        self.lastKilledText:SetText("")
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

function HowManyMobs:UpdateEstimatedTimeText()
    if not self.estimatedTimeText or not HowManyMobsDB.showEstimatedTime then
        return
    end

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
        local averageXP = HowManyMobs:GetAverageRealXP()

        if averageXP == 0 then
            averageXP = HowManyMobs:GetAverageMobXP()
        end

        if averageXP > 0 then
            local mobsNeeded = math.ceil(xpNeeded / averageXP)
            self.mobsNeededText:SetText("|cffff9900" .. mobsNeeded .. "|r mobs to level up")
        else
            self.mobsNeededText:SetText("|cffff0000Gray mob (0 XP)|r")
        end
    end
    self:UpdateLastKilledText()
    self:UpdateEfficiencyText()
    self:UpdateEstimatedTimeText()
    self:UpdateUILayout()

    local xpHour, killsHour = HowManyMobs:GetSessionStats()

    if self.sessionStatsText then
        self.sessionStatsText:SetText(
            string.format(
                "|cffffd700Session:|r |cff00ff00%.0f XP/hr|r |cff00ccff%.1f kills/hr|r",
                xpHour,
                killsHour
            )
        )
    end

end

-- ============================================
-- XP CALCULATION FUNCTIONS
-- Z-value represents the XP penalty range based on player level
-- Formula: XP = baseXP * (1 - levelDiff/ZD) where levelDiff is player-mob delta
-- ============================================

--- GetZD: Returns the Z-value for a given player level
-- This affects XP penalties for lower-level mobs
-- @param playerLevel number Player's current level
-- @return number The Z-value for XP calculation
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

--- EstimateMobXP: Calculates estimated XP for a mob based on level difference
-- Handles yellow/orange/red mobs with proper penalty scaling
-- Gray mobs (5+ levels below) return 0 XP
-- @param mobLevel number|nil The mob's level (defaults to player level)
-- @param playerLevel number The player's current level
-- @return number Estimated XP gain from this mob, 0 if gray
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

-- ============================================
-- KILL EFFICIENCY RATING (#2)
-- ============================================

--- GetKillEfficiency: Calculates and color-codes kill efficiency
-- Returns color code and rating based on XP vs player level
-- @param mobLevel number The mob's level
-- @param playerLevel number The player's current level
-- @return string colorCode The efficiency rating color (green/yellow/red)
-- @return number efficiency The efficiency percentage (0-100)
function HowManyMobs:GetKillEfficiency(mobLevel, playerLevel)
    if not mobLevel then mobLevel = playerLevel end
    
    local mobXP = self:EstimateMobXP(mobLevel, playerLevel)
    local maxXP = self:EstimateMobXP(playerLevel, playerLevel)
    
    if mobXP <= 0 then
        return "|cff999999", 0
    end
    
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

--- UpdateEfficiencyText: Updates the efficiency display line
function HowManyMobs:UpdateEfficiencyText()
    if not self.efficiencyText or not HowManyMobsDB.showEfficiency then
        return
    end
    
    if HowManyMobsDB.lastMobs and #HowManyMobsDB.lastMobs > 0 then
        local latest = HowManyMobsDB.lastMobs[1]
        if latest and latest.level then
            local playerLevel = UnitLevel("player")
            local colorCode, efficiency = self:GetKillEfficiency(latest.level, playerLevel)
            local effText = string.format("%s%d%%|r efficiency", colorCode, efficiency)
            self.efficiencyText:SetText("|cffffd700Efficiency:|r " .. effText)
        else
            self.efficiencyText:SetText("|cffffd700Efficiency:|r |cff99ccffNo data|r")
        end
    else
        self.efficiencyText:SetText("|cffffd700Efficiency:|r |cff99ccffKill a mob|r")
    end
end

function HowManyMobs:OnCombatLogEvent()
    if not HowManyMobsDB or not HowManyMobsDB.trackingEnabled then return end
    local combatInfo = CombatLogGetCurrentEventInfo()
    if not combatInfo then return end
    local _, eventType, _, _, _, _, _, _, destName, destFlags = combatInfo
    if eventType == "UNIT_DIED" then
        if not destName or not destFlags then return end
        local isPlayer = bit.band(destFlags, COMBATLOG_OBJECT_TYPE_PLAYER) ~= 0
        local isAlly = bit.band(destFlags, COMBATLOG_OBJECT_AFFILIATION_MINE) ~= 0 
                   or bit.band(destFlags, COMBATLOG_OBJECT_AFFILIATION_PARTY) ~= 0 
                   or bit.band(destFlags, COMBATLOG_OBJECT_AFFILIATION_RAID) ~= 0
        if not isPlayer and not isAlly and destName then
            local targetName = UnitName("target") or ""
            local targetLevel = nil
            if targetName == destName then
                targetLevel = UnitLevel("target")
            end
            local mobLevel = targetLevel or (HowManyMobsDB.lastMobs and HowManyMobsDB.lastMobs[1] and HowManyMobsDB.lastMobs[1].level) or UnitLevel("player")
            self:AddMobToHistory(destName, mobLevel)
            self:UpdateMobCount()
        end
    end
end

function HowManyMobs:OnXPUpdate()
    local currentXP = UnitXP("player")
    local gained = currentXP - (self.lastXP or currentXP)

    -- level-up reset safety
    if gained < 0 then
        self.lastXP = currentXP
        return
    end

    if gained > 0 then
        self.lastXPGain = gained
    end

    self.sessionXP = (self.sessionXP or 0) + gained

    self.lastXP = currentXP

    if HowManyMobsDB.lastMobs and #HowManyMobsDB.lastMobs > 0 then
        self:UpdateMobCount()
    end
end

function HowManyMobs:OnPlayerLogin()
    print("|cff00ff00" .. ADDON_NAME .. "|r Initializing...")
    
    if HowManyMobsDB.lastMobName and (not HowManyMobsDB.lastMobs or #HowManyMobsDB.lastMobs == 0) then
        HowManyMobsDB.lastMobs = {{name = HowManyMobsDB.lastMobName, level = HowManyMobsDB.lastMobLevel or UnitLevel("player"), time = GetTime()}}
        HowManyMobsDB.lastMobName = nil
        HowManyMobsDB.lastMobLevel = nil
    end
    
    local success, err = pcall(function() self:CreateUI() end)
    if not success then
        print("|cffff0000HowManyMobs Error creating UI:|r " .. tostring(err))
        return
    end
    
    self:RegisterSettingsPanel()
    
    print("|cff00ff00" .. ADDON_NAME .. "|r loaded successfully!")
    print("Type |cffffff00/hmm help|r to see all commands")
    print("Settings available at: |cffffff00Options > AddOns > How Many Mobs|r")
    
    if HowManyMobsDB.lastMobs and #HowManyMobsDB.lastMobs > 0 then
        self:UpdateMobCount()
    end
end

function HowManyMobs:OnPlayerEnteringWorld()
    C_Timer.After(2, function()
        self:CreateMinimapButton()
    end)
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
    end
end

HowManyMobs:SetScript("OnEvent", HowManyMobs.OnEvent)

-- ============================================
-- IMPROVED HELP SYSTEM (#5)
-- ============================================

function HowManyMobs:PrintHelp()
    print("|cff00ff00========== HowManyMobs Help =========|r")
    print(" ")
    print("|cffff00ffUI COMMANDS:|r")
    print("|cffffff00  /hmm show, /hmm info|r - Show the tracking window")
    print("|cffffff00  /hmm hide|r - Hide the tracking window")
    print("|cffffff00  /hmm button|r - Show the minimap button")
    print(" ")
    print("|cffff00ffTRACKING COMMANDS:|r")
    print("|cffffff00  /hmm toggle|r - Toggle tracking on/off")
    print("|cffffff00  /hmm reset|r - Clear all tracking data")
    print(" ")
    print("|cffff00ffUI CUSTOMIZATION:|r")
    print("|cffffff00  /hmm lock|r - Lock the window to prevent dragging")
    print("|cffffff00  /hmm unlock|r - Unlock the window")
    print("|cffffff00  /hmm scale <0.5-2.0>|r - Set UI scale")
    print("|cffffff00  /hmm opacity <0-1>|r - Set background opacity")
    print(" ")
    print("|cffff00ffDEBUG:|r")
    print("|cffffff00  /hmm debug|r - Toggle debug logging")
    print(" ")
    print("|cffff00ffFEATURES:|r")
    print("- Tracks mobs killed and calculates kills to next level")
    print("- Color-coded kill efficiency (green=80%+, yellow=50%+, orange, red=0%)")
    print("- Session statistics (XP/hr, kills/hr)")
    print("- Estimated time to level")
    print("|cff00ff00=========================================|r")
end

-- Slash commands
SLASH_HOWMANYMOBS1 = "/hmm"
SLASH_HOWMANYMOBS2 = "/howmanymobs"

SlashCmdList["HOWMANYMOBS"] = function(msg)
    local cmd, arg = msg:match("^(%S*)%s*(.*)")
    cmd = cmd:lower()
    if cmd == "show" or cmd == "info" or cmd == "" then
        if HowManyMobs.UIFrame then
            HowManyMobs.UIFrame:Show()
        else
            HowManyMobs:CreateUI()
        end
        if HowManyMobsDB.lastMobs and #HowManyMobsDB.lastMobs > 0 then
            HowManyMobs:UpdateMobCount()
        end
    elseif cmd == "hide" then
        if HowManyMobs.UIFrame then HowManyMobs.UIFrame:Hide() end
        print("|cff00ff00HowManyMobs:|r UI hidden.")
    elseif cmd == "button" then
        if HowManyMobs.MinimapButton then
            HowManyMobs.MinimapButton:Show()
            HowManyMobs.MinimapButton:Raise()
            print("|cff00ff00HowManyMobs:|r Minimap button forced visible")
        else
            HowManyMobs:CreateMinimapButton()
        end
    elseif cmd == "help" then
        HowManyMobs:PrintHelp()
    elseif cmd == "reset" then
        HowManyMobsDB.lastMobs = {}
        print("|cff00ff00HowManyMobs:|r Tracking reset.")
        if HowManyMobs.mobsNeededText then
            HowManyMobs.mobsNeededText:SetText("")
            HowManyMobs:UpdateLastKilledText()
            HowManyMobs:UpdateEstimatedTimeText()
            HowManyMobs:UpdateUILayout()
        end
    elseif cmd == "toggle" then
        HowManyMobsDB.trackingEnabled = not HowManyMobsDB.trackingEnabled
        print("|cff00ff00HowManyMobs:|r Tracking " .. (HowManyMobsDB.trackingEnabled and "enabled" or "disabled"))
    elseif cmd == "lock" then
        HowManyMobsDB.uiLocked = true
        print("|cff00ff00HowManyMobs:|r Frame is now |cffffff00locked|r (no dragging)")
    elseif cmd == "unlock" then
        HowManyMobsDB.uiLocked = false
        print("|cff00ff00HowManyMobs:|r Frame is now |cffffff00unlocked|r")
    elseif cmd == "scale" then
        local scale = tonumber(arg)
        if scale and scale >= 0.5 and scale <= 2.0 then
            HowManyMobsDB.uiScale = scale
            HowManyMobs:ApplyUISettings()
            print("|cff00ff00HowManyMobs:|r UI scale set to " .. string.format("%.1f", scale))
        else
            print("|cffff0000Invalid scale! Use /hmm scale <0.5-2.0>|r")
        end
    elseif cmd == "opacity" then
        local opacity = tonumber(arg)
        if opacity and opacity >= 0 and opacity <= 1 then
            HowManyMobsDB.uiOpacity = opacity
            HowManyMobs:ApplyBoxOpacity()
            print("|cff00ff00HowManyMobs:|r Box opacity set to " .. string.format("%d%%", opacity * 100))
        else
            print("|cffff0000Invalid opacity! Use /hmm opacity <0-1>|r")
        end
    elseif cmd == "debug" then
        HowManyMobs.debugMode = not HowManyMobs.debugMode
        print("|cff00ff00HowManyMobs:|r Debug mode " .. (HowManyMobs.debugMode and "|cff00ff00enabled|r" or "|cffff0000disabled|r"))
    else
        HowManyMobs:PrintHelp()
    end
end

-- Settings panel (unchanged)
function HowManyMobs:CreateSettingsPanel()
    local panel = CreateFrame("Frame", "HowManyMobsSettingsPanel")
    panel.name = "How Many Mobs"
    
    -- Helper function to add tooltips (#7 - Tooltips in Settings)
    local function AddTooltip(element, text)
        element:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:AddLine(text, 1, 1, 1, true)
            GameTooltip:Show()
        end)
        element:SetScript("OnLeave", function(self)
            GameTooltip:Hide()
        end)
    end
    
    local title = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", 16, -16)
    title:SetText("How Many Mobs Settings")
    
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
    lockCheck.text:SetText("Lock Frame Position (prevents accidental dragging)")
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
    
    local showTimeCheck = CreateFrame("CheckButton", "HowManyMobsShowTimeCheck", panel, "UICheckButtonTemplate")
    showTimeCheck:SetPoint("TOPLEFT", 16, -280)
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
    AddTooltip(showEfficiencyCheck, "Color-coded efficiency rating (green=80%+, yellow=50%+)")

    local showSessionCheck = CreateFrame("CheckButton", "HowManyMobsShowSessionCheck", panel, "UICheckButtonTemplate")
    showSessionCheck:SetPoint("TOPLEFT", 16, -340)
    
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
    resetBtn:SetPoint("TOPLEFT", 16, -340)
    resetBtn:SetSize(120, 25)
    resetBtn:SetText("Reset Defaults")
    resetBtn:SetScript("OnClick", function()
        HowManyMobsDB.uiScale = 1.0
        HowManyMobsDB.uiOpacity = 0.85
        HowManyMobsDB.uiLocked = false
        HowManyMobsDB.showLastKilled = true
        HowManyMobsDB.showMobLevel = true
        HowManyMobsDB.showEstimatedTime = false
        HowManyMobsDB.showEfficiency = true
        HowManyMobsDB.lastMobs = {}
        HowManyMobsDB.showSessionStats = true
        scaleSlider:SetValue(1.0)
        opacitySlider:SetValue(0.85)
        lockCheck:SetChecked(false)
        showLastCheck:SetChecked(true)
        showLevelCheck:SetChecked(true)
        showTimeCheck:SetChecked(false)
        showEfficiencyCheck:SetChecked(true)
        showSessionCheck:SetChecked(true)
        HowManyMobs:ApplyUISettings()
        HowManyMobs:UpdateUILayout()
        HowManyMobs:UpdateLastKilledText()
        HowManyMobs:UpdateEstimatedTimeText()
        HowManyMobs:UpdateEfficiencyText()
    end)
    AddTooltip(resetBtn, "Reset all settings to their default values")
    
    local sessionStatsLabel = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    sessionStatsLabel:SetPoint("TOPLEFT", 16, -370)
    sessionStatsLabel:SetText("|cff00ff00Current Session:|r")
    
    local sessionStatsDisplay = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    sessionStatsDisplay:SetPoint("TOPLEFT", 16, -385)
    sessionStatsDisplay:SetWidth(300)
    sessionStatsDisplay:SetJustifyH("LEFT")
    
    local helpText = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    helpText:SetPoint("TOPLEFT", 16, -410)
    helpText:SetWidth(300)
    helpText:SetJustifyH("LEFT")
    helpText:SetText("Quick commands: /hmm show | hide | toggle | reset")
    
    local infoText = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    infoText:SetPoint("TOPLEFT", 16, -430)
    infoText:SetWidth(300)
    infoText:SetJustifyH("LEFT")
    infoText:SetText("Type |cffffff00/hmm help|r for all available commands")
    
    return panel
end

function HowManyMobs:RegisterSettingsPanel()
    local panel = self:CreateSettingsPanel()
    if not panel then return end
    if Settings and Settings.RegisterCanvasLayoutCategory then
        local category = Settings.RegisterCanvasLayoutCategory(panel, panel.name)
        Settings.RegisterAddOnCategory(category)
    elseif InterfaceOptions_AddCategory then
        InterfaceOptions_AddCategory(panel)
    end
end

print("|cff00ff00HowManyMobs|r addon initialized. Use |cffffff00/hmm help|r for all commands.")