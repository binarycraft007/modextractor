const std = @import("std");
const c = @import("c");
const mem = std.mem;
const kmod = @import("kmod");
const firmwares_raw = @embedFile("firmwares");

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

    var fw_base_dirs: std.BufSet = .init(arena);
    defer fw_base_dirs.deinit();

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

    var modules_file = try std.fs.createFileAbsolute("/etc/initramfs-tools/modules", .{});
    defer modules_file.close();

    var modules_bw = modules_file.writer(&buffer);
    const modules_writer = &modules_bw.interface;

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
                try files.insert(try arena.dupe(u8, info.value()));
            }
        }
        try modules_writer.print("{s}\n", .{mod_name.*});
    }

    try modules_writer.flush();

    var firmwares_file = try std.fs.createFileAbsolute("/etc/initramfs-tools/hooks/firmwares", .{ .mode = 0o755 });
    defer firmwares_file.close();

    var firmwares_bw = firmwares_file.writer(&buffer);
    const firmwares_writer = &firmwares_bw.interface;

    try firmwares_writer.writeAll(firmwares_raw);

    var files_it = files.iterator();
    while (files_it.next()) |file| {
        const fw_base_dir = std.fs.path.dirname(file.*).?;
        if (!fw_base_dirs.contains(fw_base_dir)) {
            try fw_base_dirs.insert(fw_base_dir);
            try addFirmwaresFromBase(std.heap.page_allocator, firmwares_writer, fw_base_dir, &files);
        }
        try firmwares_writer.print("add_firmware {s}\n", .{file.*});
    }

    try firmwares_writer.flush();
}

fn fatal(comptime format: []const u8, args: anytype) noreturn {
    std.debug.print(format, args);
    std.process.exit(1);
}

fn addFirmwaresFromBase(gpa: mem.Allocator, w: *std.Io.Writer, fw_base_dir: []const u8, files: *std.BufSet) !void {
    const base_dir_path = try std.fs.path.join(gpa, &.{ "/lib/firmware", fw_base_dir });
    defer gpa.free(base_dir_path);

    var dir = try std.fs.openDirAbsolute(base_dir_path, .{ .iterate = true });
    defer dir.close();

    var walker = try dir.walk(gpa);
    defer walker.deinit();

    while (try walker.next()) |entry| {
        switch (entry.kind) {
            .file => {
                const path = try std.fs.path.join(gpa, &.{ fw_base_dir, entry.path });
                defer gpa.free(path);
                if (!files.contains(path)) try w.print("add_firmware {s}\n", .{path});
            },
            else => {},
        }
    }
}

const Options = struct {
    dtb_path: []const u8,
    kmod_ctx: *kmod.Context,
    modules: *std.BufSet,
    files: *std.BufSet,
};

const blacklist = [_][]const u8{
    "/drm/",
    "bluetooth",
    "soundwire",
};

fn isInBlacklist(path: []const u8) bool {
    for (blacklist) |pattern| {
        if (mem.containsAtLeast(u8, path, 1, pattern)) {
            return true;
        }
    }
    return false;
}

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
                    if (isInBlacklist(mod.path().?)) continue :outer;
                    try options.modules.insert(try arena.dupe(u8, mod.name()));
                }
            }
        }
        if (c.fdt_getprop(fdt.ptr, offset, "firmware-name", null)) |firmware_name| {
            const str_ptr: [*:0]const u8 = @ptrCast(@alignCast(firmware_name));
            const str = mem.sliceTo(str_ptr, 0);
            try options.files.insert(try arena.dupe(u8, str));
        }
    }
}
