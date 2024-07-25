<!-- markdownlint-disable MD041 -->
<!-- markdownlint-disable MD033 -->
<!-- markdownlint-disable MD001 -->

<div align="center">

# lUAURouter

</div>

## About

A simple Go-inspired HTTP router for the Lune runtime.

### Features

* Routing based on path, method and host header;
* Path parameter parsing;
* Response body compression based on `Accept-Encoding` header;
* 'No route found' fallback handler;

<details>

<summary>Example</summary>

```lua
local router = require("./luau_router");

local server = router.server({ log = print, });

server.handle_route("GET /", function(req)
    return "Hello from Router!";
end);

server.handle_route("GET /forbidden", function(req)
    return { status = 403 };
end);

server.handle_route("GET /custom/{body}", function(req)
    return {
        body = `Hello from {req.params.body}`, 
        compress = true,
    };
end);

server.handle_404(function()
    return { status = 404, body = "Sorry, no route." };
end);

server.start(8080);
server.keep_alive();
```

</details>

## Usage

### Creating a Server

To use the router, you must first create a Router server instance.

A 'server' in LuauRouter refers to an instance containing a list of routes. A LuauRouter server is not tied to any single `net.serve` handler.

You can create a server instance by calling `router.server()`.

```lua
local server = router.server(
    compress = true, -- Compress response bodies by default?
    req_log = print, -- Log function, accepts a string.
)
```

### Handling Routes

You can define routes using the `server.handle_route` function.

```lua
server.handle_route("GET /", function(req: router.HttpRequest, route: string): router.HttpResponse
    -- Application Logic --
    return {
        status = 200,
        body = "<!DOCTYPE html>...",
    };
end);
```

### aa

## Notes

### Conflicting Paths

Unlike Go's 1.12 router, LuauRouter matches requests to handlers on a First-come First-server basis. This means the first defined handler that satisfies the request will be used.
