import 'dart:async';
import 'dart:io';

import 'package:http/http.dart' as http;

import 'api_client.dart';

/// Retries a transient async failure a few times with linear backoff.
///
/// The listening page uses this for recoverable transport failures. HTTP
/// authentication and same-device backoff are owned by the backend; a body
/// business code alone does not establish whether another attempt can recover.
Future<T> retryTransient<T>(
  Future<T> Function() task, {
  int attempts = 3,
  Duration baseDelay = const Duration(milliseconds: 200),
  bool Function(Object error)? shouldRetry,
}) async {
  if (attempts < 1) {
    throw ArgumentError.value(attempts, 'attempts', 'must be at least 1');
  }
  Object? lastError;
  for (var attempt = 0; attempt < attempts; attempt++) {
    try {
      return await task();
    } catch (error) {
      lastError = error;
      // Failures outside the caller's recovery policy must not burn the
      // remaining attempts and their backoff; callers pass [shouldRetry].
      if (shouldRetry != null && !shouldRetry(error)) break;
      if (attempt + 1 < attempts) {
        await Future<void>.delayed(baseDelay * (attempt + 1));
      }
    }
  }
  throw lastError!;
}

/// Whether [error] is a transient failure worth another attempt.
///
/// A dropped connection, HTTP 408/429 or a 5xx can recover. A timeout already
/// spent its deadline; other 4xx and business codes have no recovery policy
/// here. Backend authentication retries must not be multiplied blindly.
bool isTransientNetworkFailure(Object error) {
  if (error is ApiException) {
    final status = error.statusCode;
    if (status == null) return false;
    return status == HttpStatus.requestTimeout ||
        status == HttpStatus.tooManyRequests ||
        status >= 500;
  }
  return error is SocketException ||
      error is HttpException ||
      error is http.ClientException;
}
