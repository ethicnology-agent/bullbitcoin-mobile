# SP (Silent Payments) Development

## 1. Toolchains

| Tool | Version | Install |
|---|---|---|
| Rust | 1.100.0 (pinned by native hooks) | `rustup toolchain install 1.100.0 --profile minimal --no-self-update` |
| Flutter | 3.50.0 via fvm (pinned in `.fvmrc`) | `fvm install` in repo root |
| Dart | bundled with Flutter (SDK 3.14.0, per `pubspec.yaml`) | comes with Flutter |
| Java | >= 17 (JDK 21 matches `android.jvmTarget`) | system package manager or [SDKMAN](https://sdkman.io) |
| Android SDK | `compileSdk` 36 | Android Studio SDK Manager |
| Android NDK | `29.0.14206865` (see `android/gradle.properties`) | Android Studio SDK Manager |

The bwk bindings the SP feature calls come from the `bull_sdk` package (see `pubspec.yaml`), not a local crate. Flutter Rust Bridge 2.13 Native Assets hooks compile its aggregate Rust library (`rust_lib_bull_sdk`). Each native crate declares its exact compiler in `rust-toolchain.toml`; `make` exports the matching `RUSTUP_TOOLCHAIN` and disables automatic toolchain installation. Install the compiler and required Android target before building.

`bull_sdk` and its capability packages use immutable Git references in the workspace manifests and root lockfile. Keep those references aligned when updating the SDK; the app no longer uses a Silent Payments dependency override or the CargoKit `rust_builder` plugin.

Run `make fvm-check` to install the pinned Flutter, then `make deps` to fetch dependencies before starting.

## 2. Environment Variables

| Variable | Required? | Default / fallback | Used by |
|---|---|---|---|
| `ANDROID_HOME` | Yes | none, must be set and point to a real dir | Android Gradle build, NDK lookup |
| `JAVA_HOME` | No | derived from `java` on PATH | Gradle (only when not on PATH) |
| `PATH` | Yes, must contain `fvm` and `~/.cargo/bin` | system-default + shell rc | every Flutter/cargo command |

**`ANDROID_HOME`** - if unset or pointing to a non-existent directory, Gradle falls back to scanning common locations and usually fails with a confusing `SDK location not found` error during the Android build step. Set it to the directory containing `platforms/`, `platform-tools/`, and `ndk/`.

Flutter supplies the Android NDK compiler to Native Assets hooks. Install the NDK version listed in `android/gradle.properties` via Android Studio's SDK Manager.

**`JAVA_HOME`** - Gradle can usually locate Java from PATH, but when multiple JDKs are installed the wrong one may be picked. Setting `JAVA_HOME` explicitly avoids version mismatches. Leave unset if only one JDK is installed and it reports the expected major version.

**`PATH`** - must include the `fvm` binary and `~/.cargo/bin`. Missing entries surface immediately as `command not found` for `fvm` or `cargo`.

## 3. Verifying a Change

There is no SP-specific make target. `make checks` is the local entry point: it runs the strict `analyze` (`--fatal-warnings --fatal-infos`), the formatting and `dart fix` checks, and `make unit-test`, which is the same set CI runs in the `analyze_and_test.yml` workflow on every PR.

## 4. Tests and the Scan Policy

The SP suite needs no native libraries. `make unit-test` picks up the SP tests under `test/features/sp/` along with the rest of the project.

Scanning resumes on its own during a sync tick, but only through `SyncSpWalletUsecase`, and only when `spScanTrigger` says so: a wallet with no cursor yet, or one more than about a month behind the tip, stays on the manual path until the user acts.

That confinement is enforced by the type system rather than by a grep. `scanOnce` lives alone on `SpScanPort`, and the locator hands that port to `ScanSpWalletUsecase` and nothing else, so no other class can reach the Rust scan without a visible change to the composition root. `sp_locator_scan_policy_test.dart` covers the behaviour on top of that: it boots the real locator graph with only the outbound ports faked and counts every `scanOnce` that reaches the boundary.

## 5. Reproducible Build

The reproducible APK/AAB build runs in a container via `make android`; see `reproducibility/README.md`. It is a separate lane. `make checks` never invokes it, and developers do not need it for day-to-day SP work.
