import Foundation
import Testing
@testable import CueKit

@Suite struct ScreenshotTests {
    let home = URL(filePath: "/Users/tester", directoryHint: .isDirectory)
    let desktop = URL(filePath: "/Users/tester/Desktop", directoryHint: .isDirectory)

    func folder(_ location: String?, exists: Bool = true) -> URL {
        Screenshot.folder(location: location, home: home) { _ in exists }
    }

    @Test func folderComesFromTheLocationPreference() {
        #expect(folder(nil) == desktop)
        #expect(folder("") == desktop)
        #expect(folder("  ") == desktop)
        #expect(folder("/Users/tester/Pictures/Shots").path == "/Users/tester/Pictures/Shots")
        #expect(folder("/Users/tester/Pictures/Shots/").path == "/Users/tester/Pictures/Shots")
        #expect(folder("~/Pictures").path == "/Users/tester/Pictures")
        #expect(folder("~").path == "/Users/tester")
        #expect(folder("/Volumes/Work/../Shots").path == "/Volumes/Shots")
    }

    @Test func folderFallsBackToDesktopWhenTheLocationIsNotAFolder() {
        #expect(folder("/Users/tester/Gone", exists: false) == desktop)
        #expect(folder("Pictures") == desktop)
        #expect(folder("~someone/Pictures") == desktop)
    }

    @Test func filterAdmitsOnlyNewScreenshotImagesOnce() {
        let start = Date(timeIntervalSince1970: 1_000_000)
        let after = start.addingTimeInterval(1)
        var filter = ScreenshotFilter(start: start)
        let cases: [(path: String, type: String?, created: Date?, admitted: Bool)] = [
            ("/a.png", "public.png", after, true),
            ("/a.png", "public.png", after, false),
            ("/b.jpg", "public.jpeg", start, true),
            ("/c.heic", "public.heic", after, true),
            ("/d.tiff", "public.tiff", after, true),
            ("/old.png", "public.png", start.addingTimeInterval(-1), false),
            ("/clip.mov", "com.apple.quicktime-movie", after, false),
            ("/shot.pdf", "com.adobe.pdf", after, false),
            ("/unknown.png", nil, after, false),
            ("/undated.png", "public.png", nil, false),
        ]
        for item in cases {
            let admitted = filter.admit(path: item.path, type: item.type, created: item.created)
            #expect(admitted == item.admitted, "\(item.path)")
        }
    }
}
