import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:hive_ce/hive.dart';

/// Minimal read/write surface over the platform secure store, kept as an
/// interface so tests can substitute an in-memory fake instead of driving a
/// MethodChannel.
abstract interface class SecureKeyStorage {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
}

/// Production backend: `flutter_secure_storage` (Android Keystore /
/// EncryptedSharedPreferences, iOS Keychain). The raw key bytes never touch
/// SharedPreferences or any other plaintext store.
class FlutterSecureKeyStorage implements SecureKeyStorage {
  const FlutterSecureKeyStorage([
    this._storage = const FlutterSecureStorage(),
  ]);

  final FlutterSecureStorage _storage;

  @override
  Future<String?> read(String key) => _storage.read(key: key);

  @override
  Future<void> write(String key, String value) =>
      _storage.write(key: key, value: value);
}

/// In-memory fake for tests and for environments without a platform channel.
class InMemorySecureKeyStorage implements SecureKeyStorage {
  final Map<String, String> _values = {};

  @override
  Future<String?> read(String key) async => _values[key];

  @override
  Future<void> write(String key, String value) async {
    _values[key] = value;
  }
}

/// Key file in the app's private data directory, readable only by the user.
///
/// This is the macOS development fallback for when the Keychain is not
/// available: an ad-hoc signed sandboxed app has no
/// `keychain-access-groups` entitlement that the system can validate, so
/// flutter_secure_storage's SecItem calls fail with
/// errSecMissingEntitlement (-34018). A 0600 file in the sandbox container is
/// still private to the user and keeps local Hive boxes encrypted; once the
/// app is signed with a Developer ID team, [KeychainThenFileStorage] uses the
/// Keychain again and this file is only consulted for migration.
class MacOSFileKeyStorage implements SecureKeyStorage {
  MacOSFileKeyStorage({Future<Directory> Function()? supportDirectory})
    : _supportDirectory = supportDirectory ?? getApplicationSupportDirectory;

  final Future<Directory> Function() _supportDirectory;

  Future<File> _keyFile(String key) async {
    final support = await _supportDirectory();
    final directory = Directory('${support.path}/keys');
    await directory.create(recursive: true);
    final safeName = key.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
    return File('${directory.path}/$safeName');
  }

  @override
  Future<String?> read(String key) async {
    try {
      final file = await _keyFile(key);
      if (!await file.exists()) return null;
      final value = (await file.readAsString()).trim();
      return value.isEmpty ? null : value;
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> write(String key, String value) async {
    final file = await _keyFile(key);
    final temporary = File('${file.path}.tmp');
    await temporary.writeAsString(value, flush: true);
    try {
      await temporary.rename(file.path);
    } on FileSystemException {
      await file.writeAsString(value, flush: true);
    }
    try {
      await Process.run('chmod', ['600', file.path]);
    } catch (_) {
      // Best effort: the container is already only accessible to this user.
    }
  }
}

/// Keychain-first storage with a macOS file fallback for unsigned dev builds.
class KeychainThenFileStorage implements SecureKeyStorage {
  KeychainThenFileStorage({
    SecureKeyStorage? keychain,
    SecureKeyStorage? fallback,
  }) : _keychain = keychain ?? const FlutterSecureKeyStorage(),
       _fallback = fallback ?? MacOSFileKeyStorage();

  final SecureKeyStorage _keychain;
  final SecureKeyStorage _fallback;

  @override
  Future<String?> read(String key) async {
    try {
      final value = await _keychain.read(key);
      if (value != null && value.isNotEmpty) return value;
    } catch (_) {
      // Fall through to the file store.
    }
    return _fallback.read(key);
  }

  @override
  Future<void> write(String key, String value) async {
    try {
      await _keychain.write(key, value);
      return;
    } catch (_) {
      await _fallback.write(key, value);
    }
  }
}

/// Secure storage for the current platform.
///
/// macOS uses the Keychain when the build is signed with a team that can
/// validate `keychain-access-groups`, and transparently falls back to the
/// sandbox-private key file for ad-hoc local builds. All other platforms keep
/// using flutter_secure_storage directly.
SecureKeyStorage defaultSecureKeyStorage() {
  if (!kIsWeb && Platform.isMacOS) {
    return KeychainThenFileStorage();
  }
  return const FlutterSecureKeyStorage();
}

/// Owns the random 256-bit keys that encrypt local data at rest.
///
/// One key per purpose, all base64-encoded in secure storage:
/// - [hiveBoxKeyName]: the Hive `HiveAesCipher` key for every encrypted box
///   (see `EncryptedHive`);
/// - [devicePoolKeyName]: the Rust device-pool file key, handed to the core
///   via the `set_device_pool_key` FRB call at startup (P1-2). Sharing the
///   infrastructure but not the key material: compromising one store must not
///   open the other.
///
/// A missing entry is created once (random 256-bit via
/// `Hive.generateSecureKey`) and persisted; a present-but-malformed entry is
/// treated as a lost key and replaced, which makes the boxes encrypted under
/// the old key unreadable — `EncryptedHive` then treats those boxes as empty
/// rather than falling back to plaintext. When secure storage itself throws
/// (no platform channel, Keystore failure), `null` is returned and callers
/// degrade per their own policy instead of failing startup.
class SecureKeyProvider {
  SecureKeyProvider({
    SecureKeyStorage? storage,
    this.storageTimeout = const Duration(seconds: 10),
  }) : _storage = storage ?? defaultSecureKeyStorage();

  static final SecureKeyProvider instance = SecureKeyProvider();

  /// Hive box encryption key (base64 of 32 random bytes).
  static const hiveBoxKeyName = 'fqapp_hive_encryption_key_v1';

  /// Rust device-pool file encryption key (base64 of 32 random bytes).
  static const devicePoolKeyName = 'fqapp_device_pool_key_v1';

  /// How long a single secure-storage read/write may take before it is
  /// treated as unavailable. The platform channel normally answers in
  /// milliseconds; without a bound, a wedged Keystore — or, in widget tests,
  /// an unmocked channel whose Future never resolves — would hang startup
  /// forever instead of letting callers degrade.
  final Duration storageTimeout;

  /// Cooldown after a failed key load: lookups within one startup return the
  /// cached failure instead of each waiting out the full storage timeout.
  /// A later retry (e.g. the bootstrap retry button after the cooldown)
  /// attempts the platform channel again.
  static const _failureCooldown = Duration(seconds: 30);

  final SecureKeyStorage _storage;
  final Map<String, Uint8List> _cache = {};
  final Map<String, Future<Uint8List?>> _pending = {};
  final Map<String, DateTime> _failedAt = {};

  Future<Uint8List?> getOrCreateKey({String name = hiveBoxKeyName}) {
    final cached = _cache[name];
    if (cached != null) return Future.value(cached);
    final failedAt = _failedAt[name];
    if (failedAt != null &&
        DateTime.now().difference(failedAt) < _failureCooldown) {
      return Future.value(null);
    }
    return _pending[name] ??= _loadOrCreate(name).then((key) {
      _pending.remove(name);
      return key;
    });
  }

  Future<Uint8List?> _loadOrCreate(String name) async {
    try {
      final stored = await _storage.read(name).timeout(storageTimeout);
      if (stored != null) {
        try {
          final decoded = base64Decode(stored);
          if (decoded.length == 32) {
            final bytes = Uint8List.fromList(decoded);
            _cache[name] = bytes;
            return bytes;
          }
        } catch (_) {
          // Malformed entry: fall through and replace it (key lost).
        }
      }
      final fresh = Uint8List.fromList(Hive.generateSecureKey());
      await _storage
          .write(name, base64Encode(fresh))
          .timeout(storageTimeout);
      _cache[name] = fresh;
      return fresh;
    } catch (_) {
      // Secure storage unavailable (or wedged past the timeout): record the
      // failure so the rest of this startup degrades immediately instead of
      // each caller waiting out another timeout. Callers decide how to
      // degrade. The generated-but-unpersisted key is deliberately NOT
      // returned: persisting it is what makes it usable next launch.
      _failedAt[name] = DateTime.now();
      return null;
    }
  }

  /// Device-pool file key for the P1-2 FRB handoff. Same infrastructure as
  /// the Hive key, separate key material.
  Future<Uint8List?> devicePoolKey() =>
      getOrCreateKey(name: devicePoolKeyName);

  @visibleForTesting
  void resetForTest() {
    _cache.clear();
    _pending.clear();
    _failedAt.clear();
  }
}
