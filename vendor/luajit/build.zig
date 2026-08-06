//! LuaJIT 2.1 static build — LUA-01 (ISS-0161 / GH #485).
//!
//! LUA-01 requires the interpreter be linked STATICALLY: "The platform binary
//! depends on no external Lua shared library at runtime." This produces a
//! static archive with no shared-library dependency.
//!
//! ## Why this is not just addCSourceFiles
//!
//! LuaJIT cannot be compiled by listing its .c files. It has a three-stage
//! bootstrap that generates required headers and the VM object first:
//!
//!   1. minilua        — a stripped Lua interpreter, built from one .c file.
//!   2. dynasm         — minilua runs dynasm.lua to turn vm_x64.dasc (the VM
//!                       written in DynASM assembly) into host/buildvm_arch.h.
//!   3. buildvm        — compiled against that header, then RUN five times to
//!                       emit lj_vm.obj (the VM itself) plus lj_bcdef.h,
//!                       lj_ffdef.h, lj_libdef.h and lj_recdef.h.
//!
//! Only then can the ~60 lj_*.c core files compile. Each stage's output is the
//! next stage's input, so the steps are strictly ordered.
//!
//! ## Two toolchain workarounds, both established empirically
//!
//! **(a) The upstream Makefile cannot drive this here.** GNU Make 3.81 (the
//! version on this host) fails with `CreateProcess(NULL, host/minilua.exe ...)
//! failed / e=2` when invoking a just-built relative-path executable on
//! Windows. The identical command run directly from a shell succeeds. Driving
//! the bootstrap from build.zig — which invokes artifacts by absolute path —
//! sidesteps it entirely. This is why the build is reimplemented here rather
//! than shelling out to `make`.
//!
//! **(b) buildvm must be compiled with UBSan off.** DynASM's dasm_x86.h:143
//! does `D->sections[i].buf - D->sections[i].pos` where `buf` is NULL during
//! setup. That is undefined behaviour, and Zig's clang traps it by default:
//! buildvm.exe panics with "applying non-zero offset ... to null pointer" and
//! generates nothing. `-fno-sanitize=undefined` restores upstream C semantics.
//! This applies ONLY to the host-side buildvm tool, never to the library.
const std = @import("std");

/// Build LuaJIT as a static library and return it.
///
/// The caller links this and adds `luajitIncludePath()` to its include path.
pub fn addLuaJit(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Step.Compile {
    const src = "vendor/luajit/src/";

    // The host tools (minilua, buildvm) must run on the BUILD machine, so they
    // are always compiled for the host, never for `target`.
    const host_target = b.resolveTargetQuery(.{});

    // ---- Stage 1: minilua ---------------------------------------------------
    const minilua = b.addExecutable(.{
        .name = "minilua",
        .root_module = b.createModule(.{
            .target = host_target,
            .optimize = .ReleaseSafe,
            .link_libc = true,
        }),
    });
    minilua.root_module.addCSourceFile(.{
        .file = b.path(src ++ "host/minilua.c"),
        .flags = &.{"-fno-sanitize=undefined"},
    });
    minilua.root_module.addIncludePath(b.path(src));
    if (target.result.os.tag != .windows) minilua.root_module.linkSystemLibrary("m", .{});

    // ---- Stage 1b: genversion -> luajit.h -----------------------------------
    // luajit.h is NOT in the source tree: it is generated from
    // luajit_rolling.h + luajit_relver.txt by host/genversion.lua. buildvm.c
    // includes it, so this must run before stage 3. (This is the step the
    // upstream Makefile does under the `VERSION` label — the first place its
    // relative-path CreateProcess failure bites on this host.)
    const genversion = b.addRunArtifact(minilua);
    genversion.addFileArg(b.path(src ++ "host/genversion.lua"));
    genversion.addFileArg(b.path(src ++ "luajit_rolling.h"));
    genversion.addFileArg(b.path(src ++ "luajit_relver.txt"));
    const luajit_h = genversion.addOutputFileArg("luajit.h");

    // ---- Stage 2: dynasm -> host/buildvm_arch.h -----------------------------
    // Flags mirror the upstream Makefile's x64 configuration. P64 = 64-bit
    // pointers; JIT/FFI = compile in the JIT compiler and FFI library;
    // FPU/HFABI = hardware floating point.
    const dynasm = b.addRunArtifact(minilua);
    dynasm.addFileArg(b.path("vendor/luajit/dynasm/dynasm.lua"));
    dynasm.addArgs(&.{ "-D", "ENDIAN_LE", "-D", "P64", "-D", "JIT", "-D", "FFI", "-D", "FPU", "-D", "HFABI", "-D", "VER=" });
    if (target.result.os.tag == .windows) dynasm.addArgs(&.{ "-D", "WIN" });
    dynasm.addArg("-o");
    const buildvm_arch_h = dynasm.addOutputFileArg("buildvm_arch.h");
    dynasm.addFileArg(b.path(src ++ "vm_x64.dasc"));

    // ---- Stage 3: buildvm ---------------------------------------------------
    const buildvm = b.addExecutable(.{
        .name = "buildvm",
        .root_module = b.createModule(.{
            .target = host_target,
            .optimize = .ReleaseSafe,
            .link_libc = true,
        }),
    });
    buildvm.root_module.addCSourceFiles(.{
        .root = b.path(src ++ "host"),
        .files = &.{ "buildvm.c", "buildvm_asm.c", "buildvm_peobj.c", "buildvm_lib.c", "buildvm_fold.c" },
        // See workaround (b) in this file's header comment: without this,
        // buildvm panics inside DynASM instead of producing output.
        .flags = &.{"-fno-sanitize=undefined"},
    });
    buildvm.root_module.addIncludePath(b.path(src));
    buildvm.root_module.addIncludePath(b.path(src ++ "host"));
    // buildvm_arch.h is generated, so its directory must be on the include path.
    buildvm.root_module.addIncludePath(buildvm_arch_h.dirname());
    buildvm.root_module.addIncludePath(luajit_h.dirname());

    // The library sources buildvm scans to emit the def headers. Order matches
    // the upstream Makefile's ALL_LIB — buildvm assigns library IDs by
    // position, so this list must not be reordered.
    const lib_sources = [_][]const u8{
        "lib_base.c", "lib_math.c",   "lib_bit.c",    "lib_string.c", "lib_table.c",
        "lib_io.c",   "lib_os.c",     "lib_package.c", "lib_debug.c",  "lib_jit.c",
        "lib_ffi.c",  "lib_buffer.c",
    };

    // buildvm -m peobj -> lj_vm.obj (the VM machine code itself)
    const vm_mode = if (target.result.os.tag == .windows)
        "peobj"
    else if (target.result.os.tag == .macos)
        "machasm"
    else
        "elfasm";
    const gen_vm = b.addRunArtifact(buildvm);
    gen_vm.addArgs(&.{ "-m", vm_mode, "-o" });
    const lj_vm_obj = gen_vm.addOutputFileArg(
        if (target.result.os.tag == .windows) "lj_vm.obj" else "lj_vm.S",
    );

    // buildvm -m {bcdef,ffdef,libdef,recdef} -> four generated headers, each
    // produced by scanning the lib_*.c sources.
    var gen_headers: [5]std.Build.LazyPath = undefined;
    inline for (.{ "bcdef", "ffdef", "libdef", "recdef" }, 0..) |mode, i| {
        const run = b.addRunArtifact(buildvm);
        run.addArgs(&.{ "-m", mode, "-o" });
        gen_headers[i] = run.addOutputFileArg("lj_" ++ mode ++ ".h");
        for (lib_sources) |f| run.addFileArg(b.path(b.fmt("{s}{s}", .{ src, f })));
    }

    // lj_folddef.h is the fifth generated header and is produced differently:
    // it scans lj_opt_fold.c (the fold-rule table), not the lib_*.c sources.
    const gen_folddef = b.addRunArtifact(buildvm);
    gen_folddef.addArgs(&.{ "-m", "folddef", "-o" });
    gen_headers[4] = gen_folddef.addOutputFileArg("lj_folddef.h");
    gen_folddef.addFileArg(b.path(src ++ "lj_opt_fold.c"));

    // ---- The library --------------------------------------------------------
    const lib = b.addLibrary(.{
        .name = "luajit",
        .linkage = .static, // LUA-01: static linking is a MUST.
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });

    // Core VM, JIT compiler, and standard libraries.
    lib.root_module.addCSourceFiles(.{
        .root = b.path(src),
        .files = &(core_sources ++ lib_sources),
        .flags = &.{
            "-D_FILE_OFFSET_BITS=64",
            "-D_LARGEFILE_SOURCE",
            "-DLUAJIT_UNWIND_EXTERNAL",
            // Upstream builds the amalgamated core without UBSan; several
            // hot paths rely on wrapping arithmetic and tagged-pointer tricks
            // that trap otherwise. Same rationale as workaround (b).
            "-fno-sanitize=undefined",
        },
    });

    lib.root_module.addIncludePath(b.path(src));
    // The generated headers each land in their own cache directory, so every
    // one of them must be added individually.
    for (gen_headers) |h| lib.root_module.addIncludePath(h.dirname());
    lib.root_module.addIncludePath(buildvm_arch_h.dirname());
    lib.root_module.addIncludePath(luajit_h.dirname());

    // Link the generated VM object. On non-Windows this is assembly that Zig
    // assembles; on Windows it is already a COFF object.
    if (target.result.os.tag == .windows) {
        lib.root_module.addObjectFile(lj_vm_obj);
    } else {
        lib.root_module.addAssemblyFile(lj_vm_obj);
    }

    // Make the generated inputs true build-graph dependencies so a clean build
    // orders the stages correctly rather than racing them.
    lib.step.dependOn(&gen_vm.step);

    return lib;
}

/// Include path for lua.h / lualib.h / lauxlib.h / luajit.h.
pub fn luajitIncludePath(b: *std.Build) std.Build.LazyPath {
    return b.path("vendor/luajit/src");
}

/// LuaJIT core .c files (everything except the lib_*.c standard libraries).
const core_sources = [_][]const u8{
    "lj_assert.c",  "lj_gc.c",       "lj_err.c",      "lj_char.c",    "lj_bc.c",
    "lj_obj.c",     "lj_buf.c",      "lj_str.c",      "lj_tab.c",     "lj_func.c",
    "lj_udata.c",   "lj_meta.c",     "lj_debug.c",    "lj_prng.c",    "lj_state.c",
    "lj_dispatch.c", "lj_vmevent.c", "lj_vmmath.c",   "lj_strscan.c", "lj_strfmt.c",
    "lj_strfmt_num.c", "lj_serialize.c", "lj_api.c",  "lj_profile.c", "lj_lex.c",
    "lj_parse.c",   "lj_bcread.c",   "lj_bcwrite.c",  "lj_load.c",    "lj_ir.c",
    "lj_opt_mem.c", "lj_opt_fold.c", "lj_opt_narrow.c", "lj_opt_dce.c", "lj_opt_loop.c",
    "lj_opt_split.c", "lj_opt_sink.c", "lj_mcode.c",  "lj_snap.c",    "lj_record.c",
    "lj_crecord.c", "lj_ffrecord.c", "lj_asm.c",      "lj_trace.c",   "lj_gdbjit.c",
    "lj_ctype.c",   "lj_cdata.c",    "lj_cconv.c",    "lj_ccall.c",   "lj_ccallback.c",
    "lj_carith.c",  "lj_clib.c",     "lj_cparse.c",   "lj_lib.c",     "lj_alloc.c",
    "lib_aux.c",    "lib_init.c",
};
