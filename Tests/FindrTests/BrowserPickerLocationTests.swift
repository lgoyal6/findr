import Foundation
import AppKit
import Testing
@testable import Findr
import FindrCore
@testable import LeafBrowserBridge

@MainActor
struct BrowserPickerLocationTests {
    @Test func mixedFolderAndFileSelectionChoosesFilesWithoutNavigating() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data("file".utf8).write(to: directory.appendingPathComponent("file.txt"))
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("folder"), withIntermediateDirectories: true)
        let request = BrowserUploadRequest(origin: "https://example.test", accept: "", multiple: true, created: Date())
        let model = BrowserFilePickerModel(request: request)
        defer { model.stop() }
        model.navigate(directory)
        let initial = model.location
        model.sortOrder = [KeyPathComparator(\BrowserFileRow.name, order: .reverse)]
        model.selection = Set(model.rows.map(\.id))
        var chose = false
        model.openSelection { chose = true }
        #expect(chose)
        #expect(model.location == initial)
    }

    @Test func gridRangeSelectionAndSingleFolderActions() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        for name in ["a.txt", "b.txt", "c.txt", "d.txt"] {
            try Data(name.utf8).write(to: directory.appendingPathComponent(name))
        }
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("folder"), withIntermediateDirectories: true)
        let request = BrowserUploadRequest(origin: "https://example.test", accept: "", multiple: true, created: Date())
        let model = BrowserFilePickerModel(request: request)
        defer { model.stop() }
        model.navigate(directory)
        model.sortOrder = [KeyPathComparator(\BrowserFileRow.name)]
        let rows = model.rows
        model.select(rows[0], modifiers: [])
        model.moveSelection(by: 1, extending: true)
        #expect(model.selection == Set(rows.prefix(2).map(\.id)))
        model.moveSelection(by: 1, extending: true)
        #expect(model.selection == Set(rows.prefix(3).map(\.id)))
        model.select(rows[2], modifiers: .shift)
        #expect(model.selection == Set(rows.prefix(3).map(\.id)))
        model.select(rows[3], modifiers: .command)
        #expect(model.selectedFiles.count == 4)
        model.select(rows[3], modifiers: .command)
        #expect(model.selectedFiles.count == 3)
        model.select(try #require(rows.first { $0.directory }), modifiers: [])
        #expect(!model.canChoose)
        #expect(model.canOpenSelection)
        model.openSelection { Issue.record("A folder must open without uploading") }
        #expect(model.location.folder?.lastPathComponent == "folder")
    }

    @Test func folderChangesRefreshAndPreserveValidSelection() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data("first".utf8).write(to: directory.appendingPathComponent("first.txt"))
        try Data("hidden".utf8).write(to: directory.appendingPathComponent(".hidden.txt"))
        let request = BrowserUploadRequest(origin: "https://example.test", accept: "", multiple: true, created: Date())
        let model = BrowserFilePickerModel(request: request)
        defer { model.stop() }
        model.navigate(directory)
        #expect(model.rows.count == 1)
        model.selection = Set(model.rows.map(\.id))
        let selected = model.selection
        try Data("new".utf8).write(to: directory.appendingPathComponent("new.txt"))
        for _ in 0..<100 {
            if model.rows.contains(where: { $0.name == "new.txt" }) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(model.rows.contains { $0.name == "new.txt" })
        #expect(model.selection == selected)
        model.showHiddenFiles = true
        #expect(model.rows.contains { $0.name == ".hidden.txt" })
        try FileManager.default.removeItem(at: directory.appendingPathComponent("first.txt"))
        model.refresh()
        #expect(model.selection.isEmpty)
        #expect(model.rows.count == 2)
    }

    @Test func goToFolderRejectsMissingPathsAndSupportsHomeAndRelativePaths() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let child = directory.appendingPathComponent(".child", isDirectory: true)
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        try Data("visible".utf8).write(to: child.appendingPathComponent("visible.txt"))
        defer { try? FileManager.default.removeItem(at: directory) }
        let request = BrowserUploadRequest(origin: "https://example.test", accept: "", multiple: false, created: Date())
        let model = BrowserFilePickerModel(request: request)
        defer { model.stop() }
        #expect(model.goToFolder(directory.path))
        #expect(model.goToFolder(".child"))
        #expect(model.location.folder?.lastPathComponent == ".child")
        #expect(model.rows.map(\.name) == ["visible.txt"])
        let initial = model.location
        #expect(!model.goToFolder("/missing/" + UUID().uuidString))
        #expect(model.location == initial)
        #expect(model.error != nil)
        model.goToParent()
        #expect(model.location.folder?.lastPathComponent == directory.lastPathComponent)
        #expect(model.goToFolder("~"))
        #expect(model.location.folder == FileManager.default.homeDirectoryForCurrentUser)
    }

    @Test func folderFilesDefaultToNewestModifiedFirst() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        for (name, age) in [("a-old.txt", -86_400.0), ("z-new.txt", 0.0)] {
            let url = directory.appendingPathComponent(name)
            try Data(name.utf8).write(to: url)
            try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(age)], ofItemAtPath: url.path)
        }
        let request = BrowserUploadRequest(origin: "https://example.test", accept: ".txt", multiple: false, created: Date())
        let model = BrowserFilePickerModel(request: request)
        defer { model.stop() }
        model.navigate(directory)
        #expect(model.rows.map(\.name) == ["z-new.txt", "a-old.txt"])
        model.sortOrder = [KeyPathComparator(\BrowserFileRow.name)]
        #expect(model.rows.map(\.name) == ["a-old.txt", "z-new.txt"])
        model.sortOrder = [KeyPathComparator(\BrowserFileRow.modifiedForSorting)]
        #expect(model.rows.map(\.name) == ["a-old.txt", "z-new.txt"])
    }

    @Test func filtersKeepFoldersNavigableAndInvalidateHiddenSelections() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let folder = directory.appendingPathComponent("folder", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for (name, age) in [("old.txt", -40 * 86_400.0), ("new.txt", 0.0), ("photo.png", 0.0)] {
            let url = directory.appendingPathComponent(name)
            try Data(name.utf8).write(to: url)
            try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(age)], ofItemAtPath: url.path)
        }
        let request = BrowserUploadRequest(origin: "https://example.test", accept: ".txt", multiple: true, created: Date())
        let model = BrowserFilePickerModel(request: request)
        defer { model.stop() }
        model.navigate(directory)
        #expect(Set(model.rows.map(\.name)) == ["folder", "old.txt", "new.txt"])
        model.selection = Set(model.rows.filter { $0.name == "old.txt" }.map(\.id))
        #expect(model.canChoose)
        model.modifiedSince = "This month"
        #expect(model.selection.isEmpty)
        #expect(Set(model.rows.map(\.name)) == ["folder", "new.txt"])
        model.matchingTypesOnly = false
        model.fileKind = .image
        #expect(Set(model.rows.map(\.name)) == ["folder", "photo.png"])
        model.selection = Set(model.rows.filter { $0.name == "photo.png" }.map(\.id))
        #expect(!model.canChoose)
        model.fileKind = nil
        model.modifiedSince = "Any date"
        #expect(model.rows.count == 4)
    }

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
