# Releasing the Android app

## Identity

| | |
|---|---|
| Application ID | `com.nimbus.drive` |
| Label | Nimbus Drive |
| Version | `pubspec.yaml` → `version: 1.0.0+1` (name+code) |

**The application ID is permanent.** Once a build is on Play under
`com.nimbus.drive`, it can never be changed — a different ID is a different app,
with no upgrade path and no shared reviews. Change it now or not at all.

---

## Signing

`android/key.properties` points at the keystore and holds its passwords. Both
are gitignored, and `android/app/build.gradle.kts` falls back to the debug key
when the file is absent so a fresh clone still builds.

The keystore currently in the repo working tree was generated for development.
**Before publishing, make your own:**

```bash
cd mobile/android
keytool -genkeypair -v -keystore nimbus-release.jks \
  -keyalg RSA -keysize 4096 -validity 10000 -alias nimbus
```

Then update `key.properties`:

```properties
storeFile=nimbus-release.jks
storePassword=<yours>
keyAlias=nimbus
keyPassword=<yours>
```

> **Back the keystore up somewhere you will still have in five years.** Losing
> it means you can never publish an update to the listing — Play identifies an
> app by its signing key, and there is no recovery process. Opting into Play App
> Signing at first upload is the usual insurance.

---

## Building

The API host is compiled in, so it must be supplied:

```bash
flutter build apk --release \
  --dart-define=NIMBUS_API_BASE=https://your-server/api
```

Omitting it bakes in the `127.0.0.1` development default, which on a phone
means the phone itself — the app installs and every request fails.

| Target | Command | Notes |
|---|---|---|
| Play Store | `flutter build appbundle --release --dart-define=...` | Play requires an AAB |
| Sideload | `flutter build apk --release --split-per-abi --dart-define=...` | ~18–21 MB each |
| One APK for everything | `flutter build apk --release --dart-define=...` | ~53 MB, all ABIs |

Outputs land in `build/app/outputs/`.

### Verifying a build

```bash
BT=$(ls -d ~/Android/Sdk/build-tools/* | sort -V | tail -1)
"$BT/aapt2" dump badging app-release.apk | grep -E "^package|label|permission"
"$BT/apksigner" verify --print-certs app-release.apk
```

Check the package is `com.nimbus.drive`, that `android.permission.INTERNET` is
listed, and that the signer is *not* "Android Debug".

---

## Toolchain notes

Two things about this project's Gradle setup are deliberate, and reverting
either breaks the build in a way that does not name its own cause.

**AGP is pinned to 8.9.1, not 9.x.** Under AGP 9 any plugin that applies its own
Kotlin Gradle plugin — `file_picker` and `cryptography_flutter` both do —
compiles to an *empty jar*. The build then fails at the app's
`GeneratedPluginRegistrant` with "cannot find symbol FilePickerPlugin", which
reads like a missing dependency rather than a plugin that silently compiled
nothing. Revisit when those plugins ship built-in-Kotlin support.

**Gradle needs a real JDK on the toolchain path.** Its auto-detection scans
`/usr/lib/jvm` and will happily select a JRE, failing with "does not provide the
required capabilities: [JAVA_COMPILER]". If that appears, pin one in
`~/.gradle/gradle.properties` (a user file, not the repo):

```properties
org.gradle.java.home=/usr/lib/jvm/java-21-openjdk
```

---

## Before the first upload

- [ ] Replace the development keystore, and back it up
- [ ] Point `NIMBUS_API_BASE` at a real HTTPS host
- [ ] Bump `version:` in `pubspec.yaml` for every upload — Play rejects a
      duplicate version code
- [ ] Privacy policy URL. The app uploads user files to a Telegram channel the
      user owns; Play's Data Safety form needs that described
- [ ] Test on a physical device: bind a channel, upload, download, decrypt
