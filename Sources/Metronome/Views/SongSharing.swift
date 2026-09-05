import SwiftUI
import UniformTypeIdentifiers
import CoreTransferable

/// SwiftUI/iOS plumbing for sharing and importing songs — the UI side of `SongTransfer`.
///
/// The share sheet (`ShareLink`) exports an `ExportedSong` as a `.maelzelsong` file (JSON); the file can be
/// AirDropped, saved to Files/iCloud, or sent to a student. Import comes back in via a document picker
/// (`.fileImporter`) or open-in (`.onOpenURL`) — both route through `SongImport.song(from:)`.

/// The app's exported song document type (also declared in Info.plist so an opened/AirDropped file routes
/// here). The bytes are plain JSON; it conforms to `public.json`.
extension UTType {
    static let maelzelSong = UTType(exportedAs: "app.metronome.mobile.song")
}

/// A `Transferable` song for `ShareLink`, written lazily to a temp `.maelzelsong` file named after the song.
struct ExportedSong: Transferable {
    let song: Song

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .maelzelSong) { exported in
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent(SongTransfer.suggestedFileName(for: exported.song))
            try SongTransfer.encode(exported.song).write(to: url, options: .atomic)
            return SentTransferredFile(url)
        }
    }
}

/// Reads an imported / opened document URL into a `Song` (handling security-scoped access), or `nil`.
enum SongImport {
    static func song(from url: URL) -> Song? {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? SongTransfer.decode(data)
    }
}
