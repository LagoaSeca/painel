import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../../features/flyer/data/models/flyer_model.dart';

class DeviceRegistration {
  final String deviceId;
  final String pairingCode;
  final String panelToken;

  const DeviceRegistration({
    required this.deviceId,
    required this.pairingCode,
    required this.panelToken,
  });
}

class FlyerApiService {
  static const String _prefsDeviceIdKey = 'device_id';
  static const String _prefsPanelTokenKey = 'panel_token';

  final String baseUrl;
  final String panelToken;
  final String? deviceId;

  const FlyerApiService({
    required this.baseUrl,
    required this.panelToken,
    this.deviceId,
  });

  String get _normalizedBaseUrl =>
      baseUrl.endsWith('/') ? baseUrl.substring(0, baseUrl.length - 1) : baseUrl;

  Map<String, String> _headers() {
    return {
      'Authorization': 'Bearer $panelToken',
      'Accept': 'application/json',
      'Content-Type': 'application/json',
    };
  }

  static Future<(String? deviceId, String? panelToken)> readSavedAuth() async {
    final prefs = await SharedPreferences.getInstance();
    return (
      prefs.getString(_prefsDeviceIdKey),
      prefs.getString(_prefsPanelTokenKey),
    );
  }

  static Future<void> clearSavedAuth() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_prefsDeviceIdKey);
    await prefs.remove(_prefsPanelTokenKey);
  }

  static Future<DeviceRegistration> registerDevice({required String baseUrl}) async {
    final normalized =
        baseUrl.endsWith('/') ? baseUrl.substring(0, baseUrl.length - 1) : baseUrl;

    final response = await http
        .post(
          Uri.parse('$normalized/api/devices/register'),
          headers: {
            'Accept': 'application/json',
            'Content-Type': 'application/json',
          },
          body: json.encode(<String, dynamic>{}),
        )
        .timeout(const Duration(seconds: 15));

    if (response.statusCode != 200 && response.statusCode != 201) {
      throw Exception(
        'Falha ao registrar dispositivo: ${response.statusCode} ${response.body}',
      );
    }

    final dynamic data = json.decode(response.body);
    if (data is! Map<String, dynamic>) {
      throw Exception('Resposta inválida ao registrar dispositivo: ${response.body}');
    }

    final deviceId = data['device_id']?.toString() ?? '';
    final panelToken = data['panel_token']?.toString() ?? '';
    final pairingCode = data['pairing_code']?.toString() ?? '';

    if (deviceId.isEmpty || panelToken.isEmpty || pairingCode.isEmpty) {
      throw Exception('Registro inválido: device_id/panel_token/pairing_code ausentes.');
    }

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefsDeviceIdKey, deviceId);
    await prefs.setString(_prefsPanelTokenKey, panelToken);

    return DeviceRegistration(
      deviceId: deviceId,
      panelToken: panelToken,
      pairingCode: pairingCode,
    );
  }

  Future<(bool, String?)> checkIfPaired() async {
    if (deviceId == null || deviceId!.isEmpty) {
      throw Exception('Dispositivo não inicializado para verificação de status.');
    }

    final response = await http
        .get(
          Uri.parse('$_normalizedBaseUrl/api/devices/$deviceId/status'),
          headers: _headers(),
        )
        .timeout(const Duration(seconds: 15));

    if (response.statusCode == 200) {
      final data = json.decode(response.body) as Map<String, dynamic>;
      final isPaired = (data['paired'] as bool?) ?? false;
      final userId = data['user_id'] as String?;
      return (isPaired, userId);
    }

    if (response.statusCode == 404) {
      return (false, null);
    }

    throw Exception('Erro ao verificar status de pareamento: ${response.statusCode}');
  }

  Future<Flyer?> fetchLatestFlyer() async {
    final response = await http
        .get(
          Uri.parse('$_normalizedBaseUrl/api/latest_flyer'),
          headers: _headers(),
        )
        .timeout(const Duration(seconds: 15));

    if (response.statusCode == 401) {
      throw Exception('401 não autorizado. Refaça o registro do dispositivo.');
    }
    if (response.statusCode != 200) {
      throw Exception('Erro do servidor: ${response.statusCode} ${response.body}');
    }

    final dynamic data = json.decode(response.body);
    if (data is! Map<String, dynamic>) {
      throw Exception('Resposta inesperada em /api/latest_flyer: ${response.body}');
    }

    final flyerJson = data['flyer'];
    if (flyerJson == null) {
      return null;
    }

    return Flyer.fromJson(Map<String, dynamic>.from(flyerJson as Map));
  }

  Future<List<Flyer>> fetchAllFlyers() async {
    if (deviceId == null || deviceId!.isEmpty) {
      throw Exception('Dispositivo não inicializado para buscar todos os flyers.');
    }

    final response = await http
        .get(
          Uri.parse('$_normalizedBaseUrl/api/devices/$deviceId/all_flyers'),
          headers: _headers(),
        )
        .timeout(const Duration(seconds: 15));

    if (response.statusCode != 200) {
      throw Exception('Erro do servidor: ${response.statusCode} ${response.body}');
    }

    final dynamic data = json.decode(response.body);
    if (data is! Map<String, dynamic>) {
      throw Exception('Resposta inesperada: ${response.body}');
    }

    final flyersJson = data['flyers'] as List<dynamic>?;
    if (flyersJson == null) {
      return [];
    }

    return flyersJson
        .map((f) => Flyer.fromJson(Map<String, dynamic>.from(f as Map)))
        .toList();
  }
}
