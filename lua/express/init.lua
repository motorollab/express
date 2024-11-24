require( "pon" )

if SERVER then
    util.AddNetworkString( "express" )
    util.AddNetworkString( "express_proof" )
    util.AddNetworkString( "express_receivers_made" )
end

---@diagnostic disable-next-line
express = {}
express._receivers = {}
express._protocol = "http"
express._awaitingProof = {}
express._preDlReceivers = {}
express._maxDataSize = 24 * 1024 * 1024
express._jsonHeaders = { ["Content-Type"] = "application/json" }
express._bytesHeaders = { ["Accept"] = "application/octet-stream" }

-- Removes a receiver --
function express.ClearReceiver( message )
    message = string.lower( message )
    express._receivers[message] = nil
end

-- Registers a PreDownload receiver --
function express.ReceivePreDl( message, preDl )
    message = string.lower( message )
    express._preDlReceivers[message] = preDl
end

---@diagnostic disable-next-line
local flzma = flzma

---@param compressed string
---@param callback fun( decompressed: string )
local decompress = function( compressed, callback )
    if not flzma then
        callback( util.Decompress( compressed ) )
    end

    collectgarbage( "stop" )
    flzma.DecompressAsync( compressed, function( decompressed )
        callback( decompressed )
        collectgarbage( "restart" )
    end )
end

-- Retrieves and parses the data for given ID --
function express:Get( id, callback )
    local parameters = {
        url = self:makeAccessURL( "read", id ),
        method = "GET",
        failed = error,
        headers = self._bytesHeaders,
        timeout = self:_getTimeout()
    }

    local attempts = 1
    parameters.success = function( code, body )
        if code == 404 then
            assert( attempts <= 35, "express:Get() failed to retrieve data after 35 attempts: " .. id )

            timer.Simple( 0.125 * attempts, function()
                HTTP( parameters )
            end )

            attempts = attempts + 1
        else
            express._checkResponseCode( code )

            if attempts > 1 then
                print( "express:Get() succeeded after " .. attempts .. " attempts: " .. id )
            end

            if string.StartsWith( body, "<lzma>" ) then
                decompress( body:sub( 7 ), function( decompressed )
                    callback( pon.decode( decompressed ), util.SHA1( decompressed ) )
                end )
            else
                callback( pon.decode( body ), util.SHA1( body ) )
            end
        end
    end

    HTTP( parameters )
end

-- Asks the API for this ID's data's size --
function express:GetSize( id, cb )
    local url = self:makeAccessURL( "size", id )

    local success = function( code, body )
        express._checkResponseCode( code )

        local sizeHolder = util.JSONToTable( body )
        assert( sizeHolder, "Invalid JSON" )

        local size = sizeHolder.size
        if not size then
            print( "Express: Failed to get size for ID '" .. id .. "'.", code )
            print( body )
        end
        assert( size, "No size data" )

        cb( tonumber( size ) )
    end

    HTTP( {
        method = "GET",
        url = url,
        success = success,
        failed = error,
        headers = self._jsonHeaders,
        timeout = self:_getTimeout()
    } )
end

-- Given prepared data, sends it to the API --
function express:Put( data, cb )
    local success = function( code, body )
        express._checkResponseCode( code )

        local response = util.JSONToTable( body )
        assert( response, "Invalid JSON" )
        assert( response.id, "No ID returned" )

        cb( response.id )
    end

    HTTP( {
        method = "POST",
        url = self:makeAccessURL( "write" ),
        body = data,
        success = success,
        failed = error,
        headers = { ["Content-Length"] = #data, ["Accept"] = "application/json" },
        type = "application/octet-stream",
        timeout = CLIENT and 240 or 60
    } )
end

-- Runs the express receiver for the given message --
function express:Call( message, ply, data )
    local cb = self:_getReceiver( message )
    if not cb then
        return
    end

    if CLIENT then
        return cb( data )
    end
    if SERVER then
        return cb( ply, data )
    end
end

-- Runs the express pre-download receiver for the given message --
function express:CallPreDownload( message, ply, id, size, needsProof )
    local cb = self:_getPreDlReceiver( message )
    if not cb then
        return
    end

    if CLIENT then
        return cb( message, id, size, needsProof )
    end
    if SERVER then
        return cb( message, ply, id, size, needsProof )
    end
end

-- Handles a net message containing an ID to download from the API --
function express.OnMessage( _, ply )
    local message = net.ReadString()
    if not express:_getReceiver( message ) then
        error( "Express: Received a message that has no listener! (" .. message .. ")" )
    end

    local id = net.ReadString()
    local needsProof = net.ReadBool()

    local function makeRequest( size )
        if size then
            local check = express:CallPreDownload( message, ply, id, size, needsProof )
            if check == false then
                return
            end
        end

        express:_get( id, function( data, hash )
            express:Call( message, ply, data )

            if not needsProof then
                return
            end
            net.Start( "express_proof" )
            net.WriteString( hash )
            express.shSend( ply )
        end )
    end

    if express:_getPreDlReceiver( message ) then
        return express:_getSize( id, makeRequest )
    end

    makeRequest()
end

-- Handles a net message containing a proof of data download --
function express.OnProof( _, ply )
    -- Server prefixes the hash with the player's Steam ID
    local prefix = ply and ply:SteamID64() .. "-" or ""
    local hash = prefix .. net.ReadString()

    local cb = express._awaitingProof[hash]
    if not cb then
        return
    end

    cb( ply )
    express._awaitingProof[hash] = nil
end

net.Receive( "express", express.OnMessage )
net.Receive( "express_proof", express.OnProof )

hook.Add( "CreateTeams", "ExpressLoaded", function()
    hook.Run( "ExpressLoaded" )
end )
