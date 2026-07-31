import 'package:fooplayer_core/fooplayer_core.dart';
import 'package:test/test.dart';

void main() {
  PlaylistFile pf(String id, String name, List<String> ids, String mod,
          {String by = 'dev'}) =>
      PlaylistFile(id: id, name: name, trackIds: ids,
          created: DateTime.parse('2026-07-01T00:00:00Z'),
          modified: DateTime.parse(mod), modifiedBy: by);
  PlaylistSidecarState state(
          {Map<String, PlaylistFile>? p, Map<String, PlaylistTombstone>? t}) =>
      PlaylistSidecarState(p ?? {}, t ?? {}, []);
  PlaylistTombstone ts(String when, [String name = 'gone']) =>
      PlaylistTombstone(deleted: DateTime.parse(when), name: name);
  List<PlaylistSyncAction> run(PlaylistSidecarState l, PlaylistSidecarState r) =>
      reconcilePlaylists(l, r, localLabel: 'tablet', remoteLabel: 'NAS');

  test('identical sides produce no actions', () {
    final a = pf('p_1', 'n', ['x'], '2026-07-31T12:00:00Z');
    final b = pf('p_1', 'n', ['x'], '2026-07-31T12:00:00Z');
    expect(run(state(p: {'p_1': a}), state(p: {'p_1': b})), isEmpty);
  });

  test('same content, different timestamps: no copy (idempotent double-sync)', () {
    final a = pf('p_1', 'n', ['x'], '2026-07-31T12:00:00Z');
    final b = pf('p_1', 'n', ['x'], '2026-07-31T11:00:00Z');
    expect(run(state(p: {'p_1': a}), state(p: {'p_1': b})), isEmpty);
  });

  test('local newer wins: copyToRemote with backup', () {
    final l = pf('p_1', 'n', ['x', 'y'], '2026-07-31T12:00:00Z', by: 'tablet');
    final r = pf('p_1', 'n', ['x'], '2026-07-31T11:00:00Z', by: 'desktop');
    final acts = run(state(p: {'p_1': l}), state(p: {'p_1': r}));
    expect(acts, hasLength(1));
    expect(acts.single.op, PlaylistSyncOp.copyToRemote);
    expect(acts.single.backupFirst, isTrue);
    expect(acts.single.note, contains('tablet'));
  });

  test('remote newer wins: copyToLocal with backup', () {
    final l = pf('p_1', 'n', ['x'], '2026-07-31T11:00:00Z');
    final r = pf('p_1', 'n', ['x', 'y'], '2026-07-31T12:00:00Z');
    final acts = run(state(p: {'p_1': l}), state(p: {'p_1': r}));
    expect(acts.single.op, PlaylistSyncOp.copyToLocal);
    expect(acts.single.backupFirst, isTrue);
  });

  test('equal timestamps, different content: remote wins deterministically', () {
    final l = pf('p_1', 'n', ['x'], '2026-07-31T12:00:00Z');
    final r = pf('p_1', 'n', ['y'], '2026-07-31T12:00:00Z');
    final acts = run(state(p: {'p_1': l}), state(p: {'p_1': r}));
    expect(acts.single.op, PlaylistSyncOp.copyToLocal);
    expect(acts.single.note, contains('same timestamp'));
  });

  test('local-only playlist with no remote tombstone: new, copyToRemote, no backup', () {
    final l = pf('p_1', 'n', ['x'], '2026-07-31T12:00:00Z');
    final acts = run(state(p: {'p_1': l}), state());
    expect(acts.single.op, PlaylistSyncOp.copyToRemote);
    expect(acts.single.backupFirst, isFalse);
  });

  test('remote tombstone newer than local playlist: deleteLocal with backup + tombstoneToLocal', () {
    final l = pf('p_1', 'n', ['x'], '2026-07-31T10:00:00Z');
    final acts = run(state(p: {'p_1': l}),
        state(t: {'p_1': ts('2026-07-31T12:00:00Z')}));
    expect(acts.map((a) => a.op), unorderedEquals(
        [PlaylistSyncOp.deleteLocal, PlaylistSyncOp.tombstoneToLocal]));
    expect(acts.firstWhere((a) => a.op == PlaylistSyncOp.deleteLocal).backupFirst,
        isTrue);
  });

  test('local edit newer than remote tombstone: resurrect (copyToRemote)', () {
    final l = pf('p_1', 'n', ['x'], '2026-07-31T12:00:00Z');
    final acts = run(state(p: {'p_1': l}),
        state(t: {'p_1': ts('2026-07-31T10:00:00Z')}));
    expect(acts.single.op, PlaylistSyncOp.copyToRemote);
  });

  test('tombstone only on local side propagates to remote', () {
    final acts = run(state(t: {'p_1': ts('2026-07-31T12:00:00Z')}), state());
    expect(acts.single.op, PlaylistSyncOp.tombstoneToRemote);
  });

  test('remote tombstone deletes a remote-unaware local AND mirrors symmetrically', () {
    // mirror case of deleteLocal: remote has the live playlist, local has the newer tombstone
    final r = pf('p_1', 'n', ['x'], '2026-07-31T10:00:00Z');
    final acts = run(state(t: {'p_1': ts('2026-07-31T12:00:00Z')}),
        state(p: {'p_1': r}));
    expect(acts.map((a) => a.op), unorderedEquals(
        [PlaylistSyncOp.deleteRemote, PlaylistSyncOp.tombstoneToRemote]));
  });

  test('independent ids on both sides sync both ways', () {
    final l = pf('p_1', 'a', [], '2026-07-31T12:00:00Z');
    final r = pf('p_2', 'b', [], '2026-07-31T12:00:00Z');
    final acts = run(state(p: {'p_1': l}), state(p: {'p_2': r}));
    expect(acts.map((a) => a.op), unorderedEquals(
        [PlaylistSyncOp.copyToRemote, PlaylistSyncOp.copyToLocal]));
  });
}
