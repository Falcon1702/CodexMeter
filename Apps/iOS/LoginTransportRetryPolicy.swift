import Foundation

/// Network failures that may be caused by iOS suspending a foreground-only
/// request while another app (for example Safari) takes over the screen.
/// Callers must still verify that the surrounding login task is current before
/// retrying; this policy intentionally does not decide logical cancellation.
enum LoginTransportRetryPolicy {
    static func isRetryable(_ error: Error) -> Bool {
        guard let urlError = error as? URLError else { return false }
        return [
            .cancelled,
            .timedOut,
            .cannotFindHost,
            .cannotConnectToHost,
            .networkConnectionLost,
            .dnsLookupFailed,
            .notConnectedToInternet,
            .resourceUnavailable,
            .dataNotAllowed,
            .backgroundSessionWasDisconnected,
        ].contains(urlError.code)
    }
}
