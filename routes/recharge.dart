import 'dart:convert';
import 'dart:io';
import 'package:dart_frog/dart_frog.dart';

// Helper to keep track of quotas
// In production, this would be a real database like PostgreSQL or Firebase
final File _dbFile = File('${Directory.current.path}/db.json');

Future<Response> onRequest(RequestContext context) async {
  if (context.request.method != HttpMethod.post) {
    return Response.json(
      body: {'error': 'POST required'},
      statusCode: HttpStatus.methodNotAllowed,
    );
  }

  try {
    final body = await context.request.json() as Map<String, dynamic>;
    final deviceId = body['deviceId'] as String?;
    final code = body['code'] as String?;

    if (deviceId == null || deviceId.isEmpty || code == null || code.isEmpty) {
      return Response.json(
        body: {'error': 'deviceId and code are required'},
        statusCode: HttpStatus.badRequest,
      );
    }

    if (code != 'RECHARGE29') {
      return Response.json(
        body: {'error': 'Invalid activation code'},
        statusCode: HttpStatus.badRequest,
      );
    }

    // Load DB
    Map<String, dynamic> db = {};
    if (_dbFile.existsSync()) {
      final content = _dbFile.readAsStringSync();
      if (content.isNotEmpty) {
        db = jsonDecode(content) as Map<String, dynamic>;
      }
    }

    // Initialize if not exists
    if (!db.containsKey(deviceId)) {
      db[deviceId] = {'scans': 0, 'limit': 15};
    }

    // Add 49 to the limit
    final currentLimit = db[deviceId]['limit'] as int;
    db[deviceId]['limit'] = currentLimit + 49;

    // Save DB
    _dbFile.writeAsStringSync(jsonEncode(db));

    return Response.json(
      body: {
        'message': 'Successfully recharged! Added 49 scans.',
        'newLimit': db[deviceId]['limit'],
      },
    );
  } catch (e) {
    return Response.json(
      body: {'error': 'Server Error: $e'},
      statusCode: HttpStatus.internalServerError,
    );
  }
}
