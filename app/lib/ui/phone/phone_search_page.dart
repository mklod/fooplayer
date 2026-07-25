// Last modified: 2026-07-24--1855
import 'package:flutter/material.dart';
import '../../model/filtering.dart';
import '../../model/library_model.dart';
import 'phone_feed.dart';

/// Full-screen phone search: an AppBar [TextField] live-filtering the feed
/// (title/artist/album substring match via [applyFilters], same semantics
/// as the desktop search field) over a date-added-desc result list. Keeps
/// its query LOCAL -- it never writes [LibraryModel.search], so backing out
/// of the page leaves the underlying feed exactly as it was.
class PhoneSearchPage extends StatefulWidget {
  final LibraryModel library;
  final PlayTrackCallback onPlayTrack;
  final TrackLongPressCallback onTrackLongPress;

  const PhoneSearchPage({
    super.key,
    required this.library,
    required this.onPlayTrack,
    required this.onTrackLongPress,
  });

  @override
  State<PhoneSearchPage> createState() => _PhoneSearchPageState();
}

class _PhoneSearchPageState extends State<PhoneSearchPage> {
  String _query = '';

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: TextField(
          key: const Key('phone-search-field'),
          autofocus: true,
          decoration: const InputDecoration(
            hintText: 'Search title, artist, album',
            prefixIcon: Icon(Icons.search, size: 18),
          ),
          onChanged: (s) => setState(() => _query = s),
        ),
      ),
      body: ListenableBuilder(
        listenable: widget.library,
        builder: (context, _) => PhoneTrackList(
          tracks: sortByDateAddedDesc(
              applyFilters(widget.library.allTracks, search: _query)),
          onPlay: widget.onPlayTrack,
          onLongPress: widget.onTrackLongPress,
        ),
      ),
    );
  }
}
