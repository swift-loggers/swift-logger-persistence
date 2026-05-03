/// Renders canonical shortest-roundtrip decimal strings for finite
/// IEEE-754 binary64 values.
///
/// The canonical persistence spelling is defined by
/// `Docs/FileFormatSpec.md` ("Deterministic Encoding"). The
/// renderer does not depend on Foundation or locale-sensitive
/// floating-point formatting APIs.
enum CanonicalBinary64 {
    /// Renders a finite `Double` to its canonical persistence
    /// spelling: the shortest decimal string that round-trips
    /// through `Double(_:)` back to `value`. Signed zero collapses
    /// to `0`. Returns `nil` for non-finite input or for an
    /// internal consistency failure.
    ///
    /// The rendered spelling is deterministic across supported
    /// platforms and package patch releases.
    static func render(_ value: Double) -> String? {
        guard value.isFinite else { return nil }
        // `Docs/FileFormatSpec.md` collapses the sign of zero in
        // the JSON payload, so both `+0.0` and `-0.0` map to the
        // single canonical token `0` here.
        if value == 0 { return "0" }
        let isNegative = value.sign == .minus
        let positive = isNegative ? -value : value
        guard let body = renderPositive(positive) else { return nil }
        return isNegative ? "-" + body : body
    }

    private static func renderPositive(_ value: Double) -> String? {
        let (mantissa, binaryExponent) = decompose(value)
        var rational = ScaledRational(mantissa: mantissa, binaryExponent: binaryExponent)
        let baseDecimalExponent = rational.decimalExponent()
        let extraction = rational.extractDigits(
            decimalExponent: baseDecimalExponent,
            count: 18
        )
        let allDigits = extraction.digits
        let hasTail = extraction.hasTail
        for digitCount in 1 ... 17 {
            guard let candidate = candidateAt(
                digitCount: digitCount,
                allDigits: allDigits,
                hasTail: hasTail,
                decimalExponent: baseDecimalExponent
            ) else { return nil }
            // `candidate` is positive-only; sign and zero are
            // handled by ``render(_:)``.
            if Double(candidate) == value {
                return candidate
            }
        }
        // No verified shortest candidate for any `k <= 17`:
        // renderer failure, surface as `nil`.
        return nil
    }

    /// Decomposes a positive finite `Double` into a non-negative
    /// integer mantissa `m` and a binary exponent `e` such that
    /// `value = m * 2^e`. Subnormals reuse the same return shape;
    /// the implicit leading bit is added only for normals.
    private static func decompose(_ value: Double) -> (mantissa: UInt64, binaryExponent: Int) {
        let bits = value.bitPattern
        let biasedExponent = Int((bits >> 52) & 0x7FF)
        let fraction = bits & 0xF_FF_FF_FF_FF_FF_FF
        if biasedExponent == 0 {
            return (fraction, -1074)
        }
        let mantissa = (UInt64(1) << 52) | fraction
        let binaryExponent = biasedExponent - 1023 - 52
        return (mantissa, binaryExponent)
    }

    /// Builds a rounded canonical decimal candidate for the
    /// requested precision.
    ///
    /// Returns `nil` when the precision request or extracted
    /// digits are invalid.
    private static func candidateAt(
        digitCount: Int,
        allDigits: [UInt8],
        hasTail: Bool,
        decimalExponent: Int
    ) -> String? {
        guard digitCount > 0, digitCount < allDigits.count else { return nil }
        let roundDigit = allDigits[digitCount]
        let trailingNonZero = (digitCount + 1 ..< allDigits.count)
            .contains(where: { allDigits[$0] != 0 }) || hasTail
        let lastKept = allDigits[digitCount - 1]
        let roundUp: Bool
        if roundDigit > 5 {
            roundUp = true
        } else if roundDigit < 5 {
            roundUp = false
        } else if trailingNonZero {
            roundUp = true
        } else {
            roundUp = (lastKept & 1) == 1
        }
        var digits = Array(allDigits.prefix(digitCount))
        var localDecimalExponent = decimalExponent
        if roundUp {
            guard applyRoundUpCarry(
                digits: &digits,
                decimalExponent: &localDecimalExponent
            ) else { return nil }
        }
        // Keep malformed extracted digits on the typed-failure path.
        guard digits.allSatisfy({ $0 < 10 }) else { return nil }
        return formatExtraction(
            digits: digits,
            decimalExponent: localDecimalExponent
        )
    }

    /// Applies decimal carry propagation. Carry overflow is
    /// represented by incrementing `decimalExponent`.
    ///
    /// Returns `false` when carry propagation cannot be performed.
    private static func applyRoundUpCarry(
        digits: inout [UInt8],
        decimalExponent: inout Int
    ) -> Bool {
        guard !digits.isEmpty else { return false }
        for index in digits.indices.reversed() {
            digits[index] += 1
            if digits[index] < 10 { return true }
            digits[index] = 0
        }
        digits = [1] + [UInt8](repeating: 0, count: digits.count - 1)
        decimalExponent += 1
        return true
    }

    /// Formats extracted digits using the canonical
    /// fixed/scientific formatting window
    /// (`decimalExponent < -5 || decimalExponent >= 21`).
    private static func formatExtraction(
        digits: [UInt8],
        decimalExponent: Int
    ) -> String {
        if decimalExponent < -5 || decimalExponent >= 21 {
            return formatScientific(digits: digits, decimalExponent: decimalExponent)
        }
        return formatFixed(digits: digits, decimalExponent: decimalExponent)
    }

    /// Renders the digits as `D[.DDD]eEE` with canonical
    /// normalization: lowercase `e`, no `+` exponent sign, no
    /// leading exponent zeros, no trailing fractional zeros.
    private static func formatScientific(digits: [UInt8], decimalExponent: Int) -> String {
        var bytes: [UInt8] = []
        bytes.append(asciiDigit(digits[0]))
        var tail = Array(digits.dropFirst())
        while tail.last == 0 { tail.removeLast() }
        if !tail.isEmpty {
            bytes.append(UInt8(ascii: "."))
            for digit in tail { bytes.append(asciiDigit(digit)) }
        }
        bytes.append(UInt8(ascii: "e"))
        appendExponent(decimalExponent, into: &bytes)
        return asciiString(from: bytes)
    }

    /// Renders the digits as `DD...D[.DDD]` with canonical
    /// normalization: no trailing fractional zeros, no trailing
    /// decimal point. Used only inside the canonical fixed-point
    /// window selected by ``formatExtraction(digits:decimalExponent:)``.
    private static func formatFixed(digits: [UInt8], decimalExponent: Int) -> String {
        var bytes: [UInt8] = []
        if decimalExponent >= 0 {
            appendFixedIntegerSide(
                digits: digits,
                decimalExponent: decimalExponent,
                into: &bytes
            )
        } else {
            appendFixedFractionalSide(
                digits: digits,
                decimalExponent: decimalExponent,
                into: &bytes
            )
        }
        return asciiString(from: bytes)
    }

    /// Appends the bytes for `value >= 1` fixed-point form: the
    /// integer prefix, zero-padded when needed, plus an optional
    /// `.fractional` tail with trailing zeros trimmed.
    private static func appendFixedIntegerSide(
        digits: [UInt8],
        decimalExponent: Int,
        into bytes: inout [UInt8]
    ) {
        let integerPositions = decimalExponent + 1
        if integerPositions <= digits.count {
            for digit in digits.prefix(integerPositions) {
                bytes.append(asciiDigit(digit))
            }
        } else {
            for digit in digits { bytes.append(asciiDigit(digit)) }
            for _ in 0 ..< (integerPositions - digits.count) {
                bytes.append(UInt8(ascii: "0"))
            }
        }
        if integerPositions < digits.count {
            var fractional = Array(digits.suffix(digits.count - integerPositions))
            while fractional.last == 0 { fractional.removeLast() }
            if !fractional.isEmpty {
                bytes.append(UInt8(ascii: "."))
                for digit in fractional { bytes.append(asciiDigit(digit)) }
            }
        }
    }

    /// Appends the bytes for `value < 1` fixed-point form:
    /// `0.000...DDD`, with trailing fractional zeros removed.
    private static func appendFixedFractionalSide(
        digits: [UInt8],
        decimalExponent: Int,
        into bytes: inout [UInt8]
    ) {
        bytes.append(UInt8(ascii: "0"))
        bytes.append(UInt8(ascii: "."))
        for _ in 0 ..< (-decimalExponent - 1) {
            bytes.append(UInt8(ascii: "0"))
        }
        var trimmed = digits
        while trimmed.last == 0 { trimmed.removeLast() }
        for digit in trimmed { bytes.append(asciiDigit(digit)) }
    }

    /// Appends the canonical exponent suffix bytes (no `+` sign, no
    /// leading zeros) to `bytes`. Exponent `0` renders as `e0`.
    private static func appendExponent(_ exponent: Int, into bytes: inout [UInt8]) {
        if exponent < 0 {
            bytes.append(UInt8(ascii: "-"))
        }
        let magnitude = exponent < 0 ? -exponent : exponent
        if magnitude == 0 {
            bytes.append(UInt8(ascii: "0"))
            return
        }
        var stack: [UInt8] = []
        var remaining = magnitude
        while remaining > 0 {
            stack.append(asciiDigit(UInt8(remaining % 10)))
            remaining /= 10
        }
        for byte in stack.reversed() { bytes.append(byte) }
    }

    /// Returns the ASCII byte for a decimal digit.
    private static func asciiDigit(_ digit: UInt8) -> UInt8 {
        UInt8(ascii: "0") &+ digit
    }

    /// Materializes a `String` from canonical ASCII bytes.
    private static func asciiString(from bytes: [UInt8]) -> String {
        var result = ""
        result.reserveCapacity(bytes.count)
        for byte in bytes {
            result.unicodeScalars.append(Unicode.Scalar(byte))
        }
        return result
    }
}

/// Exact rational representation of a positive finite IEEE-754
/// binary64 value as `numerator / denominator` with both sides
/// `BigUInt`.
private struct ScaledRational {
    private let numerator: BigUInt
    private let denominator: BigUInt
    // Per-instance memoization; methods that grow the table are `mutating`.
    private var powerOfTen = PowerOfTenTable()

    init(mantissa: UInt64, binaryExponent: Int) {
        let mantissaBig = BigUInt(mantissa)
        if binaryExponent >= 0 {
            numerator = mantissaBig.shiftedLeft(by: binaryExponent)
            denominator = BigUInt(1)
        } else {
            numerator = mantissaBig
            denominator = BigUInt(1).shiftedLeft(by: -binaryExponent)
        }
    }

    /// Returns the exact decimal exponent `e` such that
    /// `10^e <= value < 10^(e + 1)`. Starts from a `Double`-based
    /// log10 estimate, then refines it using exact `BigUInt`
    /// comparisons.
    mutating func decimalExponent() -> Int {
        let numeratorBitLength = numerator.bitLength
        let denominatorBitLength = denominator.bitLength
        let log10Of2 = 0.301_029_995_663_981_2
        let bitDifference = Double(numeratorBitLength - denominatorBitLength)
        var estimate = Int((bitDifference * log10Of2).rounded(.down))
        // Adjust upward while `value >= 10^(estimate + 1)`.
        while compareValueAgainstPowerOfTen(estimate + 1) >= 0 {
            estimate += 1
        }
        // Adjust downward while `value < 10^estimate`.
        while compareValueAgainstPowerOfTen(estimate) < 0 {
            estimate -= 1
        }
        return estimate
    }

    /// Returns `1` if `value > 10^power`, `0` if equal, `-1` if
    /// less. The comparison is rearranged so both sides can be
    /// compared exactly without fractional arithmetic: when
    /// `power` is non-negative, `denominator` is scaled by
    /// `10^power`; otherwise `numerator` is scaled by
    /// `10^|power|`.
    private mutating func compareValueAgainstPowerOfTen(_ power: Int) -> Int {
        if power >= 0 {
            let scaled = denominator.multiplied(by: powerOfTen.value(power))
            return BigUInt.compare(numerator, scaled)
        }
        let scaled = numerator.multiplied(by: powerOfTen.value(-power))
        return BigUInt.compare(scaled, denominator)
    }

    /// Extracts the leading `count` decimal digits of `value`
    /// plus a non-zero remainder flag describing whether the
    /// decimal expansion continues past that prefix. The flag
    /// drives round-half-to-even decisions in the caller. The
    /// leading digit is always in `1...9`; subsequent digits are
    /// in `0...9`.
    mutating func extractDigits(
        decimalExponent: Int,
        count: Int
    ) -> (digits: [UInt8], hasTail: Bool) {
        var current = numerator
        var divisor = denominator
        if decimalExponent >= 0 {
            divisor = divisor.multiplied(by: powerOfTen.value(decimalExponent))
        } else {
            current = current.multiplied(by: powerOfTen.value(-decimalExponent))
        }
        var digits: [UInt8] = []
        digits.reserveCapacity(count)
        for _ in 0 ..< count {
            let digit = leadingDigit(current: current, divisor: divisor)
            digits.append(digit)
            if digit != 0 {
                let subtrahend = divisor.multiplied(by: BigUInt(UInt64(digit)))
                current = BigUInt.subtract(current, subtrahend)
            }
            current = current.multiplied(by: BigUInt(UInt64(10)))
        }
        let hasTail = !current.isZero
        return (digits, hasTail)
    }

    /// Returns the leading decimal digit of `current / divisor`
    /// for `current < 10 * divisor`. Uses bounded digit search
    /// over the decimal range `0...9`.
    private func leadingDigit(current: BigUInt, divisor: BigUInt) -> UInt8 {
        var digit: UInt8 = 0
        while digit < 9 {
            let next = divisor.multiplied(by: BigUInt(UInt64(digit + 1)))
            if BigUInt.compare(current, next) < 0 { break }
            digit += 1
        }
        return digit
    }
}

/// Per-render power-of-ten memoization table. Owned by a single
/// ``ScaledRational`` value; grown lazily as `10^k` requests come
/// in and discarded when the owning value goes out of scope.
/// Holds no global state and is isolated to a single render
/// operation.
private struct PowerOfTenTable {
    private var entries: [BigUInt] = [BigUInt(1)]

    /// Returns `10^power` as a `BigUInt`. Requesting a power that
    /// has not been computed yet extends the table by repeated
    /// `* 10` from the current largest entry; previously computed
    /// powers are reused for later lookups. Negative powers are
    /// outside the renderer contract and return `BigUInt(0)`.
    mutating func value(_ power: Int) -> BigUInt {
        if power < 0 { return BigUInt(0) }
        while entries.count <= power {
            let last = entries[entries.count - 1]
            entries.append(last.multiplied(by: BigUInt(UInt64(10))))
        }
        return entries[power]
    }
}

/// Minimal non-negative big-integer type with little-endian `UInt32`
/// limbs. Trailing zero limbs are removed after every operation,
/// so `limbs.last != 0` and `0` is represented by an empty array.
/// Supports the subset of
/// operations required by the canonical decimal renderer (left
/// shift, multiply by `BigUInt`, scalar / `BigUInt` subtract,
/// compare).
/// Pure value type with no static mutable state -- power-of-ten
/// memoization lives in a per-render ``PowerOfTenTable`` owned by
/// ``ScaledRational``, not on this type.
private struct BigUInt: Equatable {
    private(set) var limbs: [UInt32]

    init(_ value: UInt64) {
        if value == 0 {
            limbs = []
        } else if value <= UInt64(UInt32.max) {
            limbs = [UInt32(value)]
        } else {
            limbs = [UInt32(value & 0xFF_FF_FF_FF), UInt32(value >> 32)]
        }
    }

    private init(limbs: [UInt32]) {
        var trimmed = limbs
        while trimmed.last == 0 { trimmed.removeLast() }
        self.limbs = trimmed
    }

    var isZero: Bool { limbs.isEmpty }

    /// Position of the highest set bit plus one.
    ///
    /// Returns `0` for zero.
    var bitLength: Int {
        guard let topLimb = limbs.last else { return 0 }
        let topLimbBits = 32 - topLimb.leadingZeroBitCount
        return (limbs.count - 1) * 32 + topLimbBits
    }

    func shiftedLeft(by bits: Int) -> BigUInt {
        if isZero || bits == 0 { return self }
        let limbShift = bits / 32
        let bitShift = bits % 32
        var newLimbs = [UInt32](repeating: 0, count: limbShift) + limbs
        if bitShift > 0 {
            var carry: UInt32 = 0
            for index in 0 ..< newLimbs.count {
                let limb = newLimbs[index]
                let shifted = (limb << bitShift) | carry
                newLimbs[index] = shifted
                carry = UInt32(UInt64(limb) >> UInt64(32 - bitShift))
            }
            if carry > 0 { newLimbs.append(carry) }
        }
        return BigUInt(limbs: newLimbs)
    }

    func multiplied(by factor: BigUInt) -> BigUInt {
        if isZero || factor.isZero { return BigUInt(0) }
        var result = [UInt32](repeating: 0, count: limbs.count + factor.limbs.count)
        for i in 0 ..< limbs.count {
            var carry: UInt64 = 0
            for j in 0 ..< factor.limbs.count {
                let current = UInt64(result[i + j])
                let product = UInt64(limbs[i]) * UInt64(factor.limbs[j]) + current + carry
                result[i + j] = UInt32(product & 0xFF_FF_FF_FF)
                carry = product >> 32
            }
            // Propagate the inner-loop carry, accumulating with any
            // value already present and growing the array if the carry
            // would land past the current limb count.
            var carryIndex = i + factor.limbs.count
            while carry > 0 {
                if carryIndex == result.count {
                    result.append(0)
                }
                let sum = UInt64(result[carryIndex]) + carry
                result[carryIndex] = UInt32(sum & 0xFF_FF_FF_FF)
                carry = sum >> 32
                carryIndex += 1
            }
        }
        return BigUInt(limbs: result)
    }

    static func compare(_ lhs: BigUInt, _ rhs: BigUInt) -> Int {
        if lhs.limbs.count != rhs.limbs.count {
            return lhs.limbs.count < rhs.limbs.count ? -1 : 1
        }
        for index in lhs.limbs.indices.reversed()
            where lhs.limbs[index] != rhs.limbs[index] {
            return lhs.limbs[index] < rhs.limbs[index] ? -1 : 1
        }
        return 0
    }

    /// Subtraction with borrow; returns `lhs - rhs`. Caller
    /// guarantees `lhs >= rhs` (the renderer only subtracts
    /// `digit * divisor` from a current that is known to be
    /// strictly greater by construction of the digit-extraction
    /// search).
    static func subtract(_ lhs: BigUInt, _ rhs: BigUInt) -> BigUInt {
        if rhs.isZero { return lhs }
        var result = lhs.limbs
        var borrow: Int64 = 0
        for index in 0 ..< result.count {
            let leftValue = Int64(result[index])
            let rightValue = index < rhs.limbs.count ? Int64(rhs.limbs[index]) : 0
            let diff = leftValue - rightValue - borrow
            if diff < 0 {
                result[index] = UInt32(diff + (Int64(1) << 32))
                borrow = 1
            } else {
                result[index] = UInt32(diff)
                borrow = 0
            }
        }
        return BigUInt(limbs: result)
    }
}
