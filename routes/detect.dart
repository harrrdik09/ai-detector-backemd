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
  model: 'gemini-2.5-flash', // We use 2.5 because it is the latest and fastest
  apiKey: _apiKey,
  generationConfig: GenerationConfig(
    temperature: 0.1,
    maxOutputTokens: 1024,
    responseMimeType: 'application/json', // Forces Gemini to return pure JSON
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

    // Parse the JSON response from Gemini
    try {
      final result =
          jsonDecode(cleanedText) as Map<String, dynamic>;

      final isAI = result['isAI'] as bool? ?? false;
      final confidence =
          (result['confidence'] as num?)?.toDouble() ?? 0.0;
      final reason =
          result['reason'] as String? ?? 'No reason provided';

      return Response.json(
        body: {
          'isAI': isAI,
          'confidence': confidence,
          'message': isAI
              ? '⚠️ AI-Generated Image Detected'
              : '✅ Image appears to be Real',
          'reason': reason,
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
    return Response.json(
      body: {
        'error': 'Server error: $e',
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
