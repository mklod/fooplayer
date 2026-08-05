// Full-resolution artwork viewer (right-click on the sidebar's corner art
// preview -- see home_screen.dart's _SelectedArtPreview). Read-only by
// design: the left-click picker already owns CHANGING artwork; this modal
// exists purely to LOOK at the real pixels, at their real size, with the
// dimensions spelled out.
//
// Last modified: 2026-08-04--1712
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../artwork/artwork_resolver.dart';
import '../model/track.dart';
import 'app_theme.dart';

/// Resolves [track]'s artwork through [resolver] (the same chain every
/// other cover in the app uses -- embedded, sidecar choice, folder image)
/// and shows it full-resolution in a modal dialog: the image at up to ~85%
/// of the window, BoxFit.contain, with a `WxH px` caption. No artwork
/// resolving to null/empty simply shows nothing -- no dialog, no error;
/// the preview the user right-clicked already told them what exists.
Future<void> showFullResArtworkDialog(
  BuildContext context, {
  required Track track,
  required ArtworkResolver resolver,
}) async {
  final List<int>? bytes;
  try {
    bytes = await resolver.resolve(ArtworkRequest.forTrack(track));
  } catch (_) {
    return; // resolver hiccup -- same silent policy as a missing cover
  }
  if (bytes == null || bytes.isEmpty) return;
  final u8 = bytes is Uint8List ? bytes : Uint8List.fromList(bytes);

  // Decode once for the caption's real pixel dimensions; the Image.memory
  // below re-uses Flutter's image cache, so this doesn't decode twice.
  final ui.Image decoded;
  try {
    decoded = await decodeImageFromList(u8);
  } catch (_) {
    return; // corrupt bytes -- nothing worth a broken-image dialog
  }

  if (!context.mounted) return;
  await showDialog<void>(
    context: context,
    builder: (ctx) {
      final screen = MediaQuery.sizeOf(ctx);
      return Dialog(
        key: const Key('artwork-view-dialog'),
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: screen.width * 0.85,
            maxHeight: screen.height * 0.85,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Flexible(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: Image.memory(
                      u8,
                      fit: BoxFit.contain,
                      filterQuality: FilterQuality.high,
                    ),
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        '${track.album.isNotEmpty ? track.album : track.title}'
                        ' — ${decoded.width}×${decoded.height} px',
                        key: const Key('artwork-view-caption'),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 12,
                          color: AppColors.inkSecondary,
                        ),
                      ),
                    ),
                    TextButton(
                      onPressed: () => Navigator.of(ctx).pop(),
                      child: const Text('Close'),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      );
    },
  );
}
