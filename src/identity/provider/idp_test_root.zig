//! Test root for `src/identity/provider/bootstrap.zig` (3 in-file test blocks).
//!
//! ISS-0137 / GH #439. bootstrap.zig was reachable only as a member of
//! `identity_provider_mod`, never from an addTest root, so its tests never ran.
//!
//! Single-Owner Module Rule (design §1.2): reached by **relative** path, which
//! is correct here because bootstrap.zig is not itself a module root
//! (`src/identity/provider/mod.zig` is). Placement at `src/identity/provider/`
//! is verified safe: bootstrap.zig reaches manager.zig,
//! adapters/keycloak/provider.zig and adapters/stub/provider.zig — all at or
//! below this directory, so nothing escapes this module root.
//!
//! `@import("root")` contract: bootstrap.zig line 3 does
//! `const root = @import("root");`, which resolves to whichever file is the
//! addTest root — i.e. this shim. Verified by reading bootstrap.zig: `root` is
//! referenced ONLY inside an `@hasDecl(root, "idp_config")` guard, so this shim
//! needs to declare nothing; the guard simply takes its false branch and
//! bootstrap.zig falls through to its `@import("idp_config")` named module.
//!
//! `.link_libc = true` required — this target transitively reaches src/env.zig
//! via both `env` and `idp_config` (ISS-0134).
//!
//! Run via `zig build test-idp-bootstrap` (also reached by `zig build test`).

const std = @import("std");

pub const bootstrap = @import("bootstrap.zig");

test {
    std.testing.refAllDecls(bootstrap);
}
