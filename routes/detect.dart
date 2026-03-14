// --------------------------------------------------------------------------
// FILE: routes/detect.dart
// PURPOSE: Accepts an image via POST, sends it to Gemini 1.5 Flash
//          to analyze if the image is AI-generated or Real.
//
// JAVA ANALOGY:
//   This is like a @PostMapping("/detect") method in Spring Boot.
//   Dart Frog maps files in `routes/` to URL paths automatically.
// --------------------------------------------------------------------------

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:dart_frog/dart_frog.dart';
import 'package:google_generative_ai/google_generative_ai.dart';

// -----------------------------------------------------------------------
// 🔑 API KEY — Secured via Environment Variables
// -----------------------------------------------------------------------
// The API key is ONLY read from the securely provided environment variables.
final String _apiKey = Platform.environment['GEMINI_API_KEY'] ?? '';

// The prompt we send to Gemini along with the image
// This is carefully crafted to get a structured JSON response
const String _analysisPrompt = '''
ACT AS A HIGH-LEVEL DIGITAL FORENSICS EXPERT. 
Your task is to detect if an image is AI-generated (Synthetic) or a Real Photograph.

AI models like Gemini, Midjourney, and DALL-E have specific "fingerprints" even when they look perfect. Look for:
1. Abnormal skin smoothness and lack of natural pores.
2. Inconsistencies in lighting and shadows.
3. Strange patterns in complex areas like hair, hands, or eyes.
4. Pixel noise: Check for unnaturally clean areas vs. natural camera sensor grain.

MANDATORY: Be extremely aggressive in finding AI artifacts. If you see any abnormal smoothness or strange patterns, mark it as isAI: true.

Respond ONLY with a valid JSON object in this exact format (no markdown, no extra text):
{"isAI": true or false, "confidence": 0.0 to 1.0, "reason": "Explain exactly which AI fingerprint you found."}
''';

// -----------------------------------------------------------------------
// 📦 MAIN REQUEST HANDLER
// -----------------------------------------------------------------------

final File _dbFile = File('${Directory.current.path}/db.json');

Future<Response> onRequest(RequestContext context) async {
  // Only allow POST requests
  if (context.request.method != HttpMethod.post) {
    return Response.json(
      body: {'error': 'Only POST requests are allowed'},
      statusCode: HttpStatus.methodNotAllowed,
    );
  }

  // Check if API key is configured
  if (_apiKey.isEmpty) {
    return Response.json(
      body: {
        'error': 'API key not configured! '
            'Please set the GEMINI_API_KEY environment variable.',
      },
      statusCode: HttpStatus.internalServerError,
    );
  }

  // ── DEVICE ID QUOTA CHECK ──
  final headers = context.request.headers;
  // Dart HTTP headers are always lowercased automatically
  final deviceId =
      headers['device-id'] ?? headers['Device-Id'] ?? 'unknown_device';

  Map<String, dynamic> db = {};
  if (_dbFile.existsSync()) {
    final content = _dbFile.readAsStringSync();
    if (content.isNotEmpty) {
      db = jsonDecode(content) as Map<String, dynamic>;
    }
  }

  // Initialize if new device
  if (!db.containsKey(deviceId)) {
    db[deviceId] = {'scans': 0, 'limit': 15};
  }

  // Check quota
  final scans = db[deviceId]['scans'] as int;
  final limit = db[deviceId]['limit'] as int;

  if (scans >= limit) {
    return Response.json(
      body: {
        'error': 'QUOTA_EXCEEDED',
        'message': 'You have used all $limit free scans. Please recharge.',
        'scans': scans,
        'limit': limit,
      },
      statusCode: HttpStatus.forbidden,
    );
  }

  try {
    // ----- STEP 1: Read image bytes from request -----
    // bytes() returns Stream<List<int>> — collect all chunks
    final byteStream = context.request.bytes();
    final imageBytes = <int>[];
    await for (final chunk in byteStream) {
      imageBytes.addAll(chunk);
    }

    if (imageBytes.isEmpty) {
      return Response.json(
        body: {
          'error': 'No image data received. '
              'Send image bytes in the request body.',
        },
        statusCode: HttpStatus.badRequest,
      );
    }

// ----- STEP 2: Initialize Latest Flash Model -----
    final model = GenerativeModel(
      model:
          'gemini-2.5-flash', // We use 2.5 because it is the latest and fastest
      apiKey: _apiKey,
      generationConfig: GenerationConfig(
        temperature: 0.1,
        maxOutputTokens: 1024,
        responseMimeType:
            'application/json', // Forces Gemini to return pure JSON
      ),
    );

    // ----- STEP 3: Send image to Gemini for analysis -----
    // Detect the image MIME type from the first bytes
    final mimeType = _detectMimeType(imageBytes);

    // Build the content with both text prompt and image
    // In Java: Content.newBuilder()
    //            .addPart(TextPart(prompt))
    //            .addPart(InlineData(mimeType, bytes))
    //            .build()
    final content = Content.multi([
      TextPart(_analysisPrompt),
      DataPart(mimeType, Uint8List.fromList(imageBytes)),
    ]);

    // Call Gemini — like Java's model.generateContent(content)
    final response = await model.generateContent([content]);

    // ----- STEP 4: Parse the response -----
    final responseText = response.text;

    if (responseText == null || responseText.isEmpty) {
      return Response.json(
        body: {
          'isAI': false,
          'confidence': 0.0,
          'message': 'Gemini returned no response',
        },
      );
    }

    // Clean the response — remove markdown code blocks
    // if Gemini wraps the JSON in ```json ... ```
    var cleanedText = responseText.trim();
    if (cleanedText.startsWith('```')) {
      cleanedText = cleanedText
          .replaceFirst(RegExp(r'^```json?\s*'), '')
          .replaceFirst(RegExp(r'```\s*$'), '')
          .trim();
    }

    // ── INCREASE QUOTA USAGE ──
    db[deviceId]['scans'] = scans + 1;
    _dbFile.writeAsStringSync(jsonEncode(db));

    // Parse the JSON response from Gemini
    try {
      final result = jsonDecode(cleanedText) as Map<String, dynamic>;

      final isAI = result['isAI'] as bool? ?? false;
      final confidence = (result['confidence'] as num?)?.toDouble() ?? 0.0;
      final reason = result['reason'] as String? ?? 'No reason provided';

      return Response.json(
        body: {
          'isAI': isAI,
          'confidence': confidence,
          'message': isAI
              ? '⚠️ AI-Generated Image Detected'
              : '✅ Image appears to be Real',
          'reason': reason,
          'scansLeft': limit - (scans + 1), // Optional: inform frontend
        },
      );
    } catch (parseError) {
      // If JSON parsing fails, return raw Gemini response
      return Response.json(
        body: {
          'isAI': false,
          'confidence': 0.0,
          'message': 'Could not parse Gemini response',
          'rawResponse': responseText,
        },
      );
    }
  } catch (e, stackTrace) {
    final errorString = e.toString().toLowerCase();
    print('ERROR ENCOUNTERED: $e'); 
    
    // 1. Check for Expired or Invalid API Key (CRITICAL)
    if (errorString.contains('api key expired') || errorString.contains('key_invalid') || errorString.contains('invalid api key')) {
      return Response.json(
        body: {
          'error': 'API_KEY_EXPIRED',
          'message': '🔴 YOUR API KEY HAS EXPIRED! \n\nPlease go to https://aistudio.google.com/apikey and create a NEW key, then update your Render environment variable.',
        },
        statusCode: 401,
      );
    }

    // 2. Check if it's a rate limit or quota issue
    if (errorString.contains('quota exceeded') || errorString.contains('429')) {
      return Response.json(
        body: {
          'error': 'API_LIMIT_REACHED',
          'message': '⏳ Our AI servers are currently full (Per-Minute Quota Exceeded). Please wait 1 minute and try again!',
        },
        statusCode: 429,
      );
    } 
    // 3. Check if Google's server is down or unreachable
    else if (errorString.contains('unavaila') ||
        errorString.contains('socket') ||
        errorString.contains('connection')) {
      return Response.json(
        body: {
          'error': 'SERVER_DOWN',
          'message':
              'The AI Server is currently unreachable. Please try again later.',
        },
        statusCode: 503,
      );
    }

    // Generic server error
    return Response.json(
      body: {
        'error': 'SERVER_ERROR',
        'message': 'An unexpected server error occurred: $e',
        'stackTrace': '$stackTrace',
      },
      statusCode: HttpStatus.internalServerError,
    );
  }
}

/// Detects the MIME type of an image from its first bytes
/// In Java: URLConnection.guessContentTypeFromStream()
String _detectMimeType(List<int> bytes) {
  if (bytes.length >= 3 &&
      bytes[0] == 0xFF &&
      bytes[1] == 0xD8 &&
      bytes[2] == 0xFF) {
    return 'image/jpeg';
  }
  if (bytes.length >= 8 &&
      bytes[0] == 0x89 &&
      bytes[1] == 0x50 &&
      bytes[2] == 0x4E &&
      bytes[3] == 0x47) {
    return 'image/png';
  }
  if (bytes.length >= 4 &&
      bytes[0] == 0x47 &&
      bytes[1] == 0x49 &&
      bytes[2] == 0x46) {
    return 'image/gif';
  }
  if (bytes.length >= 4 &&
      bytes[0] == 0x52 &&
      bytes[1] == 0x49 &&
      bytes[2] == 0x46 &&
      bytes[3] == 0x46) {
    return 'image/webp';
  }
  // Default to JPEG if we can't detect
  return 'image/jpeg';
}
