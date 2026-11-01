public import CoreFoundation

/// A value of a Disk Arbitration description, as the model reads it.
public enum DiskValue: Sendable, Hashable, ExpressibleByStringLiteral, ExpressibleByIntegerLiteral,
    ExpressibleByBooleanLiteral
{
    case text(String)
    case number(Int64)
    case flag(Bool)

    public init(stringLiteral value: String) { self = .text(value) }
    public init(integerLiteral value: Int64) { self = .number(value) }
    public init(booleanLiteral value: Bool) { self = .flag(value) }

    /// Strings, numbers and booleans as they are, URLs as their path, UUIDs as their string; anything else (icons, data) is
    /// left out.
    public init?(_ value: CFTypeRef) {
        switch CFGetTypeID(value) {
            case CFStringGetTypeID(): self = .text(unsafe unsafeDowncast(value, to: CFString.self) as String)
            case CFBooleanGetTypeID(): self = .flag(CFBooleanGetValue(unsafe unsafeDowncast(value, to: CFBoolean.self)))
            case CFNumberGetTypeID():
                var number: Int64 = 0
                guard unsafe CFNumberGetValue(unsafe unsafeDowncast(value, to: CFNumber.self), .sInt64Type, &number)
                else { return nil }
                self = .number(number)
            case CFURLGetTypeID():
                let url = unsafe unsafeDowncast(value, to: CFURL.self)
                guard let path = CFURLCopyFileSystemPath(url, .cfurlposixPathStyle) else { return nil }
                self = .text(path as String)
            case CFUUIDGetTypeID():
                guard let text = CFUUIDCreateString(nil, unsafe unsafeDowncast(value, to: CFUUID.self)) else {
                    return nil
                }
                self = .text(text as String)
            default: return nil
        }
    }

    var text: String? { if case .text(let value) = self { value } else { nil } }
    var number: Int64? { if case .number(let value) = self { value } else { nil } }
    var flag: Bool? { if case .flag(let value) = self { value } else { nil } }
}
