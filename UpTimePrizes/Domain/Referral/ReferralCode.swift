import Foundation
import CryptoKit

// MARK: - ReferralCode
//
// The affiliate code, as the iPhone handles it, entirely offline.
//
// ONE code per affiliate, the same on both platforms (founder's ruling,
// 8 November 2026: the code is a name, e.g. `katie`). The backend's
// `uptime-affiliate-backend/functions/src/codes.ts` is the source this file
// mirrors; Android mirrors it in `ReferralCodeRules.kt`. Change it there
// first.
//
// How a referral reaches the affiliate on iOS, with no network call from the
// app: the code is turned into a UUID here, that UUID goes into the purchase
// as StoreKit's `appAccountToken`, Apple carries it to the App Store Server
// Notifications endpoint inside the signed transaction, and the endpoint
// derives the same UUID for every active code and matches
// (`functions/src/appStore/appStoreMapping.ts`).
//
// The token is fixed on each purchase. A code entered after a purchase does
// not credit that purchase. No code saved → no token → no referral.
//
// The code unlocks nothing and changes nothing for the buyer (guideline
// 3.1.1).

enum ReferralCode {

    // MARK: Derivation — must agree byte for byte with the backend

    /// UUIDv5(DNS namespace, "affiliate.uptimeprizes.com"). Published by the
    /// App Builder, 8 Nov 2026; recomputed independently in the tests.
    static let namespace = UUID(uuidString: "c073b658-63a9-5686-b284-4f5ccf51c7a4")!

    /// RFC 4122 DNS namespace, used only to re-derive `namespace` in the check.
    static let dnsNamespace = UUID(uuidString: "6ba7b810-9dad-11d1-80b4-00c04fd430c8")!
    static let namespaceName = "affiliate.uptimeprizes.com"

    /// The App Builder's published check value: "katie" → this UUID.
    static let checkCode = "katie"
    static let checkToken = UUID(uuidString: "df49c53c-4d1e-59a3-931b-28d68b424f06")!

    /// Trim then lowercase — the same normalisation on every side, before any
    /// check or hash.
    static func normalize(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// The STORED-code shape, `^[a-z0-9][a-z0-9_-]{1,63}$`: what a lookup
    /// accepts. A typed code is a lookup. (The issuance rule that also refuses
    /// 0 and 1 runs on the server when a code is minted, not here: a buyer
    /// typing `test001` is typing a code that exists.)
    ///
    /// Checked character by character rather than by regex so that only ASCII
    /// can ever reach the hash — whatever Unicode rules a platform applies when
    /// trimming or lowercasing, a code that passes here is the same bytes on
    /// every side.
    static func isValid(_ raw: String) -> Bool {
        let code = Array(normalize(raw).unicodeScalars)
        guard (2...64).contains(code.count) else { return false }
        // ASCII code points: a–z 97–122, 0–9 48–57, "-" 45, "_" 95.
        func isLowerOrDigit(_ s: Unicode.Scalar) -> Bool {
            (97...122).contains(s.value) || (48...57).contains(s.value)
        }
        guard isLowerOrDigit(code[0]) else { return false }
        return code.dropFirst().allSatisfy { isLowerOrDigit($0) || $0.value == 45 || $0.value == 95 }
    }

    /// The `appAccountToken` for a code, or nil if the code has the wrong shape.
    static func token(for raw: String) -> UUID? {
        guard isValid(raw) else { return nil }
        return uuidV5(namespace: namespace, name: normalize(raw))
    }

    /// RFC 4122 version 5: SHA-1 over the namespace's 16 bytes followed by the
    /// name's UTF-8 bytes; the first 16 bytes of the digest, version nibble 5,
    /// variant bits 10.
    static func uuidV5(namespace: UUID, name: String) -> UUID {
        var input = withUnsafeBytes(of: namespace.uuid) { Data($0) }
        input.append(contentsOf: Array(name.utf8))
        var b = Array(Insecure.SHA1.hash(data: input))
        b[6] = (b[6] & 0x0F) | 0x50
        b[8] = (b[8] & 0x3F) | 0x80
        return UUID(uuid: (b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7],
                           b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15]))
    }

    /// True when this build's derivation reproduces both published values.
    /// Logged at every launch, pass or fail (Protocol rule 4).
    static func derivationMatchesBackend() -> Bool {
        uuidV5(namespace: dnsNamespace, name: namespaceName) == namespace
            && token(for: checkCode) == checkToken
    }

    // MARK: Storage — on the phone only

    private static let storageKey = "referral.code"

    /// The code saved on this phone, already normalised; nil when none.
    static var savedCode: String? {
        guard let code = UserDefaults.standard.string(forKey: storageKey), isValid(code) else { return nil }
        return code
    }

    /// Saves a typed code. Returns the normalised code, or nil (and saves
    /// nothing) when it does not have the shape of a code.
    @discardableResult
    static func save(_ raw: String) -> String? {
        let length = raw.count
        guard isValid(raw) else {
            UpTimeLog.referral.notice("[REFERRAL] typed code refused by the shape check (length \(length, privacy: .public))")
            return nil
        }
        let code = normalize(raw)
        UserDefaults.standard.set(code, forKey: storageKey)
        let tokenText = token(for: code)?.uuidString.lowercased() ?? "none"
        UpTimeLog.referral.notice("[REFERRAL] code saved on this phone: \(code, privacy: .public) token=\(tokenText, privacy: .public)")
        return code
    }

    /// The token for the next purchase: the saved code's, or nil.
    static var currentToken: UUID? {
        savedCode.flatMap { token(for: $0) }
    }

    /// One line at launch saying whether the derivation agrees with the
    /// backend and which code, if any, this phone carries.
    static func logLaunchState() {
        let ok = derivationMatchesBackend()
        let name = checkCode
        let got = token(for: name)?.uuidString.lowercased() ?? "none"
        let want = checkToken.uuidString.lowercased()
        let onPhone = savedCode ?? "none"
        if ok {
            UpTimeLog.referral.notice("[REFERRAL] derivation check: \(name, privacy: .public) -> \(got, privacy: .public) matches the backend")
        } else {
            UpTimeLog.referral.error("[REFERRAL] derivation check FAILED: \(name, privacy: .public) -> \(got, privacy: .public), backend expects \(want, privacy: .public)")
        }
        UpTimeLog.referral.notice("[REFERRAL] code on this phone: \(onPhone, privacy: .public)")
    }

    /// The one line shown when a typed code cannot be a code. Android's
    /// wording (`ReferralCodeRules.INVALID_MESSAGE`); the Curator may reword.
    static let invalidMessage = "Codes use letters, numbers, - and _ (2 to 64 characters)."
}
