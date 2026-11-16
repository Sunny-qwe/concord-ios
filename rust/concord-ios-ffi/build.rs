// build.rs — placeholder.
// TODO: if/when the real Concord crates are added, this is where iOS-specific
// build configuration belongs (e.g. BoringSSL / iphoneos SDK handling).
// BoringSSL under the iphoneos SDK is UNVERIFIED for Concord — see README.md.
// Do not assume `cargo build --target aarch64-apple-ios` will just work
// once Concord is added as a dependency.
fn main() {
    // No-op for the stub crate.
}
