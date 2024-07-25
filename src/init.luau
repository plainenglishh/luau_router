local _PKGNAME = "LuauRouter";
local _PKGVERSION = "0.1.0";

local task = require("@lune/task");
local net = require("@lune/net");
local serde = require("@lune/serde");
local process = require("@lune/process");
local datetime = require("@lune/datetime");
local fs = require("@lune/fs");

local response_codes = require("./response_codes");
local mime_types = require("./mime_types");

local anti_gc = {};

local ENCODING_PREFERENCE = {
    "brotli",
    "gzip",
};

local ENCODINGS = {
    gzip = "gzip",
    br = "brotli",
};

local PORT_SUFFIX_MATCH = ":(%d+)$";
local PORT_ONLY_MATCH = "^%d+$";

--[[
    Converts empty strings to nil.
]]
local function empty_eq_nil(str: string?): string?
    if str == "" then
        return nil;
    else
        return str;
    end
end

--[[
    Provides a debug name for the passed function.
]]
local function f_name(func)
    return empty_eq_nil(debug.info(func, "n")) or tostring(func):gsub(":", "");
end

--[[
    The default 404 handler
]]
local function default_404_handler(): HttpResponse
    return { status = 404, body = "Not Found" };
end

--[[
    The default 405 handler
]]
local function default_405_handler(): HttpResponse
    return { status = 405, body = "Method Not Found" };
end

--[[
    Escapes special gsub syntax
]]
local function escape_gsub(str: string): string
    return str
        :gsub("%%", "%%%%")
        :gsub("%.", "%%.")
        :gsub("%(", "%%(")
        :gsub("%)", "%%)")
        :gsub("%+", "%%+")
        :gsub("%-", "%%-")
        :gsub("%^", "%%^")
        :gsub("%$", "%%$");
end

--[[
    Remove empty strings in an array
]]
local function remove_from_array(arr: {string}, rm: {string}): {string}
    local new = {};

    for _, v in arr do
        if not table.find(rm, v) then
            table.insert(new, v);
        end
    end

    return new;
end

--[[
    Remove empty strings in an array
]]
local function remove_empty_strs(arr: {string}): {string}
    return remove_from_array(arr, {""});
end

--[[
    Ensures a string ends with a certain string
]]
local function ensure_ends_with(str: string, suffix: string): string
    if not str:match(escape_gsub(suffix).."$") then
        return str..suffix;
    end
    return str;
end

local function rm_dbl_slash(str: string): string
    while true do
        str = str:gsub("//", "/");
        if not str:find("//") then
            break;
        end
    end
    return str;
end

local function dict_lowercase(dict: {[string]: any}): {[string]: any}
    local out = {};

    for k, v in dict do
        out[k:lower()] = v;
    end

    return out;
end

--------------------------------------------------------------------------------
--  Type & Class Definitions
--------------------------------------------------------------------------------

--[=[
	@class router

	Library for Go-style HTTP Routing

	### Example usage

	```luau
	local router =

	local server = router.server({
        compress = true,
        log = print,
    });

    local profiles = {
        ["plainenglish"] = {
            display_name = "Plain",
            country = "GB",
        },
    };

    server.handle_route("GET /users/{username}", function(req: router.HttpRequest)
        local profile = profiles[req.params.username];
        if profile then
            return {
                status = 200,
                body = profile, -- Serialised to JSON by default.
            };
        else
            return { status = 404 };
        end
    end);
    
    server.start(8080);
    server.keep_alive(); -- Yields indefinitely to prevent script from ending.
	```
]=]
local router = {};

export type HttpBody = buffer|string|{[any]: any};
export type StringMap = {[string]: string};
export type RouteHandler = (request: HttpRequest, route: string)->(HttpResponse);
export type SocketHandler = (websocket: net.WebSocket)->();
export type SocketAddr = string|number|{
    port: number,
    address: string?,
};

--[=[
	@interface HttpRequest
	@within router

	Dictionary respresenting an incoming HTTP request.

    This is a modified version of the Lune ServeRequest table provided by `net.serve`.

    * `path` - The path being requested, relative to the root. Will be `/` if not specified.
    * `params` - A table of path parameters as specified in the route string.
    * `query` - A table of key-value pairs representing query parameters in the request path.
	* `method` - The HTTP method verb, such as `"GET"`, `"POST"`, `"PATCH"`, `"PUT"`, or `"DELETE"`. Will always be uppercase.
	* `headers` - A table of key-value pairs representing headers.
	* `body` - The request body.
]=]
export type HttpRequest = {
    --[=[
        @within HttpRequest

       The path being requested, relative to the root. Will be `/` if not specified.
    ]=]
    path: string,

    --[=[
        @within HttpRequest

        A table of path parameters as specified in the route string.
    ]=]
    params: StringMap,

    --[=[
        @within HttpRequest

        A table of key-value pairs representing headers.
    ]=]
    headers: StringMap,

    --[=[
        @within HttpRequest

        A table of key-value pairs representing query parameters in the request path.
    ]=]
    query: StringMap,

    --[=[
        @within HttpRequest

        The request body.
    ]=]
    body: HttpBody?,

    --[=[
        @within HttpRequest

        The HTTP method verb, such as `"GET"`, `"POST"`, `"PATCH"`, `"PUT"`, or `"DELETE"`. Will always be uppercase.
    ]=]
    method: net.HttpMethod,
};

--[=[
	@interface HttpResponse
	@within router

	Dictionary respresenting an outgoing HTTP response.

    * `status` - A number representing the status code of the response. `200` by default.
    * `body` - A string, buffer or a table containing the response body. Will be serialised as JSON if a table.
    * `headers` - A dictionary containing HTTP headers.
	* `compress` - A boolean representing whether to compress the response. Will default to the servers `compress` option.
]=]
export type HttpResponse = {
    --[=[
        @within HttpResponse

        A number representing the status code of the response.
        
        `200` by default.
    ]=]
    status: number?,

    --[=[
        @within HttpResponse

        A string, buffer or a table containing the response body.
        
        Will be serialised as JSON if a table.
    ]=]
    body: HttpBody?,

    --[=[
        @within HttpResponse

        A dictionary containing HTTP headers.
    ]=]
    headers: StringMap?,

    --[=[
        @within HttpResponse
        
        A boolean representing whether to compress the response. Will default to the servers `compress` option.
    ]=]
    compress: boolean?,
};

--[=[
	@class Server
	@within router

	Class representing a server.

    * `active` - Whether the server is accepting requests.
    * `port` - The port number the server is accepting requests on.
    * `handle_route` - Sets the handler function for a given route.
    * `handle_404` - Sets the fallback handler.
    * `handle_websocket` - Sets the handler for WebSockets.
    * `stop` - Stops accepting requests.
    * `start` - Starts or restarts accepting requests.
    * `destroy` - Destroys the server instance.
    * `keep_alive` - Yields forever to prevent the script from exiting.
]=]
export type Server = {
    --[=[
        @within Server
        @readonly
            
        Whether the server is accepting requests.
    ]=]
    active: boolean,

    --[=[
        @within Server
        @readonly
            
        The port number the server is accepting requests on.
    ]=]
    port: number?,

    --[=[
        @within Server
        @readonly
            
        The IP address the server is accepting requests on.
    ]=]
    address: string?,

    --[=[
        @within Server
            
        Sets the handler function for a given route.

        Must be set before calling `start`, otherwise HTTP requests won't be accepted.

        @param route string -- The route to match the handler to.
        @param handler RouteHandler -- The handler function.
        @return Server -- The server instance, allows for chaining.
    ]=]
    handle_route: (route: string, handler: RouteHandler)->(Server),

    --[=[
        @within Server
            
        Sets the 404 Not Found fallback handler.

        @param handler RouteHandler -- The handler function.
        @return Server -- The server instance, allows for chaining.
    ]=]
    handle_404: (handler: RouteHandler)->(Server),

    --[=[
        @within Server
            
        Sets the 405 Method Not Found fallback handler.

        @param handler RouteHandler -- The handler function.
        @return Server -- The server instance, allows for chaining.
    ]=]
    handle_405: (handler: RouteHandler)->(Server),

    --[=[
        @within Server
            
        Sets the handler for WebSockets.

        Must be set before calling `start`, otherwise WebSocket requests won't be accepted.

        @param handler SocketHandler -- The WebSocket handler function.
        @return Server -- The server instance, allows for chaining.
    ]=]
    handle_websocket: (handler: SocketHandler)->(Server),

    --[=[
        @within Server
            
        Stops accepting requests.

        Can be resumed with `start`.

        @return Server -- The server instance, allows for chaining.
    ]=]
    stop: ()->(Server),

    --[=[
        @within Server
            
        Starts or restarts accepting requests.

        @param addr SocketAddr -- A string containing the port and/or address to bind to.
        @param callback (Server)->()? -- Callback called when the server starts listening for requests.
        @return Server -- The server instance, allows for chaining.
    ]=]
    start: (addr: SocketAddr, callback: (Server)->()?)->(Server),

    --[=[
        @within Server
            
        Destroys the server instance.
    ]=]
    destroy: ()->(),

    --[=[
        @within Server
        @yields

        Yields forever to prevent the script from exiting.
    ]=]
    keep_alive: ()->never,
};

--[=[
	@interface ServerOptions
	@within router

	Parameters for sending network requests with `net.request`.

	This is a dictionary that may contain one or more of the following values:

	* `compress` - Boolean representing whether to compress response bodies by default.
    * `log` - A callback to be used to log incoming requests. Should accept a string as the first argument (i.e print).
]=]
export type ServerOptions = {
    --[=[
        @within ServerOptions

        Boolean representing whether to compress response bodies by default.
    ]=]
    compress: boolean?,

    --[=[
        @within ServerOptions

        A callback to be used to log incoming requests. Should accept a string as the first argument (i.e print).
    ]=]
    req_log: (string)->()?,

    --[=[
        @within ServerOptions

        A callback to be used to log misc server operations. Should accept a string as the first argument (i.e print).
    ]=]
    sys_log: (string)->()?,
};


--------------------------------------------------------------------------------
--  Utility Functions
--------------------------------------------------------------------------------

router.util = {};
router.util.response_code_map = response_codes;

--[=[
    @within router

    Applies router specific headers to a header dictionary.

    @param headers StringMap -- The header dictionary.
    @return StringMap -- The modified header dictionary.
]=]
function router.util.apply_header(headers: StringMap): StringMap
    headers = headers or {};
    headers["server"] = headers["server"] or `{_PKGNAME}/{_PKGVERSION} ({process.os})`;
    headers["keep alive"] = nil;
    return headers;
end

--[=[
    @within router

    Matches paths with dynamic parameters.

    @param route_path string -- The route path.
    @param req_path string -- The requested path.
    @return boolean -- Whether the requested path matches the route.
    @return StringMap? -- A list of parameters, if matched.
]=]
function router.util.match_path(route_path: string, req_path: string): (boolean, StringMap?)
    if route_path == req_path then
        return true, {};
    end

    local params = {};
    local handler_path_components = remove_empty_strs(route_path:split("/"));
    local request_path_components = remove_empty_strs(req_path:split("/"));

    if #handler_path_components ~= #request_path_components then
        if handler_path_components[#handler_path_components] ~= "**" then
            return false;
        end
    end

    for i, v in handler_path_components do
        local param_name = v:match("^{(.-)}$");
        
        if param_name then
            if request_path_components[i] == "" then
                return false;
            end

            params[param_name] = request_path_components[i];
        else
            if 
                v ~= request_path_components[i]
                and v ~= "*"
            then
                if v == "**" then
                    if i == #handler_path_components then
                        continue;
                    else
                        error("attempt to use open ended wildcard halfway through path");
                    end
                else
                    return false;
                end
            end
        end
    end
    
    return true, params;
end

--[=[
    @within router

    Selects an encoding method based on the preference order.

    @param accepted string -- String from the `Accept-Encoding` header.
    @param preference {string}? -- A custom preference order.
    @return string? -- The preferred encoding method. Absent if no compatible encoding is found.
    @return string? -- The preferred encoding in the `Content-Encoding` format. Absent if no compatible encoding is found.
]=]
function router.util.select_encoding(accepted: string, preference: {string}?): (string?, string?)
    local encodings = accepted:gsub("%s", ""):split(",");

    local encoding_pref = preference or ENCODING_PREFERENCE;

    for _, preferred in encoding_pref do
        for _, v in encodings do
            local raw = v:split(";")[1];
            local encoding = ENCODINGS[raw];
            if encoding == preferred then
                return preferred, raw;
            end
        end
    end

    return nil;
end

--[=[
    @within router

    Encodes a response body depending on the supported client encoding methods.

    @param body string|buffer -- The body to encode.
    @param accepted string -- The `Accept-Encoding` header of the request.
    @return string|buffer -- The encoded body.
    @return string? -- The encoding method used (in the `Content-Encoding format`). Absent if no encoding was applied.
]=]
function router.util.encode_body(body: string|buffer, accepted: string): (string|buffer, string?)
    local selected_encoding, raw = router.util.select_encoding(accepted);
    if not selected_encoding then
        return body;
    else
        local encoded = serde.compress(selected_encoding, body);
        return encoded, raw;
    end
end

--[=[
    @within router

    Parses a socket address string into seperate port/address values.

    @param addr SocketAddr -- The socket address.
    @return number -- The port.
    @return string? -- The address.
]=]
function router.util.parse_addr(addr: SocketAddr): (number, string?)
    if typeof(addr) == "table" then
        return 
            addr.port or error("port field must be present", 2),
            addr.address;
    elseif typeof(addr) == "number" then
        return addr;
    elseif typeof(addr) == "string" then
        local port = addr:match(PORT_ONLY_MATCH);
        if port then
            return tonumber(port) or error("port couldn't be converted to a number", 2);
        else
            port = addr:match(PORT_SUFFIX_MATCH);
        end

        local address = addr:gsub(PORT_SUFFIX_MATCH, "");

        return 
            tonumber(port) or error("port couldn't be converted to a number", 2),
            empty_eq_nil(address);
    else
        error("invalid address format provided", 2);
    end
end

--[[
    @within router

    Creates a log file object. Use logfile.write as the log function, and use logfile.dump to get the current value.
]]
function router.util.logfile()
    local file = "";

    return {
        write = function(text: string)
            file ..= text.."\n";
        end,

        dump = function(): string
            return file;
        end,
    };
end

function router.util.parse_route(route: string)
    return {
        method = empty_eq_nil(route:match("^(%u+)%s")),
        path = empty_eq_nil(route:match("(/.-)$")),
        host = empty_eq_nil(route:match("([^%s]-)/.-$")),
    };
end

function router.util.remove_path_prefix(prefix: string, path: string): (string, string)
    local pfx_len = #remove_from_array(prefix:split("/"), {"", "**"});
    local components = remove_from_array(path:split("/"), {""});

    local removed = "/";

    for i = 1, pfx_len do
        removed ..= table.remove(components, 1) :: any .. "/";
    end

    return "/"..table.concat(components, "/").."/", removed;
end


--------------------------------------------------------------------------------
--  Server Constructor
--------------------------------------------------------------------------------

--[=[
    @within router

    Creates a server instance.

    @param options ServerOptions? -- The server options.
    @return Server -- The server instance.
]=]
function router.server(options: ServerOptions?): Server
    local _options = options or {};

    local serve_handler;
    local http_active = false;
    local ws_active = false;
    local handler_404 = default_404_handler;
    local handler_405 = default_405_handler;
    local handler_socket;

    local function write_log(message: string, stream: string?)
        local _stream = stream or "sys";
        local func = _options[_stream.."_log"];
        if func then
            local date = datetime.now():toIsoDate()
                            :sub(1, 19)
                            :gsub("T", " ")
                            :gsub("-", "/");

            func(`[{date}]: {message}`);
        end
    end

    --// Create server instance
    local server = newproxy(true);
    local raw_name = tostring(server);
    local api = {};

    local mt = getmetatable(server);
    mt.__index = api;
    mt.__metatable = false;
    mt.__tostring = function(t)
        return raw_name:gsub("userdata: ", "RouterServer: ");
    end;
    mt.__newindex = function()
        error("Attempt to set readonly property", 2); 
    end;

    write_log("Created server instance");

    --// Setup API    
    api.active = false;
    api.port = nil;
    api.address = nil;

    local route_table = {};

    function api.handle_route(route: string, handler: RouteHandler): Server
        assert(server, "Instance is destroyed");
        http_active = true;

        local parsed = router.util.parse_route(route);

        table.insert(route_table, {
            host = parsed.host,
            method = parsed.method,
            path = parsed.path,
            route = route,
            handler = handler,
        });

        write_log(`Assigned route '{route}' to '{f_name(handler)}' @ ln {debug.info(handler, "l")}`);

        return server;
    end

    function api.handle_404(handler: RouteHandler): Server
        assert(server, "Instance is destroyed");
        http_active = true;
        handler_404 = handler;

        write_log(`Assigned 404 fallback to '{f_name(handler)}' @ ln {debug.info(handler, "l")}`);

        return server;
    end

    function api.handle_405(handler: RouteHandler): Server
        assert(server, "Instance is destroyed");
        http_active = true;
        handler_405 = handler;

        write_log(`Assigned 405 fallback to '{f_name(handler)}' @ ln {debug.info(handler, "l")}`);

        return server;
    end

    function api.handle_websocket(handler: SocketHandler): Server
        assert(server, "Instance is destroyed");
        ws_active = true;
        handler_socket = handler;

        write_log(`Assigned websockets to '{f_name(handler)}' @ ln {debug.info(handler, "l")}`);

        return server;
    end

    function api.stop(): Server
        assert(server, "Instance is destroyed");
        
        if api.active then
            serve_handler.stop();
            serve_handler = nil;
            api.active = false;
        end

        write_log(`Server stopped`);

        return server;
    end

    function api.destroy()
        assert(server, "Instance is destroyed");
        
        api.stop();
        serve_handler = nil;
        server = nil;

        write_log(`Server destroyed`);
    end

    function api.keep_alive()
        while true do
            task.wait(1);
        end
    end

    function api.start(addr: SocketAddr, callback: (Server)->()?): Server
        assert(server, "Instance is destroyed");

        local port, address = router.util.parse_addr(addr);
        address = address or "127.0.0.1";

        --[[
            Function used to accept incoming HTTP requests
        ]]
        local function handle_request(req: net.ServeRequest): net.ServeResponse
            local params = {};
            local route;

            local method_not_found;

            -- Search for valid route
            for i, p_route in route_table do
                local method_matches = p_route.method == nil or p_route.method == req.method;
                local host = req.headers.host and req.headers.host:split(":")[1];
                local host_matches = p_route.host == nil or p_route.host == host; 
                local path_matches, _params = router.util.match_path(p_route.path, req.path);
    
                params = _params;
                
                if host_matches and path_matches then
                    if method_matches then
                        route = p_route;
                        method_not_found = false;
                        break;
                    else
                        method_not_found = true;
                    end
                end
            end

            -- Call route handler
            local ok, res_or_err = pcall(route and route.handler or (if method_not_found then handler_405 else handler_404), {
                path = req.path,
                params = params,
                headers = req.headers,
                query = req.query :: any,
                method = req.method,
                body = empty_eq_nil(req.body),
            }, if route then route.route else nil);
    
            local res;
            
            if ok then
                -- Handler succeeded, will 
                res_or_err = res_or_err or {
                    status = 200,
                };
    
                if typeof(res_or_err) == "string" then
                    res_or_err = {
                        status = 200,
                        body = res_or_err,
                    };
                elseif typeof(res_or_err) == "number" then
                    res_or_err = { status = res_or_err };
                end

                local temp_res = {};
                temp_res.body = res_or_err.body;
                temp_res.headers = res_or_err.headers or {};
                temp_res.status = res_or_err.status or 200;

                if typeof(temp_res.body) == "table" then
                    temp_res.body = serde.encode("json", temp_res.body);
                    temp_res.headers["content-type"] = "application/json";
                end
    
                local encoding_method;
    
                if (res_or_err.compress or _options.compress) and temp_res.body then 
                    temp_res.body, encoding_method = router.util.encode_body(temp_res.body, req.headers["accept-encoding"] or "") 
                end
    
                temp_res.headers["content-encoding"] = encoding_method or temp_res.headers["content-encoding"];
                res = temp_res;
            else
                warn(`Handler for '{route.route}' failed: `, res_or_err);
                res = {
                    status = 500,
                    body = tostring(res_or_err),
                };
            end

            res.status = res.status or 200;
            res.headers = router.util.apply_header(res.headers);

            local status_message = response_codes[tostring(res.status)].message;

            if not res.body then
                res.body = status_message;
            end

            -- Log
            if _options.req_log then
                write_log(`{req.method} {req.path} - {res.status} {status_message}`, "req");
            end

            return res;
        end
    
        --[[
            Function used to handle incoming websockets
        ]]
        local function handle_websocket(socket: net.WebSocket)
            if handler_socket then
                handler_socket(socket);
            end
        end
        
        serve_handler = net.serve(port, {
            address = if address then "http://"..address else nil,
            handleRequest = http_active and function(...)
                local ok, res = pcall(handle_request, ...);
                if ok then
                    return res;
                else
                    warn(`Failed to process request: `, res);
                    return {
                        status = 500,
                        body = tostring(res),
                    };
                end
            end or nil,
            handleWebSocket = ws_active and handle_websocket or nil,
        });

        table.insert(anti_gc, serve_handler);

        api.active = true;
        api.port = port;
        api.address = address;

        write_log(`Server started, listening to {address}:{port}`);

        if callback then
            callback(server);
        end

        return server;
    end

    return server;
end


--------------------------------------------------------------------------------
--  Predefined Handlers
--------------------------------------------------------------------------------

router.handlers = {};

function router.handlers.proxy(url: string, transform: (HttpRequest)->(HttpRequest)?, forward_q_string: boolean?, max_retries: number?)
    return function(req: HttpRequest, route: string): HttpResponse
        local q_str = "";
        if forward_q_string then
            q_str = "?";

            for i, v in req.query do
                q_str ..= `{net.urlEncode(i)}={net.urlEncode(v)}&`;
            end

            q_str = q_str:gsub("%&$", "");
        end
        
        local route_parsed = router.util.parse_route(route);
        local path = router.util.remove_path_prefix(route_parsed.path, req.path);
        
        local fwd_req = {
            url = url .. path .. q_str,
            method = req.method,
            body = req.body,
            headers = req.headers,
        };


        --print("I will proxy to", fwd_req.url)

        fwd_req.headers.host = url:match("^.-//(.-)/.+$") or nil :: any;

        if transform then
            fwd_req = transform(table.clone(fwd_req) :: any) :: any
        end

        local upstream_res;
        for i = 1, max_retries or 5 do
            local ok, val = pcall(net.request, fwd_req);
            if ok then
                upstream_res = val;
                break;
            end

            if i == (max_retries or 5) then
                return {
                    status = 500,
                    body = "Epic Fail: "..tostring(val),
                };
            end
        end

        local res = {
            status = upstream_res.statusCode,
            headers = dict_lowercase(upstream_res.headers),
            body = upstream_res.body,
            compress = false,
        };

        res.headers["x-content-type-options"] = nil; -- If these headers are present, the socket closes. I don't know why.
        --res.headers["x-frame-options"] = nil;        -- ^
        res.headers = {};
        return res;
    end
end

function router.handlers.directory(dir: string, include_dir_listing: boolean?)
    local function create_dir_listing(path, modified, created, size)
        return `<tr><td>{path or ""}</td><td>{modified or ""}</td></tr>`
    end

    local DIR_LISTING_TEMPL = [[
        <!DOCTYPE html>
        <html>
            <head>
                <style>
                    * {
                        font-family: 'Courier New', Courier, monospace;
                        font-size: 10pt;
                    }
                
                    table {
                        margin-left: auto;
                        margin-right: auto;
                    }
                </style>
            </head>
            <body>
                <h3 style="text-align: center">Directory Listing for %s</h3>
                <table>
                    <tr>
                        <th>Path</th>
                        <th>Modified</th>
                    </tr>
                    %s
                </table>
                <p style="text-align: center">%s - %s</p>
            </body>
        </html>
    ]]

    local base_dir = ensure_ends_with(dir, "/");

    return function(req: HttpRequest, route: string)
        local route_parsed = router.util.parse_route(route);
        assert(route_parsed.method == "GET", "predefined directory handler can only be used with a `GET ...` route");
        
        for _, part in req.path:split("/") do
            if part:match("^%.+$") or net.urlDecode(part):match("^%.+$") then
                return 400;
            end
        end

        local path, original_path = router.util.remove_path_prefix(route_parsed.path, req.path);
        path, original_path = rm_dbl_slash(path), rm_dbl_slash(original_path);
        local file_path = rm_dbl_slash((base_dir .. net.urlDecode(path))):gsub("/$", "");

        local metadata = fs.metadata(file_path);

        if not metadata.exists then
            return 404;
        elseif metadata.kind == "dir" then
            if include_dir_listing then
                local list = "";

                if path ~= "/" then
                    local current_path = remove_empty_strs(path:split("/"));
                    table.remove(current_path, #current_path);

                    list ..= create_dir_listing(`<a href="{original_path..table.concat(current_path, "/")}">..</a>`);                end

                for _, file in fs.readDir(file_path) do
                    local url = original_path..(path..file):gsub("^/", "");
                    local md = fs.metadata(ensure_ends_with(file_path, "/")..file);

                    if not md.exists then 
                        continue;
                    end
                    
                    local modified_at = md.modifiedAt:toIsoDate()
                            :sub(1, 19)
                            :gsub("T", " ")
                            :gsub("-", "/");

                    if md.kind == "dir" then
                        list ..= create_dir_listing(`<a href="{url}">{file}/</a>`, modified_at);
                    else
                        list ..= create_dir_listing(`<a href="{url}">{file}</a>`, modified_at);
                    end
                end

                return DIR_LISTING_TEMPL:format(
                    net.urlDecode(path),
                    list,
                    _PKGNAME,
                    _PKGVERSION
                );
            else
                return 404;
            end
        else
            local ext = file_path:split(".");
            ext = ext[#ext];

            local content_type;
            if ext then
                content_type = mime_types["."..ext];
            end

            local file = fs.readFile(file_path);

            return {
                body = file,
                headers = {
                    ["content-type"] = content_type,
                },
                compress = false,
            };
        end
    end
end

--------------------------------------------------------------------------------
--  Export
--------------------------------------------------------------------------------

--[[router.server({ sys_log = print, req_log = print })
    .handle_route("GET /upload", function()
        return "Upload page";
    end)
    .handle_route("GET /**", router.handlers.directory("../../Pictures/funnies", true))
    .start(8080)
    .keep_alive();]]

--[[
    TODO:

    [ ] Dedent Util
    [ ] Docs
]]

return router;