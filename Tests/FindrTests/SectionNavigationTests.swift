import Testing
@testable import Findr
@testable import FindrCore

@MainActor
struct SectionNavigationTests {
    private func model(names: Int = 12, inside: Int = 8) -> SearchModel {
        let model = SearchModel()
        let names = (0..<names).map {
            ResultItem(candidate: Candidate(path: "/tmp/name\($0).pdf"), section: .name,
                       tier: .exact, pickCount: 0, copies: [])
        }
        let inside = (0..<inside).map {
            ResultItem(candidate: Candidate(path: "/tmp/inside\($0).pdf"), section: .inside,
                       tier: nil, pickCount: 0, copies: [])
        }
        model.apply(SearchSnapshot(query: QueryParser.parse(""),
                                   output: Assembler.Output(name: names, inside: inside),
                                   notice: nil, searching: false), generation: 0)
        return model
    }

    @Test func overviewLimitsEachSectionAndArrowsCrossToInside() {
        let model = model()
        #expect(model.visibleName.count == 5)
        #expect(model.visibleInside.count == 5)
        for _ in 0..<5 { model.moveDown() }
        #expect(model.selectedItem?.candidate.path == "/tmp/inside0.pdf")
        for _ in 0..<30 { model.moveDown() }
        #expect(model.selected == 9)
    }

    @Test func expansionAndBackPreserveVisibleSelection() {
        let model = model()
        model.selected = 7
        let selected = model.selectedItem?.id
        model.showAll(.inside)
        #expect(model.flat.count == 8)
        #expect(model.visibleName.isEmpty)
        #expect(model.selectedItem?.id == selected)
        model.showOverview()
        #expect(model.flat.count == 10)
        #expect(model.selectedItem?.id == selected)
    }

    @Test func backFromDeepResultResetsToValidSelection() {
        let model = model()
        model.showAll(.name)
        model.selected = 11
        model.showOverview()
        #expect(model.selected == 0)
        #expect(model.selectedItem?.id == "/tmp/name0.pdf")
    }

    @Test func newQueryRestoresOverview() {
        let model = model()
        model.showAll(.inside)
        model.text = "new query"
        #expect(model.expandedSection == nil)
        #expect(model.selected == 0)
        model.reset()
    }

    @Test func changingQueryImmediatelyInvalidatesActions() {
        let model = model()
        #expect(model.selectedItem != nil)
        model.text = "different search"
        #expect(model.selectedItem == nil)
        #expect(model.name.isEmpty)
        #expect(model.inside.isEmpty)
        model.reset()
    }

    @Test func singleSectionAndSmallResultsStayAccessible() {
        let model = model(names: 0, inside: 3)
        #expect(model.visibleName.isEmpty)
        #expect(model.flat.count == 3)
        model.moveDown()
        #expect(model.selectedItem?.section == .inside)
    }
}
