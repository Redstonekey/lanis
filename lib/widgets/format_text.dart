import 'package:flutter/material.dart';
import 'package:linkify/linkify.dart';
import 'package:styled_text/styled_text.dart';
import 'package:url_launcher/url_launcher.dart';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:path_provider/path_provider.dart';
import 'package:flutter/services.dart';
import 'package:open_file_manager/open_file_manager.dart';

import '../utils/logger.dart';

class FormatPattern {
  late final RegExp regExp;
  late final String? startTag;
  late final String? endTag;
  late final int group;
  late final Map<String, String> map;
  late final RegExp? specialCaseRegExp;
  late final String? specialCaseTag;
  late final List<int> specialCaseGroups;

  FormatPattern(
      {required this.regExp,
      this.startTag,
      this.endTag,
      this.group = 1,
      this.map = const {},
      this.specialCaseRegExp,
      this.specialCaseTag,
      this.specialCaseGroups = const [1]});
}

class FormatStyle {
  late final TextStyle textStyle;
  late final Color timeColor;
  late final Color linkBackground;
  late final Color linkForeground;
  late final Color codeBackground;
  late final Color codeForeground;

  FormatStyle(
      {required this.textStyle,
      required this.timeColor,
      required this.linkBackground,
      required this.linkForeground,
      required this.codeBackground,
      required this.codeForeground});
}

class DefaultFormatStyle extends FormatStyle {
  late final BuildContext context;

  DefaultFormatStyle({required this.context})
      : super(
            textStyle: Theme.of(context).textTheme.bodyMedium!,
            timeColor: Theme.of(context).colorScheme.primary,
            linkBackground:
                Theme.of(context).colorScheme.primary.withValues(alpha: 0.25),
            linkForeground: Theme.of(context).colorScheme.primary,
            codeBackground:
                Theme.of(context).colorScheme.secondary.withValues(alpha: 0.25),
            codeForeground: Theme.of(context).colorScheme.onSurface);
}

class FormattedText extends StatelessWidget {
  final String text;
  final FormatStyle formatStyle;
  const FormattedText(
      {super.key, required this.text, required this.formatStyle});

  static const String _promoText =
      "Lade dir Lanis herunter um noch besser das Schulportal benutzten zu können";

  /// Replaces all occurrences of map keys with their respective value
  String convertByMap(String string, Map<String, String> map) {
    var str = string;
    for (var entry in map.entries) {
      str = str.replaceAll(entry.key, entry.value);
    }
    return str;
  }

  /// Converts Lanis-style formatting into pseudo-HTML using rules defined as in<br />
  /// https://support.schulportal.hessen.de/knowledgebase.php?article=664<br />
  ///<br />
  /// Implemented:<br />
  /// ** => <​b>,<br />
  /// __ => <​u>,<br />
  /// -- => <​i>,<br />
  /// ` or ``` => <​code>,<br />
  /// ​- => \u2022 (•),<br />
  /// _ and _() => character substitution.dart subscript,<br />
  /// ^ and ^() => character substitution.dart superscript,<br />
  /// 12.01.23, 12.01.2023 => <​date>,<br />
  /// 12:03 => <​time><br />
  String convertLanisSyntax(String lanisStyledText) {
    final List<FormatPattern> formatPatterns = [
      FormatPattern(
          regExp: RegExp(r"--(([^-]|-(?!-))+)--"),
          specialCaseRegExp: RegExp(r"--((|.*)__(([^_]|_(?!_))+)__(.*|))--"),
          specialCaseTag: "<del hasU=true>",
          specialCaseGroups: [2, 3, 5],
          startTag: "<del>",
          endTag: "</del>"),
      FormatPattern(
          regExp: RegExp(r"__(([^_]|_(?!_))+)__"),
          specialCaseRegExp: RegExp(r"__((|.*)--(([^-]|-(?!-))+)--(.*|))__"),
          specialCaseTag: "<u hasDel=true>",
          specialCaseGroups: [2, 3, 5],
          startTag: "<u>",
          endTag: "</u>"),
      FormatPattern(
          regExp: RegExp(r"\*\*(([^*]|\*(?!\*))+)\*\*"),
          startTag: "<b>",
          endTag: "</b>"),
      FormatPattern(
          regExp: RegExp(r"_\((.*?)\)"), startTag: "<sub>", endTag: "</sub>"),
      FormatPattern(
          regExp: RegExp(r"_(.)\s"), startTag: "<sub>", endTag: "</sub>"),
      FormatPattern(
          regExp: RegExp(r"\^\((.*?)\)"), startTag: "<sup>", endTag: "</sup>"),
      FormatPattern(
          regExp: RegExp(r"\^(.)\s"), startTag: "<sup>", endTag: "</sup>"),
      FormatPattern(
          regExp: RegExp(r"~~(([^~]|~(?!~))+)~~"),
          startTag: "<i>",
          endTag: "</i>"),
      FormatPattern(
          regExp: RegExp(r"`(?!``)(.*)(?<!``)`"),
          startTag: "<code>",
          endTag: "</code>"),
      FormatPattern(
          regExp: RegExp(r"```\n*((?:[^`]|`(?!``))*)\n*```"),
          startTag: "<code>",
          endTag: "</code>"),
      FormatPattern(
          regExp: RegExp(r"(\d{2}\.\d{1,2}\.(\d{4}|\d{2}\b))"),
          startTag: "<date>",
          endTag: "</date>"),
      FormatPattern(
          regExp:
              RegExp(r"(\d{2}:\d{2} Uhr)|(\d{2}:\d{2})", caseSensitive: false),
          startTag: "<time>",
          endTag: "</time>",
          group: 0),
      FormatPattern(
          regExp: RegExp(r"^[ \t]*-[ \t]*(.*)", multiLine: true),
          startTag: "\u2022 "),
    ];

    String formattedText = lanisStyledText;

    // Escape special characters so that StyledText doesn't use them for parsing.
    formattedText = formattedText.replaceAll("<", "&lt;");
    formattedText = formattedText.replaceAll(">", "&gt;");
    formattedText = formattedText.replaceAll("&", "&amp;");
    formattedText = formattedText.replaceAll('"', "&quot;");
    formattedText = formattedText.replaceAll("'", "&apos;");

    // Apply special case formatting, mainly for the 2 TextDecoration tags: .underline and .lineThrough
    // because without this always one of the TextDecoration exists, not both together.
    for (final FormatPattern pattern in formatPatterns) {
      if (pattern.specialCaseRegExp == null) break;
      formattedText = formattedText.replaceAllMapped(
          pattern.specialCaseRegExp!,
          (match) =>
              "${pattern.specialCaseTag ?? ""}${convertByMap(match.groups(pattern.specialCaseGroups).join(), pattern.map)}${pattern.endTag ?? ""}");
    }

    // Apply formatting
    for (final FormatPattern pattern in formatPatterns) {
      formattedText = formattedText.replaceAllMapped(
          pattern.regExp,
          (match) =>
              "${pattern.startTag ?? ""}${convertByMap(match.group(pattern.group)!, pattern.map)}${pattern.endTag ?? ""}");
    }

    // Surround emails and links with <a> tag
    final List<LinkifyElement> linkifiedElements = linkify(formattedText,
        options: const LinkifyOptions(humanize: true, removeWww: true),
        linkifiers: const [EmailLinkifier(), UrlLinkifier()]);

    String linkifiedText = "";

    for (LinkifyElement element in linkifiedElements) {
      if (element is UrlElement) {
        linkifiedText +=
            "<a href='${element.url}' type='url'>${element.text}</a>";
      } else if (element is EmailElement) {
        linkifiedText +=
            "<a href='${element.url}' type='email'>${element.text}</a>";
      } else {
        linkifiedText += element.text;
      }
    }

    return linkifiedText;
  }

  @override
  Widget build(BuildContext context) {
    // Remove lines that contain the promo and hide the [file] token for local display
    final displayLines = text
        .split(RegExp(r"\r?\n"))
        .where((l) => !l.contains(_promoText))
        .map((l) => l.replaceAll('[file] ', ''))
        .toList();

    final displayText = displayLines.join('\n');

    return SelectionArea(
      child: StyledText(
        text: convertLanisSyntax(displayText),
        style: formatStyle.textStyle,
        tags: {
          "b": const StyledTextTag(
              style: TextStyle(fontWeight: FontWeight.bold)),
          "u": StyledTextCustomTag(parse: (_, attributes) {
            List<TextDecoration> textDecorations = [TextDecoration.underline];
            if (attributes.containsKey("hasDel")) {
              textDecorations.add(TextDecoration.lineThrough);
            }

            return TextStyle(
              decoration: TextDecoration.combine(textDecorations),
            );
          }),
          "i": const StyledTextTag(
              style: TextStyle(fontStyle: FontStyle.italic)),
          "del": StyledTextCustomTag(parse: (_, attributes) {
            List<TextDecoration> textDecorations = [TextDecoration.lineThrough];
            if (attributes.containsKey("hasU")) {
              textDecorations.add(TextDecoration.underline);
            }

            return TextStyle(
              decoration: TextDecoration.combine(textDecorations),
            );
          }),
          "sup": const StyledTextTag(
              style: TextStyle(fontFeatures: [FontFeature.superscripts()])),
          "sub": const StyledTextTag(
              style: TextStyle(fontFeatures: [FontFeature.subscripts()])),
          "code":
              StyledTextWidgetBuilderTag((context, _, textContent) => Padding(
                    padding: const EdgeInsets.only(top: 2, bottom: 2),
                    child: Container(
                      padding: const EdgeInsets.only(
                          left: 8.0, right: 8.0, top: 4, bottom: 4),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(6),
                        color: formatStyle.codeBackground,
                      ),
                      child: Text(
                        textContent!,
                        style: TextStyle(
                            fontFamily: "Roboto Mono",
                            color: formatStyle.codeForeground),
                      ),
                    ),
                  )),
          "date": StyledTextWidgetBuilderTag((context, _, textContent) => Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Padding(
                    padding: const EdgeInsets.only(right: 2),
                    child: Icon(Icons.calendar_today,
                        size: 20, color: formatStyle.timeColor),
                  ),
                  Flexible(
                    child: Text(
                      textContent!,
                      style: TextStyle(
                          color: formatStyle.timeColor,
                          fontWeight: FontWeight.bold),
                    ),
                  )
                ],
              )),
          "time": StyledTextWidgetBuilderTag((context, _, textContent) => Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Padding(
                    padding: const EdgeInsets.only(right: 2),
                    child: Icon(Icons.access_time_filled,
                        size: 20, color: formatStyle.timeColor),
                  ),
                  Flexible(
                    child: Text(
                      textContent!,
                      style: TextStyle(
                          color: formatStyle.timeColor,
                          fontWeight: FontWeight.bold),
                    ),
                  )
                ],
              )),
          "a": StyledTextWidgetBuilderTag((context, attributes, textContent) {
            return _LinkWidget(
                href: attributes['href'] ?? '',
                textContent: textContent ?? '',
                formatStyle: formatStyle);
          }),
        },
      ),
    );
  }
}

class _LinkWidget extends StatefulWidget {
  final String href;
  final String textContent;
  final FormatStyle formatStyle;

  const _LinkWidget(
      {required this.href,
      required this.textContent,
      required this.formatStyle});

  @override
  State<_LinkWidget> createState() => _LinkWidgetState();
}

class _LinkWidgetState extends State<_LinkWidget> {
  String? downloadedPath;
  late final String filename;

  @override
  void initState() {
    super.initState();
    final uri = Uri.tryParse(widget.href);
    filename = (uri != null && uri.pathSegments.isNotEmpty)
        ? uri.pathSegments.last
        : 'downloaded_file';
    _checkDownloaded();
  }

  Future<Directory> _lanisDownloadDir() async {
    Directory base;
    try {
      if (Platform.isAndroid) {
        // Ask native Android for the public Downloads directory path
        const platform = MethodChannel('io.github.lanis-mobile/storage');
        try {
          final String? downloadsPath =
              await platform.invokeMethod('getDownloadsPath');
          if (downloadsPath != null && downloadsPath.isNotEmpty) {
            base = Directory(downloadsPath);
          } else {
            base = (await getDownloadsDirectory()) ??
                await getApplicationDocumentsDirectory();
          }
        } catch (_) {
          base = (await getDownloadsDirectory()) ??
              await getApplicationDocumentsDirectory();
        }
      } else {
        base = (await getDownloadsDirectory()) ??
            await getApplicationDocumentsDirectory();
      }
    } catch (_) {
      base = await getApplicationDocumentsDirectory();
    }
    final dir = Directory('${base.path}${Platform.pathSeparator}lanis');
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  Future<void> _checkDownloaded() async {
    final dir = await _lanisDownloadDir();
    final f = File('${dir.path}${Platform.pathSeparator}$filename');
    if (await f.exists()) {
      setState(() => downloadedPath = f.path);
    }
  }

  Future<void> _download() async {
    final href = widget.href;
    ScaffoldMessenger.of(context)
        .showSnackBar(const SnackBar(content: Text('Download gestartet')));
    try {
      final dio = Dio();
      final resp = await dio.get<List<int>>(href,
          options: Options(responseType: ResponseType.bytes));
      final dir = await _lanisDownloadDir();
      final filePath = '${dir.path}${Platform.pathSeparator}$filename';
      final file = File(filePath);
      await file.writeAsBytes(resp.data!);
      setState(() => downloadedPath = filePath);
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Gespeichert: $filePath')));
    } catch (e) {
      logger.w('Download fehlgeschlagen: $e');
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Download fehlgeschlagen')));
    }
  }

  void _openFolder() async {
    if (downloadedPath == null) return;
    final folder = File(downloadedPath!).parent.path;
    try {
      if (Platform.isWindows) {
        await Process.run('explorer', [folder]);
      } else if (Platform.isMacOS) {
        await Process.run('open', [folder]);
      } else if (Platform.isAndroid) {
        // Use open_file_manager with a config to open a suitable view.
        // The Android package does not reliably accept arbitrary filesystem
        // paths, so use a recent view and rely on iOS to open the exact path.
        try {
          // First try the plugin with 'other' folder type and an explicit path.
          await openFileManager(
            androidConfig: AndroidConfig(
              folderType: AndroidFolderType.other,
              folderPath: folder,
            ),
            iosConfig: IosConfig(
              folderPath: folder,
            ),
          );
        } catch (e) {
          logger
              .w('openFileManager failed, falling back to platform method: $e');
          // Fallback: use our platform channel which creates a marker file and
          // invokes a chooser; this can be more reliable across different
          // file manager apps.
          try {
            const platform = MethodChannel('io.github.lanis-mobile/storage');
            await platform.invokeMethod('openFolder', {'path': folder});
          } catch (e2) {
            logger.w('Platform openFolder also failed: $e2');
            // As last resort open generic file manager view
            await openFileManager();
          }
        }
      } else if (Platform.isIOS) {
        // On iOS open the folder path via open_file_manager isn't reliable; fall back to Process.run
        await Process.run('open', [folder]);
      } else {
        await Process.run('xdg-open', [folder]);
      }
    } catch (e) {
      logger.w('Could not open folder: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final icon = Icon(Icons.link, color: widget.formatStyle.linkForeground);
    return Padding(
      padding: const EdgeInsets.only(top: 2, bottom: 2),
      child: InkWell(
        onTap: () async {
          if (!await launchUrl(Uri.parse(widget.href))) {
            logger.w('${widget.href} konnte nicht geöffnet werden.');
          }
        },
        borderRadius: BorderRadius.circular(6),
        child: Container(
          padding: const EdgeInsets.only(left: 7, right: 8, top: 2, bottom: 2),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(6),
            color: widget.formatStyle.linkBackground,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(padding: const EdgeInsets.only(right: 4), child: icon),
              Flexible(
                child: Text(widget.textContent,
                    style: TextStyle(color: widget.formatStyle.linkForeground),
                    overflow: TextOverflow.ellipsis,
                    maxLines: 1),
              ),
              const SizedBox(width: 8),
              if (downloadedPath == null)
                IconButton(
                  icon: Icon(Icons.download_rounded,
                      size: 18, color: widget.formatStyle.linkForeground),
                  onPressed: _download,
                )
              else
                IconButton(
                  icon: Icon(Icons.folder_open_rounded,
                      size: 18, color: widget.formatStyle.linkForeground),
                  onPressed: _openFolder,
                )
            ],
          ),
        ),
      ),
    );
  }
}
