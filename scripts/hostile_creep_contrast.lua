local Contrast = {}

local TARGET_RATIO = 3.5
local DETAIL_FLOOR = 0.86
local DETAIL_CEILING = 1.12
local CORE_ALPHA = 0.9
local HUE_SHIFTS = { 0, -4 / 360, 4 / 360, -8 / 360, 8 / 360 }
local NEUTRAL_HUE = { 0 }
local NEUTRAL_SATURATION = { 1 }
local SATURATION_STEPS = { 1, 0.80, 0.62 }

local function Linear(value)
    if value <= 0.04045 then
        return value / 12.92
    end
    return ((value + 0.055) / 1.055) ^ 2.4
end

local function Luminance(red, green, blue)
    return 0.2126 * Linear(red) + 0.7152 * Linear(green) + 0.0722 * Linear(blue)
end

function Contrast.Decode(rgb, exposure)
    local red = ((rgb >> 16) & 255) / 255 * exposure[1]
    local green = ((rgb >> 8) & 255) / 255 * exposure[2]
    local blue = (rgb & 255) / 255 * exposure[3]
    return { red, green, blue, Luminance(red, green, blue) }
end

local function HslChannel(hue, chroma, lightness, offset)
    local k = (offset + hue * 12) % 12
    return lightness - chroma * math.max(-1, math.min(k - 3, 9 - k, 1))
end

local function Hsl(hue, saturation, lightness)
    local chroma = saturation * math.min(lightness, 1 - lightness)
    return HslChannel(hue, chroma, lightness, 0), HslChannel(hue, chroma, lightness, 8),
        HslChannel(hue, chroma, lightness, 4)
end

local function DetailCeiling(red, green, blue)
    return math.min(DETAIL_CEILING, 1 / math.max(red, green, blue))
end

local function ContrastAt(hue, saturation, lightness, sample, lighter)
    local red, green, blue = Hsl(hue, saturation, lightness)
    local detail = lighter and DETAIL_FLOOR or DetailCeiling(red, green, blue)
    local worst = math.huge
    local source = sample.alpha * detail
    local background = 1 - sample.alpha
    local exposure = sample.exposure
    for _, floor in ipairs(sample.backgrounds) do
        local result = Luminance(red * source * exposure[1] + floor[1] * background,
            green * source * exposure[2] + floor[2] * background,
            blue * source * exposure[3] + floor[3] * background)
        local ratio = lighter and (result + 0.05) / (floor[4] + 0.05)
            or (floor[4] + 0.05) / (result + 0.05)
        worst = math.min(worst, ratio)
    end
    return worst
end

local function ClosestLightness(hue, saturation, nativeLightness, sample, lighter)
    if ContrastAt(hue, saturation, nativeLightness, sample, lighter) >= TARGET_RATIO then
        return nativeLightness
    end
    local passing = lighter and 0.95 or 0.025
    if ContrastAt(hue, saturation, passing, sample, lighter) < TARGET_RATIO then
        return nil
    end
    local failing = nativeLightness
    for _ = 1, 10 do
        local middle = (passing + failing) * 0.5
        if ContrastAt(hue, saturation, middle, sample, lighter) >= TARGET_RATIO then
            passing = middle
        else
            failing = middle
        end
    end
    return passing
end

local function ClosestColor(hue, saturation, lightness, sample)
    local bestHue, bestLightness, bestSaturation, bestCost = hue, nil, nil, math.huge
    for _, shift in ipairs(saturation == 0 and NEUTRAL_HUE or HUE_SHIFTS) do
        local candidateHue = (hue + shift) % 1
        for _, scale in ipairs(saturation == 0 and NEUTRAL_SATURATION or SATURATION_STEPS) do
            local candidateSaturation = saturation * scale
            for _, lighter in ipairs({ false, true }) do
                local candidateLightness = ClosestLightness(candidateHue, candidateSaturation, lightness, sample, lighter)
                if candidateLightness then
                    local cost = math.abs(candidateLightness - lightness) + 0.16 * (saturation - candidateSaturation)
                        + 0.9 * math.abs(shift)
                    if cost < bestCost then
                        bestHue, bestLightness, bestSaturation, bestCost = candidateHue, candidateLightness,
                            candidateSaturation, cost
                    end
                end
            end
        end
    end
    return bestHue, bestLightness, bestSaturation
end

function Contrast.Choose(profile, backgrounds, exposure)
    local hue, saturation, lightness = profile[1], profile[2], profile[3]
    local sample = { backgrounds = backgrounds, exposure = exposure, alpha = profile[4] or CORE_ALPHA }
    local selectedHue, selectedLightness, selectedSaturation = ClosestColor(hue, saturation, lightness, sample)
    if not selectedLightness then
        sample.backgrounds = { backgrounds[2] }
        selectedHue, selectedLightness, selectedSaturation = ClosestColor(hue, saturation, lightness, sample)
        if not selectedLightness then
            local dark = ContrastAt(hue, saturation, 0.025, sample, false)
            local light = ContrastAt(hue, saturation, 0.95, sample, true)
            selectedLightness, selectedSaturation = light > dark and 0.95 or 0.025, saturation
        end
    end

    local red, green, blue = Hsl(selectedHue, selectedSaturation, selectedLightness)
    local spread = DetailCeiling(red, green, blue) - DETAIL_FLOOR
    -- coloroffset.fs adds the offset at the source alpha and adds the gray
    -- texture signal through Colorize. Both terms use the selected hue.
    return {
        ro = red * DETAIL_FLOOR, go = green * DETAIL_FLOOR, bo = blue * DETAIL_FLOOR,
        cr = red * spread, cg = green * spread, cb = blue * spread,
    }
end

return Contrast
