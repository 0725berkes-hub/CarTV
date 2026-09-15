import Foundation
import CryptoKit

/// TikTok web-API request signature. Appended as `&X-Bogus=…` to `/api/*` calls.
///
/// Without it the server answers 200 with an empty body. The algorithm is a fixed
/// construction over the query string, the User-Agent and the current time — no
/// server round-trip, no JS engine. Faithful port of the community reference
/// (iamtorsten/tiktok-api `Web/bogus.py`, updated 2026-03) which matches the
/// webmssdk behaviour. Verified against the live `/api/recommend/item_list/`.
nonisolated enum XBogus {

    private static let alphabet = Array("Dkdpgh4ZKsQB80/Mfvw36XI1R25-WUAlEi7NLboqYTOPuzmFjJnryx9HVGcaStCe")
    private static let magic: UInt32 = 536_919_696

    /// `query` is the URL query string *without* the leading `?` and without X-Bogus.
    static func sign(query: String, body: Data = Data(), userAgent: String, now: Date = .now) -> String {
        let ts = UInt32(now.timeIntervalSince1970)

        let md5Params = md5(Data(md5(Data(query.utf8))))            // md5 over the raw 16-byte digest
        let md5Data   = md5(Data(md5(body)))
        let md5UA     = md5(Data(b64(rc4(latin1(userAgent), key: [0, 1, 14])).utf8))

        // salt_list as in the reference: [ts, magic, 64, 0, 1, 14, p[-2], p[-1], d[-2], d[-1], u[-2], u[-1],
        //   ts>>24, ts>>16, ts>>8, ts, magic>>24, magic>>16, magic>>8, magic, checksum, 255]
        var salt: [UInt32] = [ts, magic, 64, 0, 1, 14,
                              UInt32(md5Params[14]), UInt32(md5Params[15]),
                              UInt32(md5Data[14]),   UInt32(md5Data[15]),
                              UInt32(md5UA[14]),     UInt32(md5UA[15])]
        salt += [ts >> 24 & 0xFF, ts >> 16 & 0xFF, ts >> 8 & 0xFF, ts & 0xFF]
        salt += [magic >> 24 & 0xFF, magic >> 16 & 0xFF, magic >> 8 & 0xFF, magic & 0xFF]
        var checksum: UInt32 = 64
        for x in salt.dropFirst(3) { checksum ^= x }
        salt += [checksum, 255]

        // filter: 1-based indices [3,5,7,…,21, 4,6,…,20] → 19 values
        let order = [3, 5, 7, 9, 11, 13, 15, 17, 19, 21, 4, 6, 8, 10, 12, 14, 16, 18, 20]
        let picked = order.map { UInt8(truncatingIfNeeded: salt[$0 - 1]) }

        // scramble: a,k,b,l,c,m,d,n,e,o,f,p,g,q,h,r,i,s,j
        var scrambled: [UInt8] = []
        for i in 0..<9 { scrambled.append(picked[i]); scrambled.append(picked[i + 10]) }
        scrambled.append(picked[9])

        let enc = rc4(scrambled, key: [255])
        return b64([0x02, 0xFF] + enc, alphabet: alphabet)
    }

    // MARK: Primitives (byte-for-byte with the Python reference, which works on latin-1 "strings")

    private static func md5(_ d: Data) -> [UInt8] { Array(Insecure.MD5.hash(data: d)) }

    private static func latin1(_ s: String) -> [UInt8] { s.unicodeScalars.map { UInt8(truncatingIfNeeded: $0.value) } }

    private static func rc4(_ data: [UInt8], key: [UInt8]) -> [UInt8] {
        var S = (0...255).map { UInt8($0) }
        var j = 0
        for i in 0..<256 {
            j = (j + Int(S[i]) + Int(key[i % key.count])) & 0xFF
            S.swapAt(i, j)
        }
        var out = [UInt8](); out.reserveCapacity(data.count)
        var i = 0; j = 0
        for byte in data {
            i = (i + 1) & 0xFF
            j = (j + Int(S[i])) & 0xFF
            S.swapAt(i, j)
            out.append(byte ^ S[(Int(S[i]) + Int(S[j])) & 0xFF])
        }
        return out
    }

    private static let stdAlphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/=")

    /// Reference b64: groups of 3; a short final group yields index 64 ('=') for the last two slots.
    private static func b64(_ b: [UInt8], alphabet: [Character]? = nil) -> String {
        let table = (alphabet ?? stdAlphabet) + (alphabet != nil ? ["="] : [])
        var s = ""
        var i = 0
        while i < b.count {
            let n1 = Int(b[i])
            if i + 2 < b.count {
                let n2 = Int(b[i + 1]), n3 = Int(b[i + 2])
                s.append(table[n1 >> 2]); s.append(table[(3 & n1) << 4 | n2 >> 4])
                s.append(table[(15 & n2) << 2 | n3 >> 6]); s.append(table[63 & n3])
            } else {
                s.append(table[n1 >> 2]); s.append(table[(3 & n1) << 4])
                s.append(table[64]); s.append(table[64])
            }
            i += 3
        }
        return s
    }
}
