# R8 rules for the release build.
#
# Flutter ships its own rules for the engine, and most plugins ship theirs via
# `consumer-rules.pro`. What is left is the handful of places where reflection
# or native lookups mean R8 cannot see a usage.

# Flutter's deferred-component machinery is referenced reflectively. Unused
# here, but stripping it produces a warning storm rather than a clean build.
-dontwarn io.flutter.embedding.engine.deferredcomponents.**

# Tink backs cryptography_flutter's AES-GCM. It resolves primitives by name, so
# renaming them breaks key derivation at runtime — long after the build passed.
-keep class com.google.crypto.tink.** { *; }
-dontwarn com.google.crypto.tink.**

# Conscrypt is an optional TLS provider that okhttp/Tink probe for. It is not
# bundled, so the reference is expected to be missing.
-dontwarn org.conscrypt.**
-dontwarn org.bouncycastle.**
-dontwarn org.openjsse.**

# Kotlin coroutines' internals are looked up by name in a few places.
-keepclassmembers class kotlinx.coroutines.** { volatile <fields>; }
-dontwarn kotlinx.coroutines.**

# flutter_secure_storage reaches the Android keystore through androidx.security,
# which resolves classes by name. Obfuscating them makes the very first call
# throw — and that call happens during startup, before any screen can report it.
-keep class androidx.security.crypto.** { *; }
-dontwarn androidx.security.crypto.**
-keep class com.it_nomads.fluttersecurestorage.** { *; }

# file_picker resolves its Android delegate reflectively through the plugin
# registrant.
-keep class com.mr.flutter.plugin.filepicker.** { *; }
