import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'package:path_provider/path_provider.dart';

import 'secure_key_storage.dart';

/// macOS key storage.
///
/// The Keychain is the right home for key material, but a locally built
/// (ad-hoc signed) sandboxed app cannot satisfy `keychain-access-groups`, so
/// SecItem calls fail with errSecMissingEntitlement (-34018) and every key read
/// would come back empty. This store therefore prefers the Keychain and falls
/// back to a 0600 file inside the app's private container: still readable only
/// by this user, still keeps the Hive boxes encrypted, and a Developer
/// ID-signed build automatically goes back to the Keychain.
class MacOSKeyStore implements SecureKeyStorage {
  MacOSKeyStore({SecureKeyStorage? keychain, SecureKeyStorage? file})
    : _keychain = keychain ?? MacOSKeychainStore(),
      _file = file ?? MacOSFileKeyStore();

  final SecureKeyStorage _keychain;
  final SecureKeyStorage _file;

  @override
  Future<String?> read(String key) async {
    try {
      final value = await _keychain.read(key);
      if (value != null && value.isNotEmpty) return value;
    } catch (_) {
      // Missing entitlement (or a locked Keychain): fall through to the file.
    }
    return _file.read(key);
  }

  @override
  Future<void> write(String key, String value) async {
    try {
      await _keychain.write(key, value);
      return;
    } catch (_) {
      await _file.write(key, value);
    }
  }

  @override
  Future<void> delete(String key) async {
    // Clear both: an earlier ad-hoc build may have written the same key to the
    // file before a signed build started using the Keychain.
    Object? error;
    try {
      await _keychain.delete(key);
    } catch (error0) {
      error = error0;
    }
    try {
      await _file.delete(key);
    } catch (error0) {
      error ??= error0;
    }
    if (error != null) throw error;
  }
}

/// Keychain backend. The macOS runner registers no native key channel, so this
/// reuses the Keychain through `flutter_secure_storage`'s macOS plugin.
class MacOSKeychainStore implements SecureKeyStorage {
  MacOSKeychainStore([FlutterSecureStorage? storage])
    : _storage = storage ?? const FlutterSecureStorage();

  final FlutterSecureStorage _storage;

  @override
  Future<String?> read(String key) => _storage.read(key: key);

  @override
  Future<void> write(String key, String value) =>
      _storage.write(key: key, value: value);

  @override
  Future<void> delete(String key) => _storage.delete(key: key);
}

/// Fallback backend: one 0600 file per key under Application Support.
class MacOSFileKeyStore implements SecureKeyStorage {
  MacOSFileKeyStore({Future<Directory> Function()? supportDirectory})
    : _supportDirectory = supportDirectory ?? getApplicationSupportDirectory;

  final Future<Directory> Function() _supportDirectory;

  Future<File> _file(String key) async {
    final support = await _supportDirectory();
    final directory = Directory('${support.path}/keys');
    await directory.create(recursive: true);
    final safe = key.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
    return File('${directory.path}/$safe');
  }

  @override
  Future<String?> read(String key) async {
    try {
      final file = await _file(key);
      if (!await file.exists()) return null;
      final value = (await file.readAsString()).trim();
      return value.isEmpty ? null : value;
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> write(String key, String value) async {
    final file = await _file(key);
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
      // Best effort: the container is already private to this user.
    }
  }

  @override
  Future<void> delete(String key) async {
    try {
      final file = await _file(key);
      if (await file.exists()) await file.delete();
    } catch (_) {
      // A missing key file is the desired post-delete state.
    }
  }
}

/// True while running under `flutter test`.
///
/// Widget tests run on the host platform (macOS on a Mac), so without this the
/// file fallback would do real async I/O whose storage-timeout timer outlives
/// the fake test clock ("A Timer is still pending"). Tests keep the legacy
/// MethodChannel store, which fails fast when unmocked.
bool get runningInFlutterTest => Platform.environment['FLUTTER_TEST'] == 'true';
