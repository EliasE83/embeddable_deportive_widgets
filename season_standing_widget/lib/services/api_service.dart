// api_service.dart
import 'dart:convert';
import 'dart:js_util' as js_util;
import 'package:http/http.dart' as http;
import 'package:crypto/crypto.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';

class ApiService {
  static String _getJsStringOrEnv(String jsField, String envField) {
    if (js_util.hasProperty(js_util.globalThis, 'customConfiguration')) {
      final dynamic config =
          js_util.getProperty(js_util.globalThis, 'customConfiguration');
      if (js_util.hasProperty(config, jsField)) {
        final val = js_util.getProperty(config, jsField);
        if (val is String && val.isNotEmpty) {
          return val;
        }
      }
    }
    return dotenv.env[envField]!;
  }

  static String get apiUsername {
    return _getJsStringOrEnv('username', 'API_USERNAME');
  }

  static String get apiSecret {
    return _getJsStringOrEnv('secret', 'API_SECRET');
  }

  static String get apiUrl {
    return _getJsStringOrEnv('api_url', 'API_URL');
  }

  static String get defaultLeagueId {
    if (js_util.hasProperty(js_util.globalThis, 'customConfiguration')) {
      final dynamic config = js_util.getProperty(js_util.globalThis, 'customConfiguration');
      if (js_util.hasProperty(config, 'league_id')) {
        final dynamic jsVal = js_util.getProperty(config, 'league_id');
        if (jsVal is String && jsVal.isNotEmpty) {
          return jsVal;
        }
      }
    }

    final String? envVal = dotenv.env['LEAGUE_ID'];
    if (envVal != null && envVal.isNotEmpty) {
      return envVal; 
    }

    return '1';
  }

  static String get defaultSeasonId {
    if (js_util.hasProperty(js_util.globalThis, 'customConfiguration')) {
      final dynamic config = js_util.getProperty(js_util.globalThis, 'customConfiguration');
      if (js_util.hasProperty(config, 'season')) {
        final dynamic jsVal = js_util.getProperty(config, 'season');
        if (jsVal is String && jsVal.isNotEmpty) {
          return jsVal;
        }
      }
    }

    final String? envVal = dotenv.env['SEASON_ID'];
    if (envVal != null && envVal.isNotEmpty) {
      return envVal; 
    }

    return '7';
  }

  static Uri generateLink(
    String request, {
    Map<String, String> moreQueries = const {},
  }) {
    final String username = apiUsername;
    final String secret   = apiSecret;
    final String baseApi  = apiUrl;

    const String body = "";
    final int authTime = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final md5Bod = md5.convert(utf8.encode(body));

    Map<String, dynamic> queryParams = {
      "auth_key":       username,
      "auth_timestamp": authTime.toString(),
      "body_md5":       md5Bod.toString(),
    };

    moreQueries.forEach((k, v) {
      queryParams[k] = v;
    });

    final secretBytes = utf8.encode(secret);
    final hmac = Hmac(sha256, secretBytes);

    bool first = true;
    String queryArgStr = "GET\n/$request\n";

    queryParams.forEach((k, v) {
      if (first) {
        first = false;
      } else {
        queryArgStr += "&";
      }
      if (k != "") {
        queryArgStr += "$k=$v";
      }
    });

    queryParams["auth_signature"] =
        hmac.convert(utf8.encode(queryArgStr)).toString();

    return Uri(
      scheme: "https",
      host: baseApi,
      path: request,
      queryParameters: queryParams.map((k, v) => MapEntry(k, v.toString())),
    );
  }

  static Future<Map<String, dynamic>> fetchData(Uri link) async {
    final resp = await http.get(link);

    if (resp.statusCode == 200) {
      return jsonDecode(resp.body) as Map<String, dynamic>;
    } else {
      throw AssertionError(
          "Connection Error: Code ${resp.statusCode}");
    }
  }
}
