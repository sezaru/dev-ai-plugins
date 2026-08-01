---
name: flutter-file-photo-attachments
description: Use when a Flutter app lets users attach photos, documents, or arbitrary files — pick from camera/gallery/document-scanner/file-picker, encrypt each at rest, store a relative path + metadata, and view them (in-app image/PDF viewers, OS handoff for other types) without leaving plaintext on disk.
---

# File & photo attachments (pick → encrypt → view)

Let users attach photos, scanned documents, PDFs, or any file — each stored as encrypted bytes
in app-internal storage, with in-app viewers for images/PDFs and an OS handoff for everything
else. Thin, swappable pickers feeding one encrypted store. Proven in caremate's capture flow.

Builds directly on `flutter-encryption-at-rest` (the `AttachmentStore`) and feeds
`flutter-on-device-ai` (OCR on captured pages) and `flutter-secure-share-export` (decrypts to
package).

## Contents

1. Three pick sources, one store
2. Dependencies
3. The pickers (thin, fakeable)
4. Downscale small artefacts
5. Persist: encrypt + relative path + metadata
6. Viewing: images, PDFs, OS handoff
7. Gotchas

## 1. Three pick sources, one store

Keep each source small and single-purpose; they all funnel into the same encrypt-and-store core:

- **Document scanner** — edge-detected, cropped paper (ML Kit / VisionKit; see
  `flutter-on-device-ai`). OCR'd, page-indexed.
- **Photo** — camera/gallery, kept **verbatim** (no crop/enhance) via `image_picker`.
- **Any file** — arbitrary types via `file_picker`, stored **verbatim**.

Model scanned pages and generic files as **separate tables** — scanned pages carry `page_index` +
`ocr_text`; generic attachments carry `position`, `source` (camera/gallery/document), and the
**original filename** (verbatim, never OCR'd).

## 2. Dependencies

```yaml
dependencies:
  image_picker: ^1.2.2   # camera + gallery
  file_picker: ^11.0.2   # arbitrary files
  pdfx: ^2.9.2           # in-app PDF viewer
  open_filex: ^4.7.0     # hand off "other" types to the OS default app
```

On Android 13+ these use the **system photo/document pickers**, so **no storage permission** is
needed (don't request `READ_EXTERNAL_STORAGE`).

## 3. The pickers (thin, fakeable)

Instance methods so tests subclass with a fake; return temp paths + original names:

```dart
class PhotoPicker {
  PhotoPicker([ImagePicker? p]) : _picker = p ?? ImagePicker();
  Future<String?> takePhoto() async => (await _picker.pickImage(source: ImageSource.camera))?.path;
  Future<List<String>> pickFromGallery() async => [for (final x in await _picker.pickMultiImage()) x.path];
}

class FileAttachmentPicker {
  Future<List<PickedFile>> pick() async {
    final res = await FilePicker.pickFiles(type: FileType.any, allowMultiple: true);
    return res == null ? const [] : [for (final f in res.files) if (f.path != null) PickedFile(f.path!, f.name)];
  }
}
```

Keep the original `name` — you need it as the display label and to preserve the extension for the
OS handoff later.

## 4. Downscale small artefacts

For small images (avatars, thumbnails) pass `maxWidth`/`imageQuality` to `pickImage` — a
full-resolution capture needlessly bloats both storage **and every backup**:

```dart
Future<String?> pickSingle({required ImageSource source, double? maxWidth, int? imageQuality}) async =>
    (await _picker.pickImage(source: source, maxWidth: maxWidth, imageQuality: imageQuality))?.path;
```

## 5. Persist: encrypt + relative path + metadata

Pipe every picked temp through the encrypted store (`flutter-encryption-at-rest`), which encrypts,
writes `.enc`, and returns a **relative** path; save that path + metadata in your DB. Use a
**stable unique `storedName`** (the row id) so edits don't overwrite files:

```dart
final rel = await attachmentStore.persistFile(eventId, picked.path, storedName: attachmentId);
await repos.attachments.insert(RecordAttachment(
  id: attachmentId, eventId: eventId, position: i,
  source: picked.source, fileName: picked.name, relativePath: rel, createdAt: now));
```

Categorize each file into a broad **preview kind** (`image` / `video` / `pdf` / `file`) from its
extension/MIME — that drives the thumbnail and how the viewer opens it.

## 6. Viewing: images, PDFs, OS handoff

Three consumer shapes; none writes durable plaintext:

- **Image** → decrypt to bytes, `Image.memory(await store.readDecrypted(rel))`. In-app zoom.
- **PDF** → `decryptToTemp(rel, suffix: '.pdf')`, open with `pdfx`, **delete the temp when the
  viewer closes**.
- **Everything else** (video, audio, office docs) → `decryptToTemp(rel, suffix: origExt)`, then
  `OpenFilex.open(tempPath)` to hand to the OS default app; delete on return.

```dart
Widget imageView(String rel) => FutureBuilder(future: store.readDecrypted(rel),
    builder: (_, s) => s.hasData ? Image.memory(s.data!) : const SizedBox());

Future<void> openOther(String rel, String ext) async {
  final tmp = await store.decryptToTemp(rel, tag: id, suffix: ext);
  await OpenFilex.open(tmp);   // OS reaps the cache dir; delete proactively when you can
}
```

## 7. Gotchas

- **Everything routes through the encrypted store** — never write a picked file's plaintext into
  durable app storage; encrypt then delete the temp (see `flutter-encryption-at-rest`).
- **No storage permission on Android 13+** — the system photo/document pickers don't need it;
  requesting `READ_EXTERNAL_STORAGE` is wrong and gets flagged.
- **Store relative paths**, resolve on read (iOS sandbox path drift).
- **Stable unique `storedName`** (row id), not list index — else an edit overwrites a sibling file.
- **Downscale small images** at pick time — full-res avatars bloat storage and every backup.
- **Preserve the original filename/extension** — needed for the OS handoff and as the label.
- **Delete decrypt-to-temp files** when a viewer/handoff closes; the OS reaps the cache dir
  eventually, but don't leave plaintext lying around longer than needed.
- **Separate the OCR'd document pages from verbatim generic files** — different tables, different
  handling (page_index/ocr_text vs position/source/filename).
- **Keep pickers as instance methods** so tests inject fakes without touching the platform.
