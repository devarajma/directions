// import 'package:flutter_sms/flutter_sms.dart';
// import 'package:geolocator/geolocator.dart';
// import 'package:permission_handler/permission_handler.dart';
// import 'package:flutter/foundation.dart';

// class EmergencyService {
//   /// Request all permissions needed for emergency alerts
//   static Future<bool> requestPermissions() async {
//     final results = await [
//       Permission.sms,
//       Permission.location,
//       Permission.phone,
//     ].request();

//     final smsGranted      = results[Permission.sms]?.isGranted      ?? false;
//     final locationGranted = results[Permission.location]?.isGranted  ?? false;

//     // Phone permission is optional, don't block on it
//     return smsGranted && locationGranted;
//   }

//   /// Fetch current GPS location, returns a Google Maps URL
//   static Future<String> _getLocationUrl() async {
//     try {
//       LocationPermission permission = await Geolocator.checkPermission();
//       if (permission == LocationPermission.denied) {
//         permission = await Geolocator.requestPermission();
//       }
//       if (permission == LocationPermission.deniedForever) {
//         return "https://maps.google.com/?q=0,0";
//       }

//       final pos = await Geolocator.getCurrentPosition(
//         locationSettings: const LocationSettings(
//           accuracy: LocationAccuracy.medium,
//           timeLimit: Duration(seconds: 8),
//         ),
//       );
//       return "https://maps.google.com/?q=${pos.latitude},${pos.longitude}";
//     } catch (e) {
//       debugPrint("EmergencyService: location error: $e");
//       return "https://maps.google.com/?q=0,0";
//     }
//   }

//   /// Send emergency SMS to all contacts.
//   /// Returns a map of { phoneNumber: success }
//   static Future<Map<String, bool>> sendEmergencyAlerts({
//     required List<String> contactNumbers,
//     String userName = '',
//     String userPhone = '',
//   }) async {
//     final results = <String, bool>{};

//     if (contactNumbers.isEmpty) return results;

//     // Check if device can send SMS
//     final canSend = await canSendSMS();
//     if (!canSend) {
//       debugPrint("EmergencyService: device cannot send SMS");
//       for (final n in contactNumbers) {
//         results[n] = false;
//       }
//       return results;
//     }

//     // Build location URL
//     final locationUrl = await _getLocationUrl();

//     // Build message
//     final senderInfo =
//         userPhone.isNotEmpty ? " This is $userPhone." : "";
//     final message =
//         "EMERGENCY:$senderInfo I need help! "
//         "My location: $locationUrl";

//     // Deduplicate and clean numbers
//     final uniqueNumbers = contactNumbers
//         .map((n) => n.replaceAll(RegExp(r'[^\d+]'), ''))
//         .where((n) => n.isNotEmpty)
//         .toSet()
//         .toList();

//     debugPrint("EmergencyService: sending to $uniqueNumbers");

//     try {
//       final result = await sendSMS(
//         message: message,
//         recipients: uniqueNumbers,
//         sendDirect: true,
//       );
//       debugPrint("EmergencyService: result = $result");

//       final success = result == "SMS Sent!";
//       for (final n in uniqueNumbers) {
//         results[n] = success;
//       }
//     } catch (e) {
//       debugPrint("EmergencyService: error = $e");
//       for (final n in uniqueNumbers) {
//         results[n] = false;
//       }
//     }

//     return results;
//   }
// }



import 'package:flutter_sms/flutter_sms.dart';
import 'package:geolocator/geolocator.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:flutter/foundation.dart';

class EmergencyService {
  /// Request all permissions needed for emergency alerts
  static Future<bool> requestPermissions() async {
    final results = await [
      Permission.sms,
      Permission.location,
      Permission.phone,
    ].request();

    final smsGranted      = results[Permission.sms]?.isGranted      ?? false;
    final locationGranted = results[Permission.location]?.isGranted  ?? false;

    // Phone permission is optional (dual-SIM detection), don't block on it
    return smsGranted && locationGranted;
  }

  /// Fetch current GPS location, returns a Google Maps URL
  static Future<String> _getLocationUrl() async {
    try {
      LocationPermission permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
      if (permission == LocationPermission.deniedForever) {
        return "https://maps.google.com/?q=0,0";
      }

      final pos = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.medium,
          timeLimit: Duration(seconds: 8),
        ),
      );
      return "https://maps.google.com/?q=${pos.latitude},${pos.longitude}";
    } catch (e) {
      debugPrint("EmergencyService: location error: $e");
      return "https://maps.google.com/?q=0,0";
    }
  }

  /// Send emergency SMS to all contacts.
  /// Returns a map of { phoneNumber: success }
  static Future<Map<String, bool>> sendEmergencyAlerts({
    required List<String> contactNumbers,
    String userName = '',
    String userPhone = '',
  }) async {
    final results = <String, bool>{};

    if (contactNumbers.isEmpty) return results;

    // Check if device can send SMS
    final canSend = await canSendSMS();
    if (!canSend) {
      debugPrint("EmergencyService: device cannot send SMS");
      for (final n in contactNumbers) {
        results[n] = false;
      }
      return results;
    }

    // Build location URL
    final locationUrl = await _getLocationUrl();

    // Build message
    final senderInfo =
        userPhone.isNotEmpty ? " This is $userPhone." : "";
    final message =
        "EMERGENCY:$senderInfo I need help! My location: $locationUrl";

    // Deduplicate and clean numbers
    final uniqueNumbers = contactNumbers
        .map((n) => n.replaceAll(RegExp(r'[^\d+]'), ''))
        .where((n) => n.isNotEmpty)
        .toSet()
        .toList();

    debugPrint("EmergencyService: sending to $uniqueNumbers");

    try {
      final result = await sendSMS(
        message: message,
        recipients: uniqueNumbers,
      );
      debugPrint("EmergencyService: result = $result");

      final success = result == "SMS Sent!";
      for (final n in uniqueNumbers) {
        results[n] = success;
      }
    } catch (e) {
      debugPrint("EmergencyService: error = $e");
      for (final n in uniqueNumbers) {
        results[n] = false;
      }
    }

    return results;
  }
}