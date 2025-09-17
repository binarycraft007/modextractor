const std = @import("std");
const c = @import("c");
const mem = std.mem;
const kmod = @import("kmod");

const binaries = "BINARIES=()\n\n";
const hooks = "HOOKS=(base udev autodetect modconf keyboard keymap consolefont block filesystems fsck)\n";

pub fn main() !void {
    var arena_state: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer arena_state.deinit();

    const arena = arena_state.allocator();

    var args = try std.process.argsWithAllocator(arena);
    defer args.deinit();

    var opt_dtb_files: std.ArrayList([]const u8) = .empty;
    defer opt_dtb_files.deinit(arena);

    _ = args.skip();
    const module_path = args.next() orelse fatal("expected first arg to be module path", .{});
    while (args.next()) |arg| {
        try opt_dtb_files.append(arena, arg);
    }

    const dtb_files = if (opt_dtb_files.items.len > 0)
        opt_dtb_files.items
    else
        fatal("module path should be followed by at least one dtb file", .{});

    var modules: std.BufSet = .init(arena);
    defer modules.deinit();

    var files: std.BufSet = .init(arena);
    defer files.deinit();

    var kmod_ctx: kmod.Context = try .init(.{ .dirname = module_path, .load_resources = true });
    defer kmod_ctx.deinit();

    for (dtb_files) |dtb_file| {
        findModulesInDtb(&arena_state, .{
            .dtb_path = dtb_file,
            .kmod_ctx = &kmod_ctx,
            .modules = &modules,
            .files = &files,
        }) catch |err| switch (err) {
            error.InvalidFdtFile => continue,
            else => |e| return e,
        };
    }

    var buffer: [8 * 1024]u8 = undefined;
    var bw = std.fs.File.stdout().writer(&buffer);
    const stdout = &bw.interface;

    try stdout.writeAll("MODULES=(\n");
    var it = modules.iterator();
    while (it.next()) |mod_name| {
        const name = try std.heap.page_allocator.dupeZ(u8, mod_name.*);
        defer std.heap.page_allocator.free(name);
        var mod = try kmod_ctx.newModFromName(name);
        defer mod.deinit();
        var info_it = try mod.info();
        defer info_it.deinit();
        while (info_it.next()) |info| {
            if (mem.eql(u8, info.key(), "firmware")) {
                const firmware_path = try std.fs.path.join(arena, &.{ "/lib/firmware", info.value() });
                try files.insert(firmware_path);
            }
        }
        try stdout.print("    {s}\n", .{mod_name.*});
    }
    try stdout.writeAll(")\n\n");

    try stdout.writeAll(binaries);

    try stdout.writeAll("FILES=(\n");
    var files_it = files.iterator();
    while (files_it.next()) |file| {
        try stdout.print("    {s}\n", .{file.*});
    }
    try stdout.writeAll(")\n\n");

    try stdout.writeAll(hooks);

    try stdout.flush();
}

fn fatal(comptime format: []const u8, args: anytype) noreturn {
    std.debug.print(format, args);
    std.process.exit(1);
}

const Options = struct {
    dtb_path: []const u8,
    kmod_ctx: *kmod.Context,
    modules: *std.BufSet,
    files: *std.BufSet,
};

fn findModulesInDtb(arena_state: *std.heap.ArenaAllocator, options: Options) !void {
    const gpa = arena_state.child_allocator;
    const arena = arena_state.allocator();
    var buffer: [8 * 1024]u8 = undefined;
    var fdt_file = try std.fs.cwd().openFile(options.dtb_path, .{});
    defer fdt_file.close();

    var fdt_reader = fdt_file.reader(&buffer);
    const reader = &fdt_reader.interface;

    var allocating: std.Io.Writer.Allocating = .init(gpa);
    defer allocating.deinit();

    _ = try reader.streamRemaining(&allocating.writer);
    try allocating.writer.flush();

    const fdt = try allocating.toOwnedSliceSentinel(0);
    defer gpa.free(fdt);

    if (c.fdt_check_header(fdt.ptr) != 0) return error.InvalidFdtFile;

    var offset: c_int = c.fdt_next_node(fdt.ptr, -1, null);
    outer: while (offset >= 0) : (offset = c.fdt_next_node(fdt.ptr, offset, null)) {
        var len: c_int = 0;
        if (c.fdt_getprop(fdt.ptr, offset, "compatible", &len)) |ptr| {
            var compatibles: [*]u8 = @ptrCast(@alignCast(@constCast(ptr)));
            var compatible: [:0]u8 = @ptrCast(compatibles[0..@intCast(len)]);
            inner: while (compatible.len > 0) : ({
                compatible = compatible[mem.len(compatible.ptr) + 1 ..];
            }) {
                var buf: [512]u8 = undefined;
                const modalias = try std.fmt.bufPrintZ(&buf, "of:N*T*C{s}", .{compatible});
                var it = options.kmod_ctx.lookup(modalias) catch continue :inner;
                defer it.deinit();
                while (it.next()) |mod| {
                    // blacklist adsp/cdsp firmwares
                    if (mem.containsAtLeast(u8, mod.path().?, 1, "remoteproc")) {
                        continue :outer;
                    }
                    try options.modules.insert(try arena.dupe(u8, mod.name()));
                }
            }
        }
        if (c.fdt_getprop(fdt.ptr, offset, "firmware-name", null)) |firmware_name| {
            const str_ptr: [*:0]const u8 = @ptrCast(@alignCast(firmware_name));
            const str = mem.sliceTo(str_ptr, 0);
            const firmware_path = try std.fs.path.join(arena, &.{ "/lib/firmware", str });
            try options.files.insert(firmware_path);
        }
    }
}
