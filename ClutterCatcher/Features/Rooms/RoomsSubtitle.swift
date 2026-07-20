import Foundation

/// U4: what the line under the Rooms large title says. The subtitle grows up
/// with the catalog — aspiration until the first container exists anywhere,
/// confident counts from then on. The threshold is deliberately "any
/// container at all": it's the only non-arbitrary boundary, and the moment
/// the first bin exists the counts line has something true to say.
enum RoomsSubtitle: Equatable {
    case aspirational
    case counts(rooms: Int, containers: Int)

    static func subtitle(roomCount: Int, containerCount: Int) -> RoomsSubtitle {
        containerCount == 0
            ? .aspirational
            : .counts(rooms: roomCount, containers: containerCount)
    }
}
