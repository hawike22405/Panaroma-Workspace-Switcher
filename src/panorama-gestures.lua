-- Live gesture bridge for the three-finger horizontal gesture
assert(hl and hl.gesture and hl.dsp and hl.dsp.event and hl.dsp.focus,
       "Panorama requires Hyprland's live Lua gesture API")

local distance = 300 -- keep in sync with Overlay.qml's gestureDistance
local threshold = distance * 0.20
local serial, total = 0, 0
local active = false

local function send(phase, cancelled)
    hl.dispatch(hl.dsp.event("panorama_v2," .. phase .. "," .. serial .. "," .. math.floor(total) .. "," .. (cancelled and "1" or "0")))
end

local action = {
    start = function(e)
        serial = serial + 1
        total = 0
        active = true
        send("start", false)
    end,
    update = function(e)
        if not active then return end
        local dx = (e.delta and tonumber(e.delta.x)) or (e.dx and tonumber(e.dx)) or 0
        total = total + dx
        -- Forward gesture movement immediately without dropping accumulated movement
        send("update", false)
    end,
    finish = function(e)
        if not active then return end
        active = false
        send("finish", e.cancelled or false)
        if not e.cancelled and math.abs(total) >= threshold then
            local ws = hl.get_active_workspace()
            local cur = (ws and ws.id and ws.id > 0) and ws.id or 1
            local target = total < 0 and (cur + 1) or math.max(1, cur - 1)
            hl.dispatch(hl.dsp.focus({ workspace = target }))
        end
    end,
}

hl.gesture({ fingers = 3, direction = "horizontal", action = "unset" })
local ok, err = pcall(function()
    hl.gesture({ fingers = 3, direction = "horizontal", action = action })
end)
if not ok then
    hl.gesture({ fingers = 3, direction = "horizontal", action = "workspace" })
    error("Panorama live gesture registration failed: " .. tostring(err))
end

for _, leaf in ipairs({ "workspaces", "workspacesIn", "workspacesOut" }) do
    hl.animation({ leaf = leaf, enabled = false })
end
hl.layer_rule({ name = "ryoku-panorama-no-layer-animation",
                match = { namespace = "^ryoku-panorama$" }, no_anim = true })

-- Autostart Panorama daemon if not already running
local panorama_bin = (os.getenv("HOME") or "") .. "/.local/bin/ryoku-panorama"
pcall(function()
    hl.on("hyprland.start", function()
        hl.exec_cmd(panorama_bin .. " start")
    end)
end)
pcall(function()
    hl.exec_cmd(panorama_bin .. " start")
end)
