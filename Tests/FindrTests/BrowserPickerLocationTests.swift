import Foundation
import Testing
@testable import Findr
@testable import LeafBrowserBridge

@MainActor
struct BrowserPickerLocationTests {
    @Test func virtualLocationsSurviveHistoryAndClearSelection() {
        let request = BrowserUploadRequest(origin: "https://example.test", accept: "", multiple: false, created: Date())
        let model = BrowserFilePickerModel(request: request)
        defer { model.stop() }
        let initial = model.location
        model.navigate(.recents)
        model.selection = ["/example.txt"]
        model.navigate(.tag("Red"))
        #expect(model.selection.isEmpty)
        #expect(model.ancestors.isEmpty)
        model.goBack()
        #expect(model.location == .recents)
        model.goBack()
        #expect(model.location == initial)
        model.goForward()
        #expect(model.location == .recents)
        model.navigate(.shared)
        #expect(!model.canGoForward)
    }

    @Test func sidebarIncludesOnlyExistingCloudFolders() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let absent = BrowserSidebarSection.available(home: home)
        #expect(!absent.contains { $0.title == "iCloud & Cloud Storage" })
        let cloud = home.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs")
        let provider = home.appendingPathComponent("Library/CloudStorage/Example Drive")
        for url in [cloud, provider] {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        let sections = BrowserSidebarSection.available(home: home)
        let locations = sections.flatMap(\.items).map(\.location)
        let paths = locations.compactMap { $0.folder?.resolvingSymlinksInPath().path }
        #expect(paths.contains(cloud.resolvingSymlinksInPath().path))
        #expect(paths.contains(provider.resolvingSymlinksInPath().path))
        #expect(locations.contains(.recents))
        #expect(locations.contains(.shared))
        #expect(locations.contains(.allTags))
    }

    @Test func unavailableFolderShowsErrorAndCanNavigateBack() {
        let request = BrowserUploadRequest(origin: "https://example.test", accept: "", multiple: false, created: Date())
        let model = BrowserFilePickerModel(request: request)
        defer { model.stop() }
        let initial = model.location
        model.navigate(URL(fileURLWithPath: "/Volumes/" + UUID().uuidString))
        #expect(model.error != nil)
        #expect(model.rows.isEmpty)
        #expect(!model.canChoose)
        model.goBack()
        #expect(model.location == initial)
        #expect(model.error == nil)
    }
}
