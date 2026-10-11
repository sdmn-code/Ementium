import Foundation
import Testing
@testable import Ementium

final class ImageDirectoryTests {
    private let folder: URL

    init() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("EmentiumTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // Тип файла определяется по расширению, содержимое для ImageDirectory не важно.
        for name in ["img-10.png", "img-2.png", "img-1.jpg", "photo.HEIC", "doc.pdf", "notes.txt", ".hidden.png"] {
            try Data().write(to: folder.appendingPathComponent(name))
        }
        // Папка с «картиночным» именем — не изображение.
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("album.png"), withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: folder)
    }

    private func url(_ name: String) -> URL { folder.appendingPathComponent(name) }

    private func names(_ directory: ImageDirectory?) -> [String] {
        directory?.images.map(\.lastPathComponent) ?? []
    }

    @Test func singleFileOpensAllImagesOfItsFolderInNaturalOrder() throws {
        let directory = try #require(ImageDirectory(opening: [url("img-2.png")]))
        #expect(names(directory) == ["img-1.jpg", "img-2.png", "img-10.png", "photo.HEIC"])
        #expect(directory.current.lastPathComponent == "img-2.png")
        #expect(directory.index == 1)
    }

    @Test func multipleFilesOpenOnlyTheSelectedImages() throws {
        let directory = try #require(ImageDirectory(opening: [url("img-10.png"), url("doc.pdf"), url("img-1.jpg")]))
        #expect(names(directory) == ["img-1.jpg", "img-10.png"])
        #expect(directory.index == 0)
    }

    @Test func duplicatesAreRemoved() throws {
        let directory = try #require(ImageDirectory(opening: [url("img-1.jpg"), url("img-1.jpg"), url("img-2.png")]))
        #expect(names(directory) == ["img-1.jpg", "img-2.png"])
    }

    @Test(arguments: [["doc.pdf"], ["notes.txt", "doc.pdf"], ["album.png"], ["missing.png"], []])
    func noImagesMeansNothingToOpen(files: [String]) {
        #expect(ImageDirectory(opening: files.map(url)) == nil)
    }

    @Test func navigationStopsAtBothEnds() throws {
        var directory = try #require(ImageDirectory(opening: [url("photo.HEIC")]))
        #expect(directory.index == 3)
        #expect(!directory.hasNext)
        let movedPastEnd = directory.moveNext()
        #expect(!movedPastEnd)
        #expect(directory.index == 3)

        let backSteps = (0..<3).map { _ in directory.movePrevious() }
        #expect(backSteps == [true, true, true])
        #expect(directory.current.lastPathComponent == "img-1.jpg")
        #expect(!directory.hasPrevious)
        let movedBeforeStart = directory.movePrevious()
        #expect(!movedBeforeStart)
        #expect(directory.index == 0)
    }

    // Временная папка лежит в /var, который на самом деле ссылка на /private/var.
    @Test func startingFileIsFoundThroughSymlinkedPath() throws {
        let resolved = url("img-10.png").resolvingSymlinksInPath()
        let directory = try #require(ImageDirectory(opening: [resolved]))
        #expect(directory.current.lastPathComponent == "img-10.png")
        #expect(directory.images.count == 4)
    }

    @Test func naturalSortMatchesFinder() {
        let sorted = ImageDirectory.sorted(["b.png", "a10.png", "a2.png", "A1.png"].map(url))
        #expect(sorted.map(\.lastPathComponent) == ["A1.png", "a2.png", "a10.png", "b.png"])
    }

    // «img-01» и «img-1» для localizedStandardCompare равны — порядок не должен зависеть от входного.
    @Test func sortIsStableForNamesThatCompareEqual() {
        let names = ["img-1.png", "img-01.png"]
        let forward = ImageDirectory.sorted(names.map(url)).map(\.lastPathComponent)
        let backward = ImageDirectory.sorted(names.reversed().map(url)).map(\.lastPathComponent)
        #expect(forward == backward)
    }

    // Два файла, один не изображение: каталог не раскрывается, остаётся единственная картинка.
    @Test func imagePlusNonImageOpensOnlyTheImage() throws {
        let directory = try #require(ImageDirectory(opening: [url("img-2.png"), url("doc.pdf")]))
        #expect(names(directory) == ["img-2.png"])
    }

    @Test func hiddenStartingFileIsShownAlone() throws {
        let directory = try #require(ImageDirectory(opening: [url(".hidden.png")]))
        #expect(names(directory) == [".hidden.png"])
    }

    @Test func previewIsTheFileThatTheFullListStartsFrom() async throws {
        for files in [["img-2.png"], ["img-10.png", "doc.pdf", "img-1.jpg"], ["doc.pdf", "photo.HEIC"]] {
            let urls = files.map(url)
            let preview = try #require(ImageDirectory(preview: urls))
            let full = try #require(await ImageDirectory.load(opening: urls))
            #expect(preview.images.count == 1)
            #expect(preview.current == full.current, "файлы: \(files)")
        }
    }

    // «Недавние»: порядок окна (не по имени), не-изображения и дубли выкидываются.
    @Test func orderedListKeepsFinderOrder() throws {
        let window = ["photo.HEIC", "doc.pdf", "img-10.png", "img-1.jpg", "img-10.png", "notes.txt", "img-2.png"].map(url)
        let directory = try #require(ImageDirectory(ordered: window, current: url("img-1.jpg")))
        #expect(names(directory) == ["photo.HEIC", "img-10.png", "img-1.jpg", "img-2.png"])
        #expect(directory.index == 2)
    }

    @Test func orderedListWithoutCurrentFileIsNil() {
        #expect(ImageDirectory(ordered: [url("img-1.jpg"), url("img-2.png")], current: url("photo.HEIC")) == nil)
        #expect(ImageDirectory(ordered: [], current: url("photo.HEIC")) == nil)
    }

    // Список окна может прийти с путями через /private/var — текущий файл всё равно находится,
    // и остаётся тем URL, который передали.
    @Test func orderedListFindsCurrentThroughResolvedPaths() throws {
        let window = ["img-1.jpg", "img-2.png"].map { url($0).resolvingSymlinksInPath() }
        let directory = try #require(ImageDirectory(ordered: window, current: url("img-2.png")))
        #expect(directory.current == url("img-2.png"))
        #expect(directory.index == 1)
    }

    @Test func moveBySeveralStepsStopsAtEdges() throws {
        var directory = try #require(ImageDirectory(opening: [url("img-2.png")]))  // 1 из 0…3
        let forward = directory.move(by: 10)
        #expect(forward)
        #expect(directory.index == 3)
        let back = directory.move(by: -2)
        #expect(back)
        #expect(directory.index == 1)
        let beyondStart = directory.move(by: -5)
        #expect(beyondStart)
        #expect(directory.index == 0)
        let stuck = directory.move(by: -1)
        #expect(!stuck)
        let zero = directory.move(by: 0)
        #expect(!zero)
    }

    @Test func previewWithoutImagesIsNil() {
        #expect(ImageDirectory(preview: [url("doc.pdf"), url("notes.txt")]) == nil)
    }

    @Test func backgroundLoadMatchesSynchronousInit() async throws {
        let urls = [url("img-2.png")]
        let loaded = await ImageDirectory.load(opening: urls)
        #expect(loaded == ImageDirectory(opening: urls))
    }

    @Test func sameFileThroughDifferentPathsIsCountedOnce() throws {
        let direct = url("img-1.jpg")
        let resolved = direct.resolvingSymlinksInPath()
        let directory = try #require(ImageDirectory(opening: [direct, resolved, url("img-2.png")]))
        #expect(names(directory) == ["img-1.jpg", "img-2.png"])
    }
}
