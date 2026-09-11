/// Identifies the build, so a screenshot can answer "which APK is this?".
///
/// Sideloaded APKs are easy to confuse — same icon, same name, no version shown
/// anywhere in the UI. That cost real debugging time once: a layout bug that had
/// already been fixed was reported again from a stale install, and there was no
/// way to tell from the screenshot which build produced it.
///
/// Bump this by hand when producing a build for testing. It is deliberately not
/// read from the package version: `versionName` stays `1.0.0` across a dozen test
/// builds, which is exactly the ambiguity this exists to remove.
const String kBuildStamp = 'build 4 · 2026-09-07';
