import 'package:dio/dio.dart';

import '../core/core.dart';
import '../utils/utils.dart';
import 'models/build_request.dart';
import 'models/build_response.dart';
import 'models/review_request.dart';
import 'models/review_response.dart';
import 'models/versions_metadata.dart';

/// HTTP client to connect to the Widgetbook Cloud backend
class WidgetbookHttpClient {
  WidgetbookHttpClient({
    Dio? client,
    required Environment environment,
  }) : client = client ??
            Dio(
              BaseOptions(
                baseUrl: environment.apiUrl,
                contentType: Headers.jsonContentType,
              ),
            );

  final Dio client;

  /// Sends review data to the Widgetbook Cloud backend.
  Future<ReviewResponse> uploadReview(
    VersionsMetadata? versions,
    ReviewRequest request,
  ) async {
    if (request.useCases.isEmpty) {
      throw WidgetbookApiException(
        message: 'No use cases to upload',
      );
    }

    try {
      final response = await client.post<Map<String, dynamic>>(
        'v1/reviews',
        data: request.toJson(),
        options: Options(
          headers: versions?.toHeaders(),
        ),
      );

      return ReviewResponse.fromJson(response.data!);
    } catch (e) {
      final message = e is DioException //
          ? e.response?.toString()
          : e.toString();

      throw WidgetbookApiException(
        message: message,
      );
    }
  }

  Future<ReviewResponse> uploadReviewNext(
    VersionsMetadata? versions,
    ReviewRequestNext request,
  ) async {
    try {
      final response = await client.post<Map<String, dynamic>>(
        'v1.5/reviews',
        data: request.toJson(),
        options: Options(
          headers: versions?.toHeaders(),
        ),
      );

      return ReviewResponse.fromJson(response.data!);
    } catch (e) {
      final message = e is DioException //
          ? e.response?.toString()
          : e.toString();

      throw WidgetbookApiException(
        message: message,
      );
    }
  }

  /// Uploads the build .zip file to the Widgetbook Cloud backend.
  Future<BuildResponse> uploadBuild(
    VersionsMetadata? versions,
    BuildRequest request,
  ) async {
    try {
      final formData = await request.toFormData();
      final response = await client.post<Map<String, dynamic>>(
        'v1/builds/deploy',
        data: formData,
        options: Options(
          headers: versions?.toHeaders(),
        ),
      );

      return BuildResponse.fromJson(response.data!);
    } catch (e) {
      final message = e is DioException //
          ? e.response?.toString()
          : e.toString();

      throw WidgetbookApiException(
        message: message,
      );
    }
  }

  /// Uploads the build .zip and use-cases file to the Widgetbook Cloud backend.
  Future<BuildResponse> uploadBuildNext(
    VersionsMetadata? versions,
    BuildRequestNext request,
  ) async {
    try {
      final formData = await request.toFormData();
      final response = await client.post<Map<String, dynamic>>(
        'v1.5/builds/deploy',
        data: formData,
        options: Options(
          headers: versions?.toHeaders(),
        ),
      );

      return BuildResponse.fromJson(response.data!);
    } catch (e) {
      final message = e is DioException //
          ? e.response?.toString()
          : e.toString();

      throw WidgetbookApiException(
        message: message,
      );
    }
  }
}
