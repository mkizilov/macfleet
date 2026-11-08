import Testing
@testable import MacFleetKit

@Suite("Byte formatting")
struct ByteFormattingTests {
    @Test func smallValuesAreWholeBytes() {
        #expect(ByteFormatting.string(bytes: UInt64(0)) == "0 B")
        #expect(ByteFormatting.string(bytes: UInt64(999)) == "999 B")
    }

    @Test func oneDecimalBelowTenUnits() {
        #expect(ByteFormatting.string(bytes: UInt64(1_500)) == "1.5 KB")
        #expect(ByteFormatting.string(bytes: UInt64(9_940)) == "9.9 KB")
    }

    @Test func wholeUnitsFromTenUp() {
        #expect(ByteFormatting.string(bytes: UInt64(12_345_678)) == "12 MB")
        #expect(ByteFormatting.string(bytes: UInt64(999_400)) == "999 KB")
    }

    @Test func roundingUpToTheNextUnitDoesNotShowAThousand() {
        #expect(ByteFormatting.string(bytes: UInt64(999_500)) == "1.0 MB")
        #expect(ByteFormatting.string(bytes: UInt64(9_960)) == "10 KB")
    }

    @Test func largeValuesUseGigabytesTerabytesAndPetabytes() {
        #expect(ByteFormatting.string(bytes: UInt64(2_000_000_000)) == "2.0 GB")
        #expect(ByteFormatting.string(bytes: UInt64(1_000_000_000_000)) == "1.0 TB")
        #expect(ByteFormatting.string(bytes: UInt64(1_000_000_000_000_000)) == "1.0 PB")
    }

    @Test func ratesAddPerSecondSuffix() {
        #expect(ByteFormatting.rate(bytesPerSecond: 1_500_000) == "1.5 MB/s")
        #expect(ByteFormatting.rate(bytesPerSecond: 0) == "0 B/s")
        #expect(ByteFormatting.rate(bytesPerSecond: 0.4) == "0 B/s")
    }

    @Test func percentagesRoundToWholeNumbers() {
        #expect(ByteFormatting.percent(0.456) == "46%")
        #expect(ByteFormatting.percent(0) == "0%")
        #expect(ByteFormatting.percent(1) == "100%")
    }
}
