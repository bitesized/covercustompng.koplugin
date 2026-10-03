--[[--
Cover with custom image: a sleep screen wallpaper mode that shows the current
book cover with a custom image drawn on top of it.

The mode is stored as the stock "cover" mode plus a flag of our own, so all of
the cover mode's behaviour (exclusions, fallbacks, fill, stretch and rotation)
is KOReader's own, and disabling the plugin simply leaves the book cover.

The overlay is added by wrapping `Screensaver:setup` and `Screensaver:show`.
`show` builds the cover with a single `ImageWidget:new` call; while it runs we
intercept that call and return the cover and the overlay stacked in an
`OverlapGroup`, so the sleep screen message is still drawn above both. The
overlay is built exactly as the "custom image" mode would build it, so it is
fitted to the screen, not to the cover.

@module koplugin.covercustompng
--]]--

local Device = require("device")
local DocumentRegistry = require("document/documentregistry")
local ImageWidget = require("ui/widget/imagewidget")
local OverlapGroup = require("ui/widget/overlapgroup")
local RenderImage = require("ui/renderimage")
local Screensaver = require("ui/screensaver")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local ffiUtil = require("ffi/util")
local filemanagerutil = require("apps/filemanager/filemanagerutil")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local util = require("util")
local _ = require("gettext")
local Screen = Device.screen

local ENABLED_SETTING = "covercustompng_enabled"
local FILE_SETTING = "covercustompng_file"

local function isModeSelected()
    return G_reader_settings:readSetting("screensaver_type") == "cover"
        and G_reader_settings:isTrue(ENABLED_SETTING)
end

local function getOverlayFile()
    local file = G_reader_settings:readSetting(FILE_SETTING)
    if file and lfs.attributes(file, "mode") == "file" then
        return file
    end
end

local function hasLastFile()
    local last_file = G_reader_settings:readSetting("lastfile")
    return last_file and lfs.attributes(last_file, "mode") == "file"
end

local function chooseOverlayFile(on_chosen)
    filemanagerutil.showChooseDialog(_("Current overlay image:"), function(path)
        G_reader_settings:saveSetting(FILE_SETTING, path)
        if on_chosen then on_chosen() end
    end, G_reader_settings:readSetting(FILE_SETTING), nil, function(filename)
        return not util.stringStartsWith(ffiUtil.basename(filename), "._") and DocumentRegistry:isImageFile(filename)
    end)
end

--- Builds the overlay the way `Screensaver:show` builds a custom image,
-- reusing the cover's box, fit and stretch settings.
local function buildOverlayWidget(cover_settings, file)
    local settings = {
        width = cover_settings.width,
        height = cover_settings.height,
        scale_factor = cover_settings.scale_factor,
        stretch_limit_percentage = cover_settings.stretch_limit_percentage,
        alpha = true,
    }
    if G_reader_settings:isTrue("screensaver_rotate_auto_for_best_fit") then
        if util.getFileNameSuffix(file) == "svg" then
            settings.image = RenderImage:renderSVGImageFile(file, nil, nil, 1)
        else
            settings.image = RenderImage:renderImageFile(file, false, nil, nil)
        end
        if not settings.image then
            logger.warn("CoverCustomPng: could not render overlay image", file)
            return
        end
        settings.image_disposable = true
        -- `show` has already switched to portrait by now; the original mode is the one it matches.
        local rotation_mode = Device.orig_rotation_mode or Screen:getRotationMode()
        local angle = rotation_mode == 3 and 180 or 0
        if (settings.image:getWidth() < settings.image:getHeight()) ~= (settings.width < settings.height) then
            angle = angle + (G_reader_settings:isTrue("imageviewer_rotation_landscape_invert") and -90 or 90)
        end
        settings.rotation_angle = angle
    else
        settings.file = file
        settings.file_do_cache = false
    end
    return ImageWidget:new(settings)
end

if not Screensaver._covercustompng_patched then
    Screensaver._covercustompng_patched = true

    local orig_setup = Screensaver.setup
    Screensaver.setup = function(self, event, event_message)
        orig_setup(self, event, event_message)
        self.covercustompng_file = nil
        -- Only when the cover is really going to be shown, i.e. no fallback kicked in.
        -- "document_cover" also ends up as "cover", so check what was actually configured.
        if not self.ui or self.screensaver_type ~= "cover" then return end
        local configured = G_reader_settings:readSetting(self.prefix .. "screensaver_type")
            or G_reader_settings:readSetting("screensaver_type")
        if configured == "cover" and G_reader_settings:isTrue(ENABLED_SETTING) then
            self.covercustompng_file = getOverlayFile()
        end
    end

    local orig_show = Screensaver.show
    Screensaver.show = function(self)
        local overlay_file = self.covercustompng_file
        if not overlay_file then
            return orig_show(self)
        end

        local own_new = rawget(ImageWidget, "new")
        local orig_new = ImageWidget.new
        local done = false
        ImageWidget.new = function(class, o)
            -- Skip subclasses (e.g. the message box's IconWidget) and anything after the cover.
            if class ~= ImageWidget or done then
                return orig_new(class, o)
            end
            done = true
            local cover_settings = o
            local cover = orig_new(class, o)
            local overlay = buildOverlayWidget(cover_settings, overlay_file)
            if not overlay then
                return cover
            end
            return OverlapGroup:new{
                dimen = { w = cover_settings.width, h = cover_settings.height },
                cover,
                overlay,
            }
        end
        local ok, err = pcall(orig_show, self)
        rawset(ImageWidget, "new", own_new)
        if not ok then
            error(err, 0)
        end
    end

    local orig_cleanup = Screensaver.cleanup
    Screensaver.cleanup = function(self)
        orig_cleanup(self)
        self.covercustompng_file = nil
    end
end

local CoverCustomPng = WidgetContainer:extend{
    name = "covercustompng",
    is_doc_only = false,
}

function CoverCustomPng:init()
    self.ui.menu:registerToMainMenu(self)
end

local function findItem(items, text)
    for i, item in ipairs(items) do
        if item.text == text then
            return item, i
        end
    end
end

function CoverCustomPng:addToMainMenu(menu_items)
    -- Built by frontend/ui/elements/screensaver_menu.lua just before plugins are asked for their items.
    local screensaver = menu_items.screensaver
    local wallpaper = screensaver and screensaver.sub_item_table
        and findItem(screensaver.sub_item_table, _("Wallpaper"))
    if not wallpaper or wallpaper.covercustompng_added then return end
    wallpaper.covercustompng_added = true
    local items = wallpaper.sub_item_table

    -- Picking any stock mode leaves ours.
    for _, item in ipairs(items) do
        if item.radio and item.callback then
            local orig_callback = item.callback
            item.callback = function(...)
                G_reader_settings:delSetting(ENABLED_SETTING)
                return orig_callback(...)
            end
        end
    end

    -- Both modes are saved as "cover", so the stock item must not look selected while ours is.
    local cover_item, cover_index = findItem(items, _("Show book cover on sleep screen"))
    if cover_item then
        local orig_checked_func = cover_item.checked_func
        cover_item.checked_func = function()
            return orig_checked_func() and not G_reader_settings:isTrue(ENABLED_SETTING)
        end
    end

    table.insert(items, (cover_index or 0) + 1, {
        text = _("Show book cover with custom image on sleep screen"),
        help_text = _("Shows the book cover, with the image chosen in 'Custom images' drawn on top of it. Use a PNG with transparency, sized to your screen."),
        enabled_func = hasLastFile,
        checked_func = isModeSelected,
        callback = function(touchmenu_instance)
            G_reader_settings:saveSetting("screensaver_type", "cover")
            G_reader_settings:makeTrue(ENABLED_SETTING)
            if not getOverlayFile() then
                chooseOverlayFile(function()
                    if touchmenu_instance then touchmenu_instance:updateItems() end
                end)
            end
        end,
        radio = true,
    })

    local choose_item = {
        text_func = function()
            local file = G_reader_settings:readSetting(FILE_SETTING)
            if file then
                return _("Choose overlay image") .. ": " .. ffiUtil.basename(file)
            end
            return _("Choose overlay image")
        end,
        enabled_func = isModeSelected,
        keep_menu_open = true,
        callback = function(touchmenu_instance)
            chooseOverlayFile(function()
                if touchmenu_instance then touchmenu_instance:updateItems() end
            end)
        end,
    }
    local custom_images = findItem(items, _("Custom images"))
    if custom_images then
        local orig_enabled_func = custom_images.enabled_func
        custom_images.enabled_func = function()
            return isModeSelected() or (orig_enabled_func == nil or orig_enabled_func())
        end
        table.insert(custom_images.sub_item_table, 2, choose_item)
    else
        table.insert(items, choose_item)
    end
end

return CoverCustomPng
