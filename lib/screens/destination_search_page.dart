import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../models/building_config.dart';
import '../models/destination.dart';

// ---------------------------------------------------------------------------
// Matching: substring first, then typo-tolerant word matching.
// ---------------------------------------------------------------------------

String _norm(String s) =>
    s.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), ' ').trim();

const Map<String, List<String>> _synonyms = {
  'washroom': ['toilet'],
  'restroom': ['toilet'],
  'bathroom': ['toilet'],
  'wc': ['toilet'],
  'loo': ['toilet'],
  'elevator': ['lift'],
  'laboratory': ['lab'],
  'teacher': ['faculty'],
  'professor': ['faculty'],
  'meeting': ['conference'],
};

int _lev(String a, String b) {
  if (a == b) return 0;
  if (a.isEmpty) return b.length;
  if (b.isEmpty) return a.length;
  var prev = List<int>.generate(b.length + 1, (i) => i);
  for (var i = 1; i <= a.length; i++) {
    final cur = List<int>.filled(b.length + 1, 0);
    cur[0] = i;
    for (var j = 1; j <= b.length; j++) {
      final cost = a[i - 1] == b[j - 1] ? 0 : 1;
      cur[j] = math.min(math.min(cur[j - 1] + 1, prev[j] + 1), prev[j - 1] + cost);
    }
    prev = cur;
  }
  return prev[b.length];
}

double? _tokenScore(String qt, String nt) {
  if (nt.startsWith(qt)) return 0.0;
  if (qt.length >= 3 && nt.contains(qt)) return 0.3;
  final allowed = qt.length <= 3 ? 0 : (qt.length <= 6 ? 1 : 2);
  if (allowed == 0) return null;
  final prefix = nt.length > qt.length ? nt.substring(0, qt.length) : nt;
  final d = math.min(_lev(qt, nt), _lev(qt, prefix));
  return d <= allowed ? 0.5 + d : null;
}

/// Lower is better; null = no match.
double? _score(String name, String rawQuery) {
  final q = _norm(rawQuery);
  if (q.isEmpty) return 0.0;
  final n = _norm(name);

  final idx = n.indexOf(q);
  if (idx >= 0) return idx == 0 ? 0.0 : (n.contains(' $q') ? 0.2 : 0.5);

  final nTokens = n.split(' ');

  // Initials, e.g. "ai" -> Artificial Intelligence Lab.
  final compact = q.replaceAll(' ', '');
  final initials = nTokens.map((t) => t.isEmpty ? '' : t[0]).join();
  if (compact.length >= 2 && initials.startsWith(compact)) return 0.8;

  var total = 0.0;
  for (final qt in q.split(' ')) {
    double? best;
    for (final alt in [qt, ...(_synonyms[qt] ?? const <String>[])]) {
      for (final nt in nTokens) {
        final s = _tokenScore(alt, nt);
        if (s != null && (best == null || s < best)) best = s;
      }
    }
    if (best == null) return null;
    total += best;
  }
  return 1.0 + total;
}

IconData _iconFor(String name) {
  final n = name.toLowerCase();
  if (n.contains('toilet') || n.contains('wc')) return Icons.wc;
  if (n.contains('lift')) return Icons.elevator_outlined;
  if (n.contains('library')) return Icons.local_library_outlined;
  if (n.contains('lab')) return Icons.computer_outlined;
  if (n.contains('faculty') || n.contains('staff') || n.contains('chamber')) {
    return Icons.person_outline;
  }
  if (n.contains('mca') || n.contains('m.sc') || n.contains('diploma')) {
    return Icons.school_outlined;
  }
  if (n.contains('room')) return Icons.meeting_room_outlined;
  return Icons.place_outlined;
}

class _Hit {
  _Hit(this.destination, this.score, this.exact);
  final Destination destination;
  final double score;
  final bool exact;
}

// ---------------------------------------------------------------------------
// Page
// ---------------------------------------------------------------------------

class DestinationSearchPage extends StatefulWidget {
  final BuildingConfig config;

  const DestinationSearchPage({
    super.key,
    required this.config,
  });

  @override
  State<DestinationSearchPage> createState() => _DestinationSearchPageState();
}

class _DestinationSearchPageState extends State<DestinationSearchPage> {
  final TextEditingController _controller = TextEditingController();
  late final List<Destination> _all;
  String _query = '';

  @override
  void initState() {
    super.initState();
    final withNode = <String>{
      for (final n in widget.config.nodes) ...n.roomIds,
    };
    _all = widget.config.rooms.where((r) => withNode.contains(r.id)).toList()
      ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  List<_Hit> _results() {
    final q = _query.trim();
    final hits = <_Hit>[];
    for (final d in _all) {
      final s = _score(d.name, q);
      if (s == null) continue;
      final exact = q.isEmpty || _norm(d.name).contains(_norm(q));
      hits.add(_Hit(d, s, exact));
    }
    if (q.isNotEmpty) {
      hits.sort((a, b) {
        final c = a.score.compareTo(b.score);
        return c != 0
            ? c
            : a.destination.name.compareTo(b.destination.name);
      });
    }
    return hits;
  }

  Widget _title(String name, ColorScheme cs) {
    const base = TextStyle(fontSize: 16, fontWeight: FontWeight.w500);
    final q = _query.trim().toLowerCase();
    final i = q.isEmpty ? -1 : name.toLowerCase().indexOf(q);
    if (i < 0) return Text(name, style: base);
    return Text.rich(TextSpan(style: base, children: [
      TextSpan(text: name.substring(0, i)),
      TextSpan(
        text: name.substring(i, i + q.length),
        style: TextStyle(fontWeight: FontWeight.w800, color: cs.primary),
      ),
      TextSpan(text: name.substring(i + q.length)),
    ]));
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final hits = _results();
    final hasQuery = _query.trim().isNotEmpty;
    final didYouMean = hasQuery && hits.isNotEmpty && !hits.any((h) => h.exact);

    return Scaffold(
      backgroundColor: const Color(0xFFF4F6FA),
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 16, 6),
              child: Row(
                children: [
                  IconButton(
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.arrow_back),
                  ),
                  Expanded(
                    child: Material(
                      elevation: 3,
                      shadowColor: Colors.black26,
                      borderRadius: BorderRadius.circular(28),
                      child: TextField(
                        controller: _controller,
                        autofocus: true,
                        textInputAction: TextInputAction.search,
                        onChanged: (v) => setState(() => _query = v),
                        onSubmitted: (_) {
                          if (hits.isNotEmpty) {
                            Navigator.pop(context, hits.first.destination);
                          }
                        },
                        decoration: InputDecoration(
                          hintText: 'Search rooms, labs, toilets…',
                          filled: true,
                          fillColor: Colors.white,
                          prefixIcon: Icon(Icons.search, color: cs.primary),
                          suffixIcon: _query.isEmpty
                              ? null
                              : IconButton(
                                  icon: const Icon(Icons.close),
                                  onPressed: () {
                                    _controller.clear();
                                    setState(() => _query = '');
                                  },
                                ),
                          contentPadding:
                              const EdgeInsets.symmetric(vertical: 14),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(28),
                            borderSide: BorderSide.none,
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(22, 10, 22, 6),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  !hasQuery
                      ? 'All places'
                      : (didYouMean ? 'Did you mean…' : 'Suggestions'),
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: Colors.grey.shade600,
                  ),
                ),
              ),
            ),
            Expanded(
              child: hits.isEmpty
                  ? Center(
                      child: Padding(
                        padding: const EdgeInsets.all(32),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.search_off,
                                size: 56, color: Colors.grey.shade400),
                            const SizedBox(height: 12),
                            Text(
                              'No places found for “${_query.trim()}”',
                              textAlign: TextAlign.center,
                              style: const TextStyle(
                                  fontSize: 16, fontWeight: FontWeight.w600),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              'Check the spelling or try another word.',
                              style: TextStyle(color: Colors.grey.shade600),
                            ),
                          ],
                        ),
                      ),
                    )
                  : ListView.builder(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
                      itemCount: hits.length,
                      itemBuilder: (context, i) {
                        final d = hits[i].destination;
                        return Padding(
                          padding: const EdgeInsets.only(bottom: 8),
                          child: Material(
                            color: Colors.white,
                            borderRadius: BorderRadius.circular(16),
                            child: InkWell(
                              borderRadius: BorderRadius.circular(16),
                              onTap: () => Navigator.pop(context, d),
                              child: Padding(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 14, vertical: 12),
                                child: Row(
                                  children: [
                                    Container(
                                      width: 42,
                                      height: 42,
                                      decoration: BoxDecoration(
                                        color: cs.primary
                                            .withValues(alpha: 0.10),
                                        borderRadius:
                                            BorderRadius.circular(12),
                                      ),
                                      child: Icon(_iconFor(d.name),
                                          color: cs.primary),
                                    ),
                                    const SizedBox(width: 14),
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          _title(d.name, cs),
                                          const SizedBox(height: 2),
                                          Text(
                                            'Floor ${widget.config.floor}',
                                            style: TextStyle(
                                              fontSize: 12.5,
                                              color: Colors.grey.shade600,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                    Icon(Icons.directions_walk,
                                        color: Colors.grey.shade500),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}
