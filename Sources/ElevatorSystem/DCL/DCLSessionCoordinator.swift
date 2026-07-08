import Foundation

/// Coordinates the set of live DCL sessions -- GUI terminal windows and
/// telnet connections -- so that exactly ONE of them owns the in-universe
/// status-mail generator.
///
/// Every attached `DCLEngine` watches the same world, and each would append
/// the same SCADA / OPCOM notice to the shared `MAILBOX.JSON`. With more than
/// one session open the inbox would fill with duplicate copies of every
/// event. Electing a single writer keeps one copy per event; the other
/// sessions still read the same shared inbox.
///
/// The writer is simply the first still-alive registered engine. When it
/// goes away (window closed / telnet disconnected) the next survivor takes
/// over -- `enableInUniverseMail()` re-watermarks against the current world
/// state, so a handover never backfills or double-mails events raised while
/// the new writer was a passive session.
@MainActor
final class DCLSessionCoordinator: ObservableObject {
    private struct WeakEngine {
        weak var engine: DCLEngine?
    }

    /// Registered engines in arrival order; the first live one is the writer.
    private var engines: [WeakEngine] = []

    /// Add a session and (re-)elect the in-universe mail writer.
    func register(_ engine: DCLEngine) {
        prune()
        if !engines.contains(where: { $0.engine === engine }) {
            engines.append(WeakEngine(engine: engine))
        }
        reassignWriter()
    }

    /// Remove a session and hand the writer role to the next survivor.
    func unregister(_ engine: DCLEngine) {
        engines.removeAll { $0.engine == nil || $0.engine === engine }
        reassignWriter()
    }

    private func prune() {
        engines.removeAll { $0.engine == nil }
    }

    /// Enable in-universe mail on the first live engine and disable it on the
    /// rest, so exactly one writer exists while any session is alive.
    private func reassignWriter() {
        prune()
        var elected = false
        for entry in engines {
            guard let engine = entry.engine else { continue }
            if !elected {
                engine.enableInUniverseMail()
                elected = true
            } else {
                engine.disableInUniverseMail()
            }
        }
    }
}
