import 'dart:convert';
import 'dart:io';

import 'package:analyzer/dart/element/element.dart';
import 'package:build/build.dart';
import 'package:collection/collection.dart';
import 'package:path/path.dart' as p;
import 'package:source_gen/source_gen.dart';
import 'package:widgetbook_annotation/widgetbook_annotation.dart';
import 'package:yaml/yaml.dart';

import '../models/element_metadata.dart';
import '../models/nav_path_mode.dart';
import '../models/use_case_metadata.dart';

class UseCaseGenerator extends GeneratorForAnnotation<UseCase> {
  UseCaseGenerator(this.navPathMode);

  final localPackages = Resource<Map<String, String>>(
    () async {
      final lockFile = await File('pubspec.lock').readAsString();
      final yaml = loadYaml(lockFile) as YamlMap;
      final packages = yaml['packages'] as YamlMap;
      final localEntries = packages.entries
          .where((entry) => entry.value['source'] == 'path')
          .map(
            (entry) => MapEntry(
              entry.key as String,
              entry.value['description']['path'] as String,
            ),
          );

      return Map.fromEntries(localEntries);
    },
  );

  final NavPathMode navPathMode;

  @override
  Future<String> generateForAnnotatedElement(
    Element element,
    ConstantReader annotation,
    BuildStep buildStep,
  ) async {
    if (element.isPrivate) {
      throw InvalidGenerationSourceError(
        'Widgetbook annotations cannot be applied to private methods',
        element: element,
      );
    }

    final name = annotation.read('name').stringValue;
    final type = annotation.read('type').typeValue;
    final designLink = !annotation.read('designLink').isNull
        ? annotation.read('designLink').stringValue
        : null;

    final path = !annotation.read('path').isNull
        ? annotation.read('path').stringValue
        : null;

    final componentName = type
        .getDisplayString(
          // The `withNullability` parameter is deprecated after analyzer 6.0.0,
          // since we support analyzer 5.x (to support Dart <3.0.0), then
          // the deprecation is ignored.
          // ignore: deprecated_member_use
          withNullability: false,
        )
        // Generic widgets shouldn't have a "<dynamic>" suffix
        // if no type parameter is specified.
        .replaceAll('<dynamic>', '');

    final useCaseUri = await resolveElementUri(element, buildStep);
    final componentUri = await resolveElementUri(type.element!, buildStep);

    final useCasePath = await resolveElementPath(element, buildStep);
    final componentPath = await resolveElementPath(type.element!, buildStep);

    final targetNavUri = navPathMode == NavPathMode.component //
        ? componentUri
        : useCaseUri;

    final inputPackage = buildStep.inputId.package;
    final navPath = path ?? getNavPath(targetNavUri, inputPackage);

    final metadata = UseCaseMetadata(
      functionName: element.name!,
      designLink: designLink,
      name: name,
      importUri: useCaseUri,
      filePath: useCasePath,
      navPath: navPath,
      component: ElementMetadata(
        name: componentName,
        importUri: componentUri,
        filePath: componentPath,
      ),
    );

    const encoder = JsonEncoder.withIndent('  ');

    return encoder.convert(metadata.toJson());
  }

  /// Splits the [uri] into its parts, skipping both the `package:` and
  /// the `src` parts.
  /// For example, `package:widgetbook/src/widgets/foo/bar.dart`
  /// will be split into `['widgets', 'foo']`.
  ///
  /// If generator is running on a sub-package in a monorepo, the package name
  /// will be prepended. The package is considered a sub-package if the
  /// package name in the URI is different from the input package.
  /// For example, `package:main_app/src/widgets/foo/bar.dart` in a package
  /// named `workspace` will be split into `['main_app', 'widgets', 'foo']`.
  static String getNavPath(
    String uri,
    String inputPackage,
  ) {
    final directory = p.dirname(uri);
    final parts = p.split(directory);
    final hasSrc = parts.length >= 2 && parts[1] == 'src';

    final navPath = parts.skip(hasSrc ? 2 : 1).join('/');
    final uriPackage = parts.first.replaceFirst('package:', '');
    final isSamePackage = uriPackage == inputPackage;

    return isSamePackage ? navPath : '$uriPackage/$navPath';
  }

  /// Resolves the URI of an [element] by retrieving the URI from
  /// the [element]'s source.
  Future<String> resolveElementUri(
    Element element,
    BuildStep buildStep,
  ) async {
    final source = element.librarySource ?? element.source!;
    final uri = source.uri;
    final rawUri = uri.toString();

    if (uri.scheme == 'package') return rawUri;

    final resource = await buildStep.fetchResource(localPackages);

    // If the URI is an asset URI, means the input file is located outside
    // the input package's lib folder. In this case, we try to promote the
    // asset URI to a package URI.
    return tryPromoteAssetUri(uri, resource) ?? rawUri;
  }

  /// An asset URI can be promoted to a package URI if
  /// it has the following two conditions:
  /// 1. The [uri] matches the pattern:
  ///    `asset:{input_package}/{local_package_path}/lib/...`.
  /// 2. There's a package defined in `pubspec.lock` that has a path
  ///    that matches the `{local_package_path}`.
  ///
  /// If both conditions are met, the URI will be promoted to a package URI.
  /// The URI will be changed from `asset:.../{local_package_patch}/lib/...`
  /// to `package:{local_package}/...`.
  ///
  /// Returns the promoted URI if the conditions are met,
  /// otherwise returns `null`.
  String? tryPromoteAssetUri(
    Uri uri,
    Map<String, String> localPackages,
  ) {
    final rawUri = uri.toString();
    final regex = RegExp(r'asset:([^/]+)/(.*)/lib/(.*)');
    final match = regex.firstMatch(rawUri);

    if (match == null) return null;

    final localPackagePath = match.group(2);
    final localPackage = localPackages.entries.firstWhereOrNull(
      (entry) => entry.value == localPackagePath,
    );

    if (localPackage == null) return null;

    final packageName = localPackage.key;
    final filePath = match.group(3);

    return 'package:$packageName/$filePath';
  }

  /// Resolves the path of a local package by retrieving the path from
  /// the `pubspec.lock` file in case its name might not match its path.
  ///
  /// Example:
  /// A package with the name "shared_package" could be located in
  /// a folder named "shared". The path of the [element] would be
  /// `/shared_package/lib/...` which is not an actual path and should
  /// be resolved into `/shared/lib/...`.
  ///
  /// See also:
  /// - [#791](https://github.com/widgetbook/widgetbook/issues/791)
  Future<String> resolveElementPath(
    Element element,
    BuildStep buildStep,
  ) async {
    final elementPath = element.librarySource!.fullName;
    final elementPackage = element.librarySource!.uri.pathSegments[0];
    final inputPackage = buildStep.inputId.package;

    // If the element is in the same package as the `pubspec.lock` file,
    // then we cannot use the `pubspec.lock` file to resolve the path.
    // In this case, we can simply replace the package name with the
    // current directory name.
    if (elementPackage == inputPackage) {
      final currentDir = Directory.current.path;
      final dirName = p.basename(currentDir);

      return elementPath.replaceFirst(
        RegExp(elementPackage),
        dirName,
      );
    }

    final resource = await buildStep.fetchResource(localPackages);
    final packagePath = resource[elementPackage];
    final isLocalPackage = packagePath != null;

    if (!isLocalPackage) return elementPath;

    final normalizedPath = packagePath.replaceAll(
      RegExp(r'(\.)?\.\/'), // Match "./" and "../"
      '',
    );

    return elementPath.replaceFirst(
      RegExp(elementPackage),
      normalizedPath,
    );
  }
}
