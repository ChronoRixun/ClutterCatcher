import CloudKit

extension CKRecord {
    /// The record's system fields (identity, zone, change tag — never user
    /// fields), archived for `record_metadata` (plan §3.2).
    func encodedSystemFields() -> Data {
        let archiver = NSKeyedArchiver(requiringSecureCoding: true)
        encodeSystemFields(with: archiver)
        archiver.finishEncoding()
        return archiver.encodedData
    }

    /// Restores a record skeleton from `encodedSystemFields()` output; nil if
    /// the blob is corrupt.
    static func decodeSystemFields(from data: Data) -> CKRecord? {
        guard let unarchiver = try? NSKeyedUnarchiver(forReadingFrom: data) else {
            return nil
        }
        unarchiver.requiresSecureCoding = true
        defer { unarchiver.finishDecoding() }
        return CKRecord(coder: unarchiver)
    }
}
