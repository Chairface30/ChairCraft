-- ChairPlus Camera.lua
-- Max camera zoom.
--
-- One CVar. The factor multiplies the client's base zoom limit, and 2.6 is the
-- ceiling this generation of client accepts -- a larger number is not clamped,
-- it is rejected, and the CVar keeps its old value. Turning the option off puts
-- the stock 1.9 back rather than leaving the setting behind, because a camera
-- that never returns is the kind of change people blame on the wrong addon.

local suiteName, Chaircraft = ...
-- Merged into Chaircraft. See the note in ChairSnack/Core.lua.
local addonName = "ChairPlus"
local ns = Chaircraft.ChairPlus

local MAX_FACTOR = 2.6
local DEFAULT_FACTOR = 1.9

ns.RegisterModule("maxCameraZoom", {
    title = "Max camera zoom",
    desc = "Zoom the camera out further than the client normally allows.",
    Apply = function(enabled)
        local setCVar = _G.SetCVar or (_G.C_CVar and _G.C_CVar.SetCVar)
        if type(setCVar) ~= "function" then return end
        pcall(setCVar, "cameraDistanceMaxZoomFactor",
            enabled and MAX_FACTOR or DEFAULT_FACTOR)
    end,
})
