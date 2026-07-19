local Loader = {}

local function script_directory()
    local ok, info = pcall(function()
        if type(debug) ~= "table" or type(debug.getinfo) ~= "function" then
            return nil
        end
        return debug.getinfo(1, "S")
    end)
    if not ok or not info or not info.source then return nil end

    local source = tostring(info.source)
    if source:sub(1, 1) == "@" then
        source = source:sub(2)
    end
    return source:match("^(.*[\\/])[^\\/]*$")
end

function Loader.load()
    if type(_G) == "table"
        and type(rawget(_G, "RequirePleasureLib")) == "function"
    then
        local lib = rawget(_G, "RequirePleasureLib")()
        if type(lib) == "table" then return lib end
    end

    if type(_G) == "table"
        and type(rawget(_G, "PleasureLib")) == "table"
    then
        return rawget(_G, "PleasureLib")
    end

    local ok, lib = pcall(require, "pleasure_lib")
    if ok and type(lib) == "table" then return lib end

    local dir = script_directory()
    if dir then
        ok, lib = pcall(dofile,
            dir .. "..\\..\\PleasureLib\\Scripts\\pleasure_lib.lua")
        if ok and type(lib) == "table" then return lib end
    end

    return nil
end

function Loader.load_or_log(mod_name)
    local lib = Loader.load()
    if type(lib) ~= "table" then
        print("[" .. tostring(mod_name or "Mod")
            .. "] PleasureLib is required but could not be loaded.\n")
        return nil
    end
    return lib
end

function Loader.new(mod_name, options)
    local lib = Loader.load_or_log(mod_name)
    if type(lib) ~= "table" then return nil end

    options = options or {}
    options.mod = options.mod or mod_name
    return lib.new(options)
end

return Loader
