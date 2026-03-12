import 'dart:convert';
import 'package:budget/struct/databaseGlobal.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Handles persistence for SimpleFIN credentials and configuration.
///
/// The Access URL (which contains credentials) is kept in flutter_secure_storage.
/// Account mappings, last sync time, and default category are in SharedPreferences.
class SimplefinStorage {
  static const _storage = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
    lOptions: LinuxOptions(),
  );

  static const _accessUrlKey = 'simplefin_access_url';
  static const _accountMappingsKey = 'simplefin_account_mappings';
  static const _lastSyncMsKey = 'simplefin_last_sync_ms';
  static const _defaultCategoryKey = 'simplefin_default_category_pk';

  // ── Access URL ──────────────────────────────────────────────────────────────

  static Future<void> saveAccessUrl(String url) async {
    await _storage.write(key: _accessUrlKey, value: url);
  }

  static Future<String?> getAccessUrl() async {
    return await _storage.read(key: _accessUrlKey);
  }

  static Future<void> clearAccessUrl() async {
    await _storage.delete(key: _accessUrlKey);
  }

  // ── Account mappings: simplefin account ID → cashew wallet PK ───────────────

  static Map<String, String> getAccountMappings() {
    final raw = sharedPreferences.getString(_accountMappingsKey);
    if (raw == null) return {};
    return Map<String, String>.from(jsonDecode(raw) as Map);
  }

  static Future<void> saveAccountMappings(Map<String, String> mappings) async {
    await sharedPreferences.setString(_accountMappingsKey, jsonEncode(mappings));
  }

  // ── Last sync time ──────────────────────────────────────────────────────────

  static DateTime? getLastSyncTime() {
    final ms = sharedPreferences.getInt(_lastSyncMsKey);
    return ms != null ? DateTime.fromMillisecondsSinceEpoch(ms) : null;
  }

  static Future<void> saveLastSyncTime(DateTime time) async {
    await sharedPreferences.setInt(_lastSyncMsKey, time.millisecondsSinceEpoch);
  }

  static Future<void> clearLastSyncTime() async {
    await sharedPreferences.remove(_lastSyncMsKey);
  }

  // ── Default category PK for uncategorized imports ───────────────────────────

  static String? getDefaultCategoryPk() {
    return sharedPreferences.getString(_defaultCategoryKey);
  }

  static Future<void> saveDefaultCategoryPk(String pk) async {
    await sharedPreferences.setString(_defaultCategoryKey, pk);
  }
}
