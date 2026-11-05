import Testing
@testable import LiberttyApp

/// ⌘J's order: waiting for you, then failed, then finished, then unseen.
struct AttentionTests {
    final class Pane { let name: String; init(_ name: String) { self.name = name } }

    @Test func ranks() {
        #expect(AttentionJump.rank(status: .blocked, unseen: false) == 0)
        #expect(AttentionJump.rank(status: .error, unseen: true) == 1)
        #expect(AttentionJump.rank(status: .done, unseen: false) == 2)
        #expect(AttentionJump.rank(status: .working, unseen: true) == 3)
        #expect(AttentionJump.rank(status: .working, unseen: false) == nil)
        #expect(AttentionJump.rank(status: nil, unseen: false) == nil)
    }

    @Test func goesByRankThenPlaceAndRoundAgain() {
        let a = Pane("a"), b = Pane("b"), c = Pane("c"), elsewhere = Pane("x")
        // As they stand: a (done), b (waiting), c (waiting).
        let candidates = [(item: a, rank: 2, place: 1), (item: b, rank: 0, place: 2), (item: c, rank: 0, place: 3)]
        #expect(AttentionJump.next(candidates, after: elsewhere) === b)
        #expect(AttentionJump.next(candidates, after: nil) === b)
        #expect(AttentionJump.next(candidates, after: b) === c)
        #expect(AttentionJump.next(candidates, after: c) === a)
        #expect(AttentionJump.next(candidates, after: a) === b)
    }

    /// A pane that failed is seen once you're there: the next is the one
    /// after where it stood, not the first again.
    @Test func goesOnFromAPaneThatNoLongerNeedsYou() {
        let asker = Pane("asker"), breaker = Pane("breaker"), finisher = Pane("finisher")
        let left = [(item: finisher, rank: 2, place: 1), (item: asker, rank: 0, place: 2)]
        #expect(AttentionJump.next(left, after: breaker, was: (rank: 1, place: 3)) === finisher)
        #expect(AttentionJump.next(left, after: breaker) === asker)
        // Past the last: round to the first.
        #expect(AttentionJump.next(left, after: breaker, was: (rank: 2, place: 9)) === asker)
    }

    @Test func nowhereElse() {
        let a = Pane("a")
        #expect(AttentionJump.next([(item: a, rank: 0, place: 1)], after: a) == nil)
        #expect(AttentionJump.next([(item: a, rank: 0, place: 1)], after: Pane("b")) === a)
        #expect(AttentionJump.next([(item: Pane, rank: Int, place: Int)](), after: a) == nil)
    }
}
