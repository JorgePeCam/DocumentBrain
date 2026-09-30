import XCTest
@testable import DocumentBrain

@MainActor
final class StructuredDataSanitizingTests: XCTestCase {

    /// What a model produced for a CV: no document type, placeholder travel fields,
    /// origin == destination, a zero amount and an invented date.
    private func cvLikeOutput() -> StructuredDocumentData {
        var d = StructuredDocumentData()
        d.vendor = "Jorge Perez Campos"
        d.date = "2025-02-01"
        d.amount = 0
        d.currency = "EUR"
        d.origin = "Madrid"
        d.destination = "Madrid"
        d.flightNumber = "N/A"
        d.departureTime = "N/A"
        d.arrivalTime = "N/A"
        d.seat = "N/A"
        d.eventTitle = "N/A"
        return d
    }

    func testCVLikeOutput_isDiscarded() {
        XCTAssertNil(cvLikeOutput().sanitized())
    }

    func testOtherTypeWithoutAmount_isDiscarded() {
        var d = cvLikeOutput()
        d.documentType = .other
        XCTAssertNil(d.sanitized())
    }

    func testBoardingPass_keepsRealTravelFields_dropsPlaceholders() throws {
        var d = StructuredDocumentData()
        d.documentType = .flight
        d.vendor = "Aerolíneas Sol"
        d.date = "2026-11-14"
        d.origin = "MAD"
        d.destination = "LIS"
        d.flightNumber = "SL2471"
        d.departureTime = "08:05"
        d.arrivalTime = "n/a"
        d.seat = " 17C "
        let s = try XCTUnwrap(d.sanitized())
        XCTAssertEqual(s.origin, "MAD")
        XCTAssertEqual(s.destination, "LIS")
        XCTAssertEqual(s.flightNumber, "SL2471")
        XCTAssertEqual(s.departureTime, "08:05")
        XCTAssertNil(s.arrivalTime)
        XCTAssertEqual(s.seat, "17C")
    }

    func testInvoice_stripsTravelAndEventFields_keepsAmount() throws {
        var d = StructuredDocumentData()
        d.documentType = .invoice
        d.vendor = "Eléctrica del Norte"
        d.amount = 85.43
        d.currency = "eur"
        d.origin = "Madrid"
        d.destination = "Lisboa"
        d.seat = "3B"
        d.eventTitle = "Algo"
        d.departureTime = "10:00"
        let s = try XCTUnwrap(d.sanitized())
        XCTAssertEqual(s.amount, 85.43)
        XCTAssertNil(s.origin)
        XCTAssertNil(s.destination)
        XCTAssertNil(s.seat)
        XCTAssertNil(s.eventTitle)
        XCTAssertNil(s.departureTime)
    }

    func testZeroAmount_isDropped_withItsCurrency() throws {
        var d = StructuredDocumentData()
        d.documentType = .contract
        d.amount = 0
        d.currency = "EUR"
        let s = try XCTUnwrap(d.sanitized())
        XCTAssertNil(s.amount)
        XCTAssertNil(s.currency)
    }

    func testAmountWithoutRecognisedType_isKept() {
        var d = StructuredDocumentData()
        d.amount = 12.5
        XCTAssertNotNil(d.sanitized())
    }

    func testMalformedDatesAndTimes_areDropped() throws {
        var d = StructuredDocumentData()
        d.documentType = .event
        d.date = "1 Feb 2025"
        d.departureTime = "25:00"
        d.eventTitle = "Río Sonoro"
        let s = try XCTUnwrap(d.sanitized())
        XCTAssertNil(s.date)
        XCTAssertNil(s.departureTime)
        XCTAssertEqual(s.eventTitle, "Río Sonoro")
    }

    func testSameOriginAndDestination_isNotARoute() throws {
        var d = StructuredDocumentData()
        d.documentType = .flight
        d.origin = "Madrid"
        d.destination = "MADRID"
        let s = try XCTUnwrap(d.sanitized())
        XCTAssertNil(s.origin)
        XCTAssertNil(s.destination)
    }

    func testStoredBadData_isCleanedOnRead() throws {
        var doc = Document(title: "CV")
        let json = try JSONEncoder().encode(cvLikeOutput())
        doc.structuredData = String(data: json, encoding: .utf8)
        XCTAssertNil(doc.structuredDataDecoded)
    }

    func testEmptyMarker_decodesToNil() {
        var doc = Document(title: "CV")
        doc.structuredData = "{}"
        XCTAssertNil(doc.structuredDataDecoded)
        XCTAssertNotNil(doc.structuredData, "marker must stay non-nil so the launch sweep skips it")
    }

    func testEmptyStruct_encodesAsEmptyMarker() throws {
        let json = try JSONEncoder().encode(StructuredDocumentData())
        XCTAssertEqual(String(data: json, encoding: .utf8), "{}")
    }
}
