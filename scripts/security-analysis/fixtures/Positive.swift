import Foundation

// Harmless reach test: this function is compiled but never called.
// No URLSession is created, and no request or credential is involved.
func insecureTLSPositiveFixture() -> URLSessionConfiguration {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.tlsMinimumSupportedProtocolVersion = .TLSv10
    return configuration
}
