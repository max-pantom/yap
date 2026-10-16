import CryptoKit
import Foundation
import Network

/// The wire protocol between Yap on the Mac and the Yap Mic iPhone app. Shared by both targets.
///
/// Pairing: the Mac shows a QR code holding a random 256-bit key. Both sides then connect over TLS with that
/// pre-shared key, found through Bonjour on the local network. Nobody without the key can connect or listen in.
///
/// Frames: 1 byte kind, 4 bytes big-endian length, payload.
enum MicLink {
    static let serviceType = "_yapmic._tcp"
    static let sampleRate = 16_000.0

    enum Kind: UInt8 {
        case hello = 1      // phone → Mac: JSON Hello
        case begin = 2      // phone → Mac: JSON Begin, start dictating
        case audio = 3      // phone → Mac: 16 kHz mono Int16 little-endian PCM
        case end = 4        // phone → Mac: finished talking, paste it
        case cancel = 5     // phone → Mac: throw it away
        case status = 16    // Mac → phone: JSON Status
    }

    struct Hello: Codable { var name: String; var version = 1 }
    struct Begin: Codable { var command = false }
    struct Status: Codable, Equatable {
        enum State: String, Codable { case ready, listening, thinking, done, error, busy }
        var state: State
        var text: String?
    }

    // MARK: Pairing

    struct Pairing: Equatable {
        var service: String     // Bonjour name of this Mac's listener, e.g. "Yap-3FA9C1"
        var macName: String
        var key: Data           // 32 random bytes

        static func generate(macName: String) -> Pairing {
            let key = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
            let id = (0..<3).map { _ in String(format: "%02X", UInt8.random(in: 0...255)) }.joined()
            return Pairing(service: "Yap-\(id)", macName: macName, key: key)
        }

        var url: URL {
            var c = URLComponents()
            c.scheme = "yapmic"; c.host = "pair"
            c.queryItems = [.init(name: "s", value: service), .init(name: "n", value: macName), .init(name: "k", value: Self.b64url(key))]
            return c.url!
        }

        init(service: String, macName: String, key: Data) { self.service = service; self.macName = macName; self.key = key }

        init?(url: URL) {
            guard url.scheme == "yapmic", url.host == "pair",
                  let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
                  let s = items.first(where: { $0.name == "s" })?.value, s.hasPrefix("Yap-"),
                  let k = items.first(where: { $0.name == "k" })?.value.flatMap(Self.unb64url), k.count == 32 else { return nil }
            self.init(service: s, macName: items.first { $0.name == "n" }?.value ?? "Mac", key: k)
        }

        static func b64url(_ d: Data) -> String {
            d.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        }
        static func unb64url(_ s: String) -> Data? {
            var t = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
            while t.count % 4 != 0 { t += "=" }
            return Data(base64Encoded: t)
        }
    }

    /// TLS 1.2 with a pre-shared key derived from the pairing key (Apple's peer-to-peer pattern).
    static func parameters(_ pairing: Pairing) -> NWParameters {
        let tls = NWProtocolTLS.Options()
        let identity = Data(pairing.service.utf8)
        let psk = Data(HMAC<SHA256>.authenticationCode(for: identity, using: SymmetricKey(data: pairing.key)))
        let pskData = psk.withUnsafeBytes { DispatchData(bytes: $0) }
        let idData = identity.withUnsafeBytes { DispatchData(bytes: $0) }
        sec_protocol_options_add_pre_shared_key(tls.securityProtocolOptions, pskData as __DispatchData, idData as __DispatchData)
        sec_protocol_options_append_tls_ciphersuite(tls.securityProtocolOptions, tls_ciphersuite_t(rawValue: UInt16(TLS_PSK_WITH_AES_128_GCM_SHA256))!)
        // Every connection proves it has the key; no shortcuts through a cached session.
        sec_protocol_options_set_tls_resumption_enabled(tls.securityProtocolOptions, false)
        sec_protocol_options_set_tls_tickets_enabled(tls.securityProtocolOptions, false)
        let tcp = NWProtocolTCP.Options()
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 5
        tcp.noDelay = true
        let params = NWParameters(tls: tls, tcp: tcp)
        params.includePeerToPeer = true
        return params
    }

    // MARK: Framing

    static func frame(_ kind: Kind, _ payload: Data = Data()) -> Data {
        var d = Data([kind.rawValue])
        var n = UInt32(payload.count).bigEndian
        d.append(Data(bytes: &n, count: 4))
        d.append(payload)
        return d
    }

    static func frame<T: Encodable>(_ kind: Kind, json: T) -> Data {
        frame(kind, (try? JSONEncoder().encode(json)) ?? Data())
    }

    /// Reassembles frames from a byte stream.
    struct Reader {
        private var buffer = Data()
        static let maxFrame = 1 << 20

        /// Returns complete frames; nil if the stream is malformed (close the connection).
        mutating func append(_ data: Data) -> [(Kind, Data)]? {
            buffer.append(data)
            var out: [(Kind, Data)] = []
            while buffer.count >= 5 {
                let start = buffer.startIndex
                let len = Int(buffer[start + 1]) << 24 | Int(buffer[start + 2]) << 16 | Int(buffer[start + 3]) << 8 | Int(buffer[start + 4])
                guard len <= Self.maxFrame else { return nil }
                guard buffer.count >= 5 + len else { break }
                let kindByte = buffer[start]
                let payload = buffer.subdata(in: (start + 5)..<(start + 5 + len))
                buffer.removeSubrange(start..<(start + 5 + len))
                if let kind = Kind(rawValue: kindByte) { out.append((kind, payload)) }
            }
            return out
        }
    }
}
