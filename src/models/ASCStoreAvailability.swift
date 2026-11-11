// Modified for the AmoSystems Blitz Neo maintenance fork (2026).

/// Confirmed store availability. Failed or incomplete reads are represented by
/// a thrown error, so callers can keep unknown state separate from unavailable.
enum ASCStoreAvailability: String, Codable, Sendable, Equatable {
    case available
    case unavailable
}
