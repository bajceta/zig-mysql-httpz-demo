const std = @import("std");
const httpz = @import("httpz");
const Allocator = std.mem.Allocator;

const sql = @import("mysql");
const testing = std.testing;
const ht = @import("httpz").testing;

const PORT = 8801;

// This example demonstrates basic httpz usage, with focus on using the
// httpz.Request and httpz.Response objects.

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    // We pass a "void" handler. This is the simplest, but limits what we can do
    // The last parameter is an instance of our handler. Since we have
    // a void handler, we pass a void value: i.e. {}.
    var server = try httpz.Server(void).init(allocator, .{
        .port = PORT,
        .request = .{
            // httpz has a number of tweakable configuration settings (see readme)
            // by default, it won't read form data. We need to configure a max
            // field count (since one of our examples reads form data)
            .max_form_count = 20,
        },
    }, {});
    defer server.deinit();

    // ensures a clean shutdown, finishing off any existing requests
    // see 09_shutdown.zig for how to to break server.listen with an interrupt
    defer server.stop();

    var router = server.router(.{});

    // Register routes. The last parameter is a Route Config. For these basic
    // examples, we aren't using it.
    // Other support methods: post, put, delete, head, trace, options and all
    router.get("/", index, .{});
    router.get("/hello", hello, .{});
    router.get("/json/hello/:name", json, .{});
    router.get("/writer/hello/:name", writer, .{});
    router.get("/metrics", metrics, .{});
    router.get("/form_data", formShow, .{});
    router.post("/form_data", formPost, .{});
    router.get("/explicit_write", explicitWrite, .{});

    std.debug.print("listening http://localhost:{d}/\n", .{PORT});

    // Starts the server, this is blocking.
    try server.listen();
}

fn index(_: *httpz.Request, res: *httpz.Response) !void {
    res.body =
        \\<!DOCTYPE html>
        \\ <ul>
        \\ <li><a href="/hello?name=Teg">Querystring + text output</a>
        \\ <li><a href="/writer/hello/Ghanima">Path parameter + serialize json object</a>
        \\ <li><a href="/json/hello/Duncan">Path parameter + json writer</a>
        \\ <li><a href="/metrics">Internal metrics</a>
        \\ <li><a href="/form_data">Form Data</a>
        \\ <li><a href="/explicit_write">Explicit Write</a>
    ;
}

fn hello(_: *httpz.Request, res: *httpz.Response) !void {
    const dbval = fromDB(res.arena);
    if (dbval) |val| {
        std.debug.print("DBVAL: {s}\n", .{val.?});
        res.body = try std.fmt.allocPrint(res.arena, "Hello {s}", .{val.?});
    } else |err| {
        std.debug.print("DB fail, {}", .{err});
        res.body = try std.fmt.allocPrint(res.arena, "DBError {}", .{err});
    }
}

fn json(req: *httpz.Request, res: *httpz.Response) !void {
    const name = req.param("name").?;

    // the last parameter to res.json is an std.json.StringifyOptions
    try res.json(.{ .hello = name }, .{});
}

fn writer(req: *httpz.Request, res: *httpz.Response) !void {
    res.content_type = httpz.ContentType.JSON;

    const name = req.param("name").?;
    var ws = std.json.writeStream(res.writer(), .{ .whitespace = .indent_4 });
    try ws.beginObject();
    try ws.objectField("name");
    try ws.write(name);
    try ws.endObject();
}

fn metrics(_: *httpz.Request, res: *httpz.Response) !void {
    // httpz exposes some prometheus-style metrics
    return httpz.writeMetrics(res.writer());
}

fn formShow(_: *httpz.Request, res: *httpz.Response) !void {
    res.body =
        \\ <html>
        \\ <form method=post>
        \\    <p><input name=name value=goku></p>
        \\    <p><input name=power value=9001></p>
        \\    <p><input type=submit value=submit></p>
        \\ </form>
    ;
}

fn formPost(req: *httpz.Request, res: *httpz.Response) !void {
    var it = (try req.formData()).iterator();

    res.content_type = .TEXT;

    const w = res.writer();
    while (it.next()) |kv| {
        try std.fmt.format(w, "{s}={s}\n", .{ kv.key, kv.value });
    }
}

fn explicitWrite(_: *httpz.Request, res: *httpz.Response) !void {
    res.body =
        \\ There may be cases where your response is tied to data which
        \\ required cleanup. If `res.arena` and `res.writer()` can't solve
        \\ the issue, you can always call `res.write()` explicitly
    ;
    return res.write();
}

const APIError = error{
    DBError,
};
// Use arena allocator to avoid mem copy
pub fn fromDB(allocator: Allocator) !?[]u8 {
    const db = try sql.DB.init(allocator, .{
        .database = "",
        .host = "172.17.0.1",
        .user = "root",
        .password = "my-secret-pw",
    });
    const query = "SELECT 'hello world' as greeting;";
    const params = .{};
    const rs = try db.runPreparedStatement(allocator, query, params);

    if (rs.rows.items.len == 1) {
        return rs.rows.items[0].columns.items[0].?;
    } else {
        return null;
    }
    return APIError.DBError;
}

var testdb: sql.DB = undefined;

test "connect" {
    testdb = try sql.DB.init(std.testing.allocator, .{
        .database = "",
        .host = "172.17.0.1",
        .user = "root",
        .password = "my-secret-pw",
    });
}

test "simple select prepared statement" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    const query = "SELECT 'just a happy test';";
    const params = .{};
    const rs = try testdb.runPreparedStatement(allocator, query, params);
    try std.testing.expectEqualStrings("just a happy test", rs.rows.items[0].columns.items[0].?);
}

test "hello fetch" {
    var wt = ht.init(.{});
    defer wt.deinit();
    try hello(wt.req, wt.res);
    try wt.expectStatus(200);
}
