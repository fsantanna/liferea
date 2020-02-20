#!/usr/bin/env lua5.3

local socket = require 'socket'
local json   = require 'json'

--[[
freechains://?cmd=publish&cfg=/data/ceu/ceu-libuv/ceu-libuv-freechains/cfg/config-8400.lua
freechains::-1?cmd=publish&cfg=/data/ceu/ceu-libuv/ceu-libuv-freechains/cfg/config-8400.lua
freechains://<address>:<port>/<chain>/<work>/<hash>?
]]

local function ASR (cnd, msg)
    msg = msg or 'malformed command'
    if not cnd then
        io.stderr:write('ERROR: '..msg..'\n')
        os.exit(1)
    end
    return cnd
end

local url = assert((...))

--local log = assert(io.open('/tmp/log.txt','a+'))
local log = io.stderr
log:write('URL: '..url..'\n')

if string.sub(url,1,13) ~= 'freechains://' then
    os.execute('xdg-open '..url)
    os.exit(0)
end

local address, port, res = string.match(url, 'freechains://([^:]*):([^/]*)(/.*)')
ASR(address and port and res)
log:write('URL: '..res..'\n')

DAEMON = {
    address = address,
    port    = ASR(tonumber(port)),
}
daemon = DAEMON.address..':'..DAEMON.port

local CFG = {
    chains = {}
}
do
    local f = io.open(os.getenv('HOME')..'/.config/freechains-liferea.json')
    if f then
        CFG = json.decode(f:read('*a'))
        f:close()
    end
end

-------------------------------------------------------------------------------

function hash2hex (hash)
    local ret = ''
    for i=1, string.len(hash) do
        ret = ret .. string.format('%02X', string.byte(string.sub(hash,i,i)))
    end
    return ret
end

function escape (html)
    return (string.gsub(html, "[}{\">/<'&]", {
        ["&"] = "&amp;",
        ["<"] = "&lt;",
        [">"] = "&gt;",
        ['"'] = "&quot;",
        ["'"] = "&#39;",
        ["/"] = "&#47;"
    }))
end -- https://github.com/kernelsauce/turbo/blob/master/turbo/escape.lua

function iter (chain)
    local visited = {}
    local heads   = {}

    local function one (hash,init)
        if visited[hash] then return end
        visited[hash] = true

        local c = assert(socket.connect(DAEMON.address,DAEMON.port))
        c:send("FC chain get\n"..chain.."\n"..hash.."\n")
        local ret = c:receive('*a')

        local block = json.decode(ret)
        if not init then
            coroutine.yield(block)
        end

        for _, front in ipairs(block.fronts) do
            one(front)
        end

        if #block.fronts == 0 then
            heads[#heads+1] = hash
        end
    end

    return coroutine.wrap(
        function ()
            local cfg = CFG.chains[chain] or {}
            CFG.chains[chain] = cfg
            if cfg.heads then
                for _,hash in ipairs(cfg.heads) do
                    one(hash,true)
                end
            else
                local c = assert(socket.connect(DAEMON.address,DAEMON.port))
                c:send("FC chain genesis\n"..chain.."\n")
                local hash = c:receive('*l')
                one(hash,true)
            end

            cfg.heads = heads
            local f = assert(io.open(os.getenv('HOME')..'/.config/freechains-liferea.json','w'))
            f:write(json.encode(CFG)..'\n')
            f:close()
        end
    )
end

-------------------------------------------------------------------------------

-- new
if not cmd then
    cmd = string.match(res, '^/%?cmd=(new)')
end

-- subscribe
if not cmd then
    chain, cmd = string.match(res, '^(/[^/]*)/%?cmd=(subscribe)')
end
if not cmd then
    chain, cmd, address, port = string.match(res, '^(/[^/]*)/%?cmd=(subscribe)&peer=(.*):(.*)')
end

-- publish
if not cmd then
    chain, cmd = string.match(res, '^(/[^/]*)/%?cmd=(publish)')
end

-- atom
if not cmd then
    chain, cmd = string.match(res, '^(/.*)/%?cmd=(atom)')
end

log:write('INFO: .'..cmd..'.\n')

if cmd=='new' or cmd=='subscribe' then
    -- get chain
    if cmd == 'new' then
        local f = io.popen('zenity --entry --title="Join new chain" --text="Chain path:"')
        chain = f:read('*a')
        chain = string.sub(chain,1,-2)
        local ok = f:close()
        if not ok then
            log:write('ERR: '..chain..'\n')
            goto END
        end
    end

    -- subscribe
    local c = assert(socket.connect(DAEMON.address,DAEMON.port))
    c:send("FC chain create\n"..chain.."\nrw\n\n\n\n")

    local exe = 'dbus-send --session --dest=org.gnome.feed.Reader --type=method_call /org/gnome/feed/Reader org.gnome.feed.Reader.Subscribe "string:|freechains-liferea freechains://'..daemon..chain..'/?cmd=atom"'
    os.execute(exe)

elseif cmd == 'publish' then
    local f = io.popen('zenity --text-info --editable --title="Publish to '..chain..'"')
    local payload = f:read('*a')
    local ok = f:close()
    if not ok then
        log:write('ERR: '..payload..'\n')
        goto END
    end

    local c = assert(socket.connect(DAEMON.address,DAEMON.port))
    c:send("FC chain put\n"..chain.."\nutf8\nnow\nfalse\n"..payload.."\n\n")

--[=[
elseif cmd == 'removal' then
    error'TODO'
    FC.send(0x0300, {
        chain = {
            key   = key,
            zeros = assert(tonumber(zeros)),
        },
        removal = block,
    }, DAEMON)
]=]

elseif cmd == 'atom' then
    TEMPLATES =
    {
        feed = [[
            <feed xmlns="http://www.w3.org/2005/Atom">
                <title>__TITLE__</title>
                <updated>__UPDATED__</updated>
                <id>
                    freechains:__CHAIN__/
                </id>
            __ENTRIES__
            </feed>
        ]],
        entry = [[
            <entry>
                <title>__TITLE__</title>
                <id>
                    freechains:__CHAIN__/__HASH__/
                </id>
                <published>__DATE__</published>
                <content type="html">__PAYLOAD__</content>
            </entry>
        ]],
    }

    -- TODO: hacky, "plain" gsub
    gsub = function (a,b,c)
        return string.gsub(a, b, function() return c end)
    end

    if not chain then
        error 'TODO'
        entries = {}
        entry = TEMPLATES.entry
        entry = gsub(entry, '__TITLE__',   'not subscribed')
        entry = gsub(entry, '__CHAIN__',   chain)
        entry = gsub(entry, '__HASH__',    string.rep('00', 32))
        entry = gsub(entry, '__DATE__',    os.date('!%Y-%m-%dT%H:%M:%SZ', os.time()))
        entry = gsub(entry, '__PAYLOAD__', 'not subscribed')
        entries[#entries+1] = entry
    else
        entries = {}

        for block in iter(chain) do
            local payload = block.hashable.payload
            local title = escape(string.match(payload,'([^\n]*)'))

            payload = payload .. [[


-------------------------------------------------------------------------------

<!--
- [X](freechains:/]]..chain..'/'..block.hash..[[/?cmd=republish)
Republish Contents
- [X](freechains:/]]..chain..'/'..block.hash..[[/?cmd=removal)
Inappropriate Contents
-->
]]

            -- freechains links
            payload = string.gsub(payload, '(%[.-%]%(freechains:)(/.-%))', '%1//'..daemon..'%2')

            -- markdown
--if false then
            do
                local tmp = os.tmpname()
                local md = assert(io.popen('pandoc -r markdown -w html > '..tmp, 'w'))
                md:write(payload)
                assert(md:close())
                local html = assert(io.open(tmp))
                payload = html:read('*a')
                html:close()
                os.remove(tmp)
            end
--end

            payload = escape(payload)

            entry = TEMPLATES.entry
            entry = gsub(entry, '__TITLE__',   title)
            entry = gsub(entry, '__CHAIN__',   chain)
            entry = gsub(entry, '__HASH__',    block.hash)
            entry = gsub(entry, '__DATE__',    os.date('!%Y-%m-%dT%H:%M:%SZ', block.hashable.timestamp))
            entry = gsub(entry, '__PAYLOAD__', payload)
            entries[#entries+1] = entry
        end

        -- MENU
        do
            entry = TEMPLATES.entry
            entry = gsub(entry, '__TITLE__',   'Menu')
            entry = gsub(entry, '__CHAIN__',   chain)
            entry = gsub(entry, '__HASH__',    hash2hex(string.rep('\0',32)))
            entry = gsub(entry, '__DATE__',    os.date('!%Y-%m-%dT%H:%M:%SZ', 25000))
            entry = gsub(entry, '__PAYLOAD__', escape([[
<ul>
]]..(chain~='/' and '' or [[
<li> <a href="freechains://]]..daemon..[[/?cmd=new">[X]</a> join new chain
]])..[[
<li> <a href="freechains://]]..daemon..chain..[[/?cmd=publish">[X]</a> publish to "]]..chain..[["
</ul>
]]))
            entries[#entries+1] = entry
        end
    end

    feed = TEMPLATES.feed
    feed = gsub(feed, '__TITLE__',   chain)
    feed = gsub(feed, '__UPDATED__', os.date('!%Y-%m-%dT%H:%M:%SZ', os.time()))
    feed = gsub(feed, '__CHAIN__',   chain)
    feed = gsub(feed, '__ENTRIES__', table.concat(entries,'\n'))

    f = io.stdout --assert(io.open(dir..'/'..key..'.xml', 'w'))
    f:write(feed)

    -- configure: save last.atom
    --FC.send(0x0500, CFG, DAEMON)

    goto END

end

::OK::
--os.execute('zenity --info --text="OK"')
goto END

::ERROR::
os.execute('zenity --error')

::END::

log:close()
