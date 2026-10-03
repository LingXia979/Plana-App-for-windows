import '../../features/assistant/session_store.dart';
import '../../features/gallery/gallery_store.dart';
import '../../features/generate/workspace_store.dart';
import 'app_stores.dart';
import 'blob_store.dart';

class InpaintHistoryUsage {
  const InpaintHistoryUsage({
    required this.count,
    required this.releasableBytes,
  });
  final int count;

  /// Unique, existing blob bytes no other saved or active state needs.
  final int releasableBytes;
}

class InpaintHistoryCleanupResult {
  const InpaintHistoryCleanupResult({
    required this.clearedIds,
    required this.releasedBytes,
    required this.failedIds,
    this.reclamationDeferred = false,
  });
  final Set<String> clearedIds;
  final int releasedBytes;
  final Set<String> failedIds;
  final bool reclamationDeferred;
}

/// Removes only historical inpaint inputs. Images, thumbnails, ordinary
/// generation settings and live workspace/assistant references are retained.
class InpaintHistoryCleanup {
  InpaintHistoryCleanup({
    required this.blobs,
    required this.gallery,
    required this.workspace,
    required this.assistant,
  });

  factory InpaintHistoryCleanup.forStores(AppStores stores) =>
      InpaintHistoryCleanup(
        blobs: stores.blobs,
        gallery: stores.gallery,
        workspace: stores.workspace,
        assistant: stores.assistant,
      );

  final BlobStore blobs;
  final GalleryStore gallery;
  final WorkspaceStore workspace;
  final AssistantStore assistant;

  Future<void> _settleWrites() async {
    workspace.flush();
    assistant.flush();
    await Future.wait([workspace.idle, assistant.idle, gallery.flushIndex()]);
    await gallery.idle;
  }

  Future<Set<String>> _protectedRefs() async => {
    ...await workspace.liveRefs(strict: true),
    ...await assistant.liveRefs(strict: true),
  };

  Future<InpaintHistoryUsage> scan() async {
    await _settleWrites();
    final revision = blobs.referenceRevision;
    final inventory = await gallery.inspectInpaintHistory();
    final live = {...inventory.retainedRefs, ...await _protectedRefs()};
    final bytes = await blobs.sizeOfHashes(
      inventory.detachedRefs.difference(live),
    );
    return InpaintHistoryUsage(
      count: inventory.ids.length,
      releasableBytes: revision == blobs.referenceRevision ? bytes : 0,
    );
  }

  Future<InpaintHistoryCleanupResult> clear({bool Function()? canClear}) async {
    await _settleWrites();
    // Validate every reference source before changing any history document.
    await _protectedRefs();
    if (canClear?.call() == false) {
      throw StateError('正在生成或保存图片，请完成后再清理');
    }
    final revision = blobs.referenceRevision;
    final removed = await gallery.clearInpaintHistory();
    var released = 0;
    var deferred = false;
    try {
      final live = {
        ...await _protectedRefs(),
        ...await gallery.liveRefs(strict: true),
      };
      released = await blobs.removeDetachedHashes(
        removed.detachedRefs,
        live,
        expectedRevision: revision,
      );
      deferred = revision != blobs.referenceRevision;
    } catch (_) {
      // Detached bytes may wait for ordinary orphan GC; never guess references
      // from an unreadable state file or roll back an already-cleared history.
      deferred = true;
    }
    return InpaintHistoryCleanupResult(
      clearedIds: removed.ids,
      releasedBytes: released,
      failedIds: removed.failedIds,
      reclamationDeferred: deferred,
    );
  }
}
