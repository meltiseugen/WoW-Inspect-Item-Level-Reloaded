local addonName = ...
local frame = CreateFrame("Frame")

local DB_NAME = "InspectItemLevelReloadedDB"

local DEFAULTS = {
    colorInspectText = true,
    showLowItemLevelIcons = true,
    reallyLowItemDelta = 10,
    iconAnchor = "TOPRIGHT",
}

local SLOT_IDS = {
    INVSLOT_HEAD,
    INVSLOT_NECK,
    INVSLOT_SHOULDER,
    INVSLOT_BACK,
    INVSLOT_CHEST,
    INVSLOT_WRIST,
    INVSLOT_HAND,
    INVSLOT_WAIST,
    INVSLOT_LEGS,
    INVSLOT_FEET,
    INVSLOT_FINGER1,
    INVSLOT_FINGER2,
    INVSLOT_TRINKET1,
    INVSLOT_TRINKET2,
    INVSLOT_MAINHAND,
    INVSLOT_OFFHAND,
}

local SLOT_BUTTON_SUFFIXES = {
    [INVSLOT_HEAD] = "HeadSlot",
    [INVSLOT_NECK] = "NeckSlot",
    [INVSLOT_SHOULDER] = "ShoulderSlot",
    [INVSLOT_BACK] = "BackSlot",
    [INVSLOT_CHEST] = "ChestSlot",
    [INVSLOT_WRIST] = "WristSlot",
    [INVSLOT_HAND] = "HandsSlot",
    [INVSLOT_WAIST] = "WaistSlot",
    [INVSLOT_LEGS] = "LegsSlot",
    [INVSLOT_FEET] = "FeetSlot",
    [INVSLOT_FINGER1] = "Finger0Slot",
    [INVSLOT_FINGER2] = "Finger1Slot",
    [INVSLOT_TRINKET1] = "Trinket0Slot",
    [INVSLOT_TRINKET2] = "Trinket1Slot",
    [INVSLOT_MAINHAND] = "MainHandSlot",
    [INVSLOT_OFFHAND] = "SecondaryHandSlot",
}

local CHARACTER_SLOT_BUTTONS = {}
local INSPECT_SLOT_BUTTONS = {}
for slotID, suffix in pairs(SLOT_BUTTON_SUFFIXES) do
    CHARACTER_SLOT_BUTTONS[slotID] = "Character" .. suffix
    INSPECT_SLOT_BUTTONS[slotID] = "Inspect" .. suffix
end

local ITEM_LEVEL_PATTERN = ITEM_LEVEL:gsub("%%d", "(%%d+)")
local ITEM_LEVEL_LINE_TYPE = Enum.TooltipDataLineType.ItemLevel
local DEFAULT_QUALITY = Enum.ItemQuality.Common

local RETRY_ATTEMPTS = 6
local RETRY_INTERVAL = 0.2

local LOW_ICON_SIZE = 10
local RED_ICON_COLOR = {0.95, 0.15, 0.15, 0.95}
local YELLOW_ICON_COLOR = {1.0, 0.85, 0.2, 0.95}

local ICON_ANCHORS = {
    { key = "TOPRIGHT", label = "Top Right" },
    { key = "TOPLEFT", label = "Top Left" },
    { key = "BOTTOMRIGHT", label = "Bottom Right" },
    { key = "BOTTOMLEFT", label = "Bottom Left" },
}

local ICON_ANCHOR_OFFSETS = {
    TOPRIGHT = { -1, -1 },
    TOPLEFT = { 1, -1 },
    BOTTOMRIGHT = { -1, 1 },
    BOTTOMLEFT = { 1, 1 },
}

local label
local retryTicker
local retriesRemaining = 0
local inspectHooksInstalled = false
local characterHooksInstalled = false
local characterFrameHooksInstalled = false
local characterSlotUpdateHookInstalled = false
local characterStatsHookInstalled = false
local characterItemsHookInstalled = false
local optionsPanelCreated = false
local db
local characterButtonsBySlot = {}
local inspectButtonsBySlot = {}

local function IsInspectUILoaded()
    return C_AddOns.IsAddOnLoaded("Blizzard_InspectUI")
end

local function InitializeDB()
    if type(_G[DB_NAME]) ~= "table" then
        _G[DB_NAME] = {}
    end

    db = _G[DB_NAME]
    for key, value in pairs(DEFAULTS) do
        if db[key] == nil then
            db[key] = value
        end
    end
end

local function EnsureLabel()
    if label or not InspectFrame then
        return
    end

    label = InspectFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    label:SetPoint("TOPRIGHT", InspectFrame, "TOPRIGHT", -10, -45)
    label:SetJustifyH("RIGHT")
    label:SetText("")
end

local function StopRetries()
    if retryTicker then
        retryTicker:Cancel()
        retryTicker = nil
    end
    retriesRemaining = 0
end

local function ResolveSlotButton(slotButtonNames, slotButtonsBySlot, slotID)
    local button = slotButtonsBySlot[slotID] or _G[slotButtonNames[slotID]]
    if button and button.GetID and button:GetID() ~= slotID then
        return nil
    end
    return button
end

local function SeedSlotButtons(slotButtonNames, slotButtonsBySlot)
    for _, slotID in ipairs(SLOT_IDS) do
        local namedButton = _G[slotButtonNames[slotID]]
        if namedButton then
            slotButtonsBySlot[slotID] = namedButton
        end
    end
end

local function RegisterSlotButton(slotButtonsBySlot, button)
    if not (button and button.GetID) then
        return
    end

    local slotID = button:GetID()
    if slotID and slotID >= INVSLOT_FIRST_EQUIPPED and slotID <= INVSLOT_LAST_EQUIPPED then
        slotButtonsBySlot[slotID] = button
    end
end

local function GetIndicatorAnchor()
    local anchor = (db and db.iconAnchor) or DEFAULTS.iconAnchor
    if ICON_ANCHOR_OFFSETS[anchor] then
        return anchor
    end
    return DEFAULTS.iconAnchor
end

local function IsCharacterSheetVisible()
    if CharacterFrame and CharacterFrame:IsShown() then
        return true
    end
    if PaperDollFrame and PaperDollFrame:IsShown() then
        return true
    end
    if PaperDollFrame and PaperDollFrame.GetParent then
        local parent = PaperDollFrame:GetParent()
        if parent and parent:IsShown() then
            return true
        end
    end
    return false
end


local function CollectSlotButtonsFromFrame(root, slotButtonsBySlot)
    if not (root and root.GetChildren) then
        return
    end

    for _, child in ipairs({ root:GetChildren() }) do
        if child and child.GetID then
            local slotID = child:GetID()
            if slotID and slotID >= INVSLOT_FIRST_EQUIPPED and slotID <= INVSLOT_LAST_EQUIPPED then
                slotButtonsBySlot[slotID] = child
            end
        end
        CollectSlotButtonsFromFrame(child, slotButtonsBySlot)
    end
end

local function SeedSlotButtonsByNamePattern(slotButtonsBySlot)
    local frame = EnumerateFrames()
    while frame do
        if frame.GetName and frame.GetID then
            local name = frame:GetName()
            if name and name:match("^Character.+Slot$") then
                local slotID = frame:GetID()
                if slotID and slotID >= INVSLOT_FIRST_EQUIPPED and slotID <= INVSLOT_LAST_EQUIPPED then
                    slotButtonsBySlot[slotID] = frame
                end
            end
        end
        frame = EnumerateFrames(frame)
    end
end

local function PositionIndicator(button, indicator)
    local anchor = GetIndicatorAnchor()
    local offsets = ICON_ANCHOR_OFFSETS[anchor]
    indicator:ClearAllPoints()
    indicator:SetPoint(anchor, button, anchor, offsets[1], offsets[2])
end

local function EnsureSlotIndicator(button)
    if button.iirlLowItemLevelIndicator then
        PositionIndicator(button, button.iirlLowItemLevelIndicator)
        return button.iirlLowItemLevelIndicator
    end

    local holder = CreateFrame("Frame", nil, button)
    holder:SetAllPoints(button)
    holder:SetFrameLevel((button:GetFrameLevel() or 0) + 5)

    local indicator = holder:CreateTexture(nil, "OVERLAY", nil, 7)
    indicator:SetSize(LOW_ICON_SIZE, LOW_ICON_SIZE)
    indicator:SetColorTexture(RED_ICON_COLOR[1], RED_ICON_COLOR[2], RED_ICON_COLOR[3], RED_ICON_COLOR[4])
    PositionIndicator(button, indicator)
    indicator:Hide()

    button.iirlLowItemLevelIndicatorHolder = holder
    button.iirlLowItemLevelIndicator = indicator
    return indicator
end

local function HideSlotIndicators(slotButtonNames, slotButtonsBySlot)
    for _, slotID in ipairs(SLOT_IDS) do
        local button = ResolveSlotButton(slotButtonNames, slotButtonsBySlot, slotID)
        if button and button.iirlLowItemLevelIndicator then
            button.iirlLowItemLevelIndicator:Hide()
        end
    end
end

local function GetTooltipItemLevel(unit, slotID)
    local tooltipInfo = C_TooltipInfo.GetInventoryItem(unit, slotID)
    if not (tooltipInfo and tooltipInfo.lines) then
        return nil
    end

    for _, line in ipairs(tooltipInfo.lines) do
        local lineItemLevel = line["itemLevel"]
        if ITEM_LEVEL_LINE_TYPE and line.type == ITEM_LEVEL_LINE_TYPE and lineItemLevel then
            local typedLevel = tonumber(lineItemLevel)
            if typedLevel and typedLevel > 0 then
                return typedLevel
            end
        end

        local text = line.leftText
        if text then
            local parsedLevel = tonumber(text:match(ITEM_LEVEL_PATTERN))
            if parsedLevel and parsedLevel > 0 then
                return parsedLevel
            end
        end
    end

    return nil
end

local function GetLinkItemLevel(unit, slotID)
    local itemLink = GetInventoryItemLink(unit, slotID)
    if not itemLink then
        return nil
    end

    local level = C_Item.GetDetailedItemLevelInfo(itemLink)
    if level and level > 0 then
        return level
    end

    return nil
end

local function GetLinkItemQuality(unit, slotID)
    local itemLink = GetInventoryItemLink(unit, slotID)
    if not itemLink then
        return nil
    end
    return C_Item.GetItemQualityByID(itemLink)
end

local function CollectItemData(unit)
    local totalLevel = 0
    local countedItems = 0
    local qualityCounts = {}
    local slotItemLevels = {}

    for _, slotID in ipairs(SLOT_IDS) do
        local itemLevel = GetTooltipItemLevel(unit, slotID) or GetLinkItemLevel(unit, slotID)
        slotItemLevels[slotID] = itemLevel

        if itemLevel and itemLevel > 0 then
            totalLevel = totalLevel + itemLevel
            countedItems = countedItems + 1

            local quality = GetLinkItemQuality(unit, slotID)
            if quality then
                qualityCounts[quality] = (qualityCounts[quality] or 0) + 1
            end
        end
    end

    if countedItems == 0 then
        return nil, 0, DEFAULT_QUALITY, slotItemLevels
    end

    local dominantQuality = DEFAULT_QUALITY
    local dominantCount = 0
    for quality, count in pairs(qualityCounts) do
        if count > dominantCount or (count == dominantCount and quality > dominantQuality) then
            dominantQuality = quality
            dominantCount = count
        end
    end

    return totalLevel / countedItems, countedItems, dominantQuality, slotItemLevels
end

local function UpdateSlotIndicators(slotButtonNames, slotButtonsBySlot, averageItemLevel, slotItemLevels)
    if not (db and db.showLowItemLevelIcons) or not averageItemLevel then
        HideSlotIndicators(slotButtonNames, slotButtonsBySlot)
        return
    end

    local reallyLowItemDelta = tonumber(db and db.reallyLowItemDelta) or DEFAULTS.reallyLowItemDelta
    reallyLowItemDelta = math.max(1, math.floor(reallyLowItemDelta + 0.5))

    for _, slotID in ipairs(SLOT_IDS) do
        local button = ResolveSlotButton(slotButtonNames, slotButtonsBySlot, slotID)
        if button then
            local indicator = EnsureSlotIndicator(button)
            local itemLevel = slotItemLevels[slotID]

            if itemLevel and itemLevel > 0 then
                local delta = averageItemLevel - itemLevel
                if delta >= reallyLowItemDelta then
                    indicator:SetColorTexture(RED_ICON_COLOR[1], RED_ICON_COLOR[2], RED_ICON_COLOR[3], RED_ICON_COLOR[4])
                    indicator:Show()
                elseif delta > 0 then
                    indicator:SetColorTexture(YELLOW_ICON_COLOR[1], YELLOW_ICON_COLOR[2], YELLOW_ICON_COLOR[3], YELLOW_ICON_COLOR[4])
                    indicator:Show()
                else
                    indicator:Hide()
                end
            else
                indicator:Hide()
            end
        end
    end
end

local function UpdateInspectLabel()
    if not (InspectFrame and InspectFrame:IsShown() and InspectFrame.unit) then
        if label then
            label:SetText("")
        end
        HideSlotIndicators(INSPECT_SLOT_BUTTONS, inspectButtonsBySlot)
        return false
    end

    EnsureLabel()
    SeedSlotButtons(INSPECT_SLOT_BUTTONS, inspectButtonsBySlot)

    local averageItemLevel, countedItems, dominantQuality, slotItemLevels = CollectItemData(InspectFrame.unit)
    UpdateSlotIndicators(INSPECT_SLOT_BUTTONS, inspectButtonsBySlot, averageItemLevel, slotItemLevels)

    if averageItemLevel then
        if db and db.colorInspectText then
            local r, g, b = C_Item.GetItemQualityColor(dominantQuality)
            label:SetTextColor(r, g, b)
        else
            label:SetTextColor(1, 1, 1)
        end
        label:SetFormattedText("iLvl: %.1f", averageItemLevel)
        return countedItems >= 15
    end

    if db and db.colorInspectText then
        local r, g, b = C_Item.GetItemQualityColor(DEFAULT_QUALITY)
        label:SetTextColor(r, g, b)
    else
        label:SetTextColor(1, 1, 1)
    end
    label:SetText("iLvl: ...")
    return false
end

local function RefreshInspectItemLevel()
    StopRetries()
    if not InspectFrame then
        return
    end

    EnsureLabel()
    UpdateInspectLabel()

    retriesRemaining = RETRY_ATTEMPTS
    retryTicker = C_Timer.NewTicker(RETRY_INTERVAL, function()
        retriesRemaining = retriesRemaining - 1
        local isStable = UpdateInspectLabel()
        if isStable or retriesRemaining <= 0 then
            StopRetries()
        end
    end)
end

local function RefreshCharacterIndicators(force)
    if not force and not IsCharacterSheetVisible() then
        HideSlotIndicators(CHARACTER_SLOT_BUTTONS, characterButtonsBySlot)
        return
    end

    SeedSlotButtons(CHARACTER_SLOT_BUTTONS, characterButtonsBySlot)
    if not next(characterButtonsBySlot) then
        CollectSlotButtonsFromFrame(PaperDollFrame or CharacterFrame, characterButtonsBySlot)
    end
    if not next(characterButtonsBySlot) then
        SeedSlotButtonsByNamePattern(characterButtonsBySlot)
    end

    local averageItemLevel, _, _, slotItemLevels = CollectItemData("player")
    UpdateSlotIndicators(CHARACTER_SLOT_BUTTONS, characterButtonsBySlot, averageItemLevel, slotItemLevels)
end

local function CreateOptionsPanel()
    if optionsPanelCreated or not Settings or not Settings.RegisterCanvasLayoutCategory then
        return
    end
    optionsPanelCreated = true

    local panel = CreateFrame("Frame")

    local title = panel:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", 16, -16)
    title:SetText("Inspect Item Level Reloaded")

    local subtitle = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    subtitle:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -8)
    subtitle:SetText("Inspect/character iLvl display options.")

    local colorTextCheckbox = CreateFrame("CheckButton", addonName .. "ColorTextCheckbox", panel, "InterfaceOptionsCheckButtonTemplate")
    colorTextCheckbox:SetPoint("TOPLEFT", subtitle, "BOTTOMLEFT", -2, -12)
    colorTextCheckbox.Text:SetText("Color average item level text")
    colorTextCheckbox.tooltipText = "If disabled, the iLvl text is always white."

    local lowItemIconsCheckbox = CreateFrame("CheckButton", addonName .. "LowItemIconsCheckbox", panel, "InterfaceOptionsCheckButtonTemplate")
    lowItemIconsCheckbox:SetPoint("TOPLEFT", colorTextCheckbox, "BOTTOMLEFT", 0, -8)
    lowItemIconsCheckbox.Text:SetText("Show low item-level icons (inspect + character)")
    lowItemIconsCheckbox.tooltipText = "Red: configured threshold iLvl below average. Yellow: below average."

    local iconPositionLabel = panel:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    iconPositionLabel:SetPoint("TOPLEFT", lowItemIconsCheckbox, "BOTTOMLEFT", -2, -14)
    iconPositionLabel:SetText("Icon position")

    local anchorCheckboxes = {}
    local thresholdSlider
    local thresholdValueLabel
    local function SyncAnchorCheckboxes()
        local selectedAnchor = (db and db.iconAnchor) or DEFAULTS.iconAnchor
        if not ICON_ANCHOR_OFFSETS[selectedAnchor] then
            selectedAnchor = DEFAULTS.iconAnchor
        end
        db.iconAnchor = selectedAnchor
        for _, checkbox in ipairs(anchorCheckboxes) do
            checkbox:SetChecked(checkbox.iirlAnchorKey == selectedAnchor)
        end
    end

    colorTextCheckbox:SetScript("OnClick", function(self)
        db.colorInspectText = self:GetChecked() and true or false
        RefreshInspectItemLevel()
    end)

    lowItemIconsCheckbox:SetScript("OnClick", function(self)
        db.showLowItemLevelIcons = self:GetChecked() and true or false
        RefreshInspectItemLevel()
        RefreshCharacterIndicators()
    end)

    for index, anchor in ipairs(ICON_ANCHORS) do
        local checkbox = CreateFrame("CheckButton", addonName .. "IconAnchor" .. anchor.key, panel, "InterfaceOptionsCheckButtonTemplate")
        checkbox.iirlAnchorKey = anchor.key
        checkbox.Text:SetText(anchor.label)

        local col = 1 - ((index - 1) % 2)
        local row = math.floor((index - 1) / 2)
        checkbox:SetPoint("TOPLEFT", iconPositionLabel, "BOTTOMLEFT", (col * 130) - 2, -6 - (row * 24))

        checkbox:SetScript("OnClick", function(self)
            if self:GetChecked() then
                db.iconAnchor = self.iirlAnchorKey
                SyncAnchorCheckboxes()
                RefreshInspectItemLevel()
                RefreshCharacterIndicators()
            else
                self:SetChecked(true)
            end
        end)

        table.insert(anchorCheckboxes, checkbox)
    end

    thresholdSlider = CreateFrame("Slider", addonName .. "RedThresholdSlider", panel, "OptionsSliderTemplate")
    thresholdSlider:SetWidth(200)
    thresholdSlider:SetPoint("TOPLEFT", iconPositionLabel, "BOTTOMLEFT", 4, -78)
    thresholdSlider:SetMinMaxValues(1, 50)
    thresholdSlider:SetValueStep(1)
    thresholdSlider:SetObeyStepOnDrag(true)
    local thresholdSliderLow = _G[thresholdSlider:GetName() .. "Low"]
    local thresholdSliderHigh = _G[thresholdSlider:GetName() .. "High"]
    local thresholdSliderText = _G[thresholdSlider:GetName() .. "Text"]
    if thresholdSliderLow then
        thresholdSliderLow:SetText("1")
    end
    if thresholdSliderHigh then
        thresholdSliderHigh:SetText("50")
    end
    if thresholdSliderText then
        thresholdSliderText:SetText("Red threshold (iLvl below average)")
    end

    thresholdValueLabel = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    thresholdValueLabel:SetPoint("LEFT", thresholdSlider, "RIGHT", 8, 0)
    thresholdValueLabel:SetText("")

    thresholdSlider:SetScript("OnValueChanged", function(self, value)
        local roundedValue = math.floor(value + 0.5)
        thresholdValueLabel:SetFormattedText("%d", roundedValue)
        db.reallyLowItemDelta = roundedValue
        RefreshInspectItemLevel()
        RefreshCharacterIndicators()
    end)

    panel:SetScript("OnShow", function()
        colorTextCheckbox:SetChecked(db.colorInspectText)
        lowItemIconsCheckbox:SetChecked(db.showLowItemLevelIcons)
        local threshold = tonumber(db.reallyLowItemDelta) or DEFAULTS.reallyLowItemDelta
        threshold = math.max(1, math.min(50, math.floor(threshold + 0.5)))
        if thresholdSlider then
            thresholdSlider:SetValue(threshold)
        end
        SyncAnchorCheckboxes()
    end)

    local category = Settings.RegisterCanvasLayoutCategory(panel, "Inspect Item Level Reloaded")
    Settings.RegisterAddOnCategory(category)
end

local function InstallInspectHooks()
    if inspectHooksInstalled or not InspectFrame then
        return
    end
    inspectHooksInstalled = true

    EnsureLabel()

    InspectFrame:HookScript("OnShow", RefreshInspectItemLevel)
    InspectFrame:HookScript("OnHide", function()
        StopRetries()
        if label then
            label:SetText("")
        end
        HideSlotIndicators(INSPECT_SLOT_BUTTONS, inspectButtonsBySlot)
    end)

    if InspectPaperDollItemSlotButton_Update then
        hooksecurefunc("InspectPaperDollItemSlotButton_Update", function(button)
            RegisterSlotButton(inspectButtonsBySlot, button)
            if InspectFrame and InspectFrame:IsShown() then
                UpdateInspectLabel()
            end
        end)
    end

    hooksecurefunc("InspectPaperDollFrame_UpdateButtons", function()
        if InspectFrame and InspectFrame:IsShown() then
            RefreshInspectItemLevel()
        end
    end)
end

local function InstallCharacterHooks()
    if not CharacterFrame and not PaperDollItemSlotButton_Update and not PaperDollFrame_UpdateStats then
        return
    end

    if not characterFrameHooksInstalled then
        if CharacterFrame then
            CharacterFrame:HookScript("OnShow", function()
                RefreshCharacterIndicators(true)
            end)
            CharacterFrame:HookScript("OnHide", function()
                HideSlotIndicators(CHARACTER_SLOT_BUTTONS, characterButtonsBySlot)
            end)
        end
        if PaperDollFrame then
            PaperDollFrame:HookScript("OnShow", function()
                RefreshCharacterIndicators(true)
            end)
            PaperDollFrame:HookScript("OnHide", function()
                HideSlotIndicators(CHARACTER_SLOT_BUTTONS, characterButtonsBySlot)
            end)
        end
        if CharacterFrame or PaperDollFrame then
            characterFrameHooksInstalled = true
        end
    end

    if PaperDollItemSlotButton_Update and not characterSlotUpdateHookInstalled then
        hooksecurefunc("PaperDollItemSlotButton_Update", function(button)
            RegisterSlotButton(characterButtonsBySlot, button)
            RefreshCharacterIndicators(true)
        end)
        characterSlotUpdateHookInstalled = true
    end

    if PaperDollFrame_UpdateStats and not characterStatsHookInstalled then
        hooksecurefunc("PaperDollFrame_UpdateStats", function()
            RefreshCharacterIndicators(true)
        end)
        characterStatsHookInstalled = true
    end

    if PaperDollFrame_UpdateItems and not characterItemsHookInstalled then
        hooksecurefunc("PaperDollFrame_UpdateItems", function()
            RefreshCharacterIndicators(true)
        end)
        characterItemsHookInstalled = true
    end

    if characterFrameHooksInstalled and (characterSlotUpdateHookInstalled or characterStatsHookInstalled) then
        characterHooksInstalled = true
    end
end

function frame:ADDON_LOADED(loadedAddon)
    if loadedAddon == addonName then
        InitializeDB()
        CreateOptionsPanel()
        InstallCharacterHooks()
        if IsInspectUILoaded() then 
            InstallInspectHooks()
        end
        C_Timer.After(0.2, RefreshCharacterIndicators)
    end

    if loadedAddon == "Blizzard_InspectUI" or (not inspectHooksInstalled and InspectFrame) then
        InstallInspectHooks()
    end

    if loadedAddon == "Blizzard_CharacterUI" or (not characterHooksInstalled and (CharacterFrame or PaperDollItemSlotButton_Update or PaperDollFrame_UpdateStats)) then
        InstallCharacterHooks()
        C_Timer.After(0.2, RefreshCharacterIndicators)
    end
end

function frame:INSPECT_READY(guid)
    if not (InspectFrame and InspectFrame:IsShown() and InspectFrame.unit) then
        return
    end
    if guid and UnitGUID(InspectFrame.unit) ~= guid then
        return
    end
    RefreshInspectItemLevel()
end

function frame:PLAYER_LOGIN()
    CreateOptionsPanel()
    if not C_AddOns.IsAddOnLoaded("Blizzard_CharacterUI") then
        C_AddOns.LoadAddOn("Blizzard_CharacterUI")
    end
    InstallCharacterHooks()
    C_Timer.After(2, InstallCharacterHooks)
    C_Timer.After(0.2, RefreshCharacterIndicators)
end

function frame:PLAYER_ENTERING_WORLD()
    RefreshCharacterIndicators(true)
end

function frame:PLAYER_EQUIPMENT_CHANGED()
    RefreshCharacterIndicators()
end

function frame:UNIT_INVENTORY_CHANGED(unit)
    if unit == "player" then
        RefreshCharacterIndicators()
    end
end

frame:SetScript("OnEvent", function(self, event, ...)
    if self[event] then
        self[event](self, ...)
    end
end)

frame:RegisterEvent("ADDON_LOADED")
frame:RegisterEvent("INSPECT_READY")
frame:RegisterEvent("PLAYER_LOGIN")
frame:RegisterEvent("PLAYER_ENTERING_WORLD")
frame:RegisterEvent("PLAYER_EQUIPMENT_CHANGED")
frame:RegisterEvent("UNIT_INVENTORY_CHANGED")
