if util.IsBinaryModuleInstalled( "flzma" ) then
    require( "flzma" )
end

walker.Include( "express", { "init.lua" } )
