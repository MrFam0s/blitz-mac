import Foundation

struct ASCPricePoint: Decodable, Identifiable {
    let id: String

    struct Attributes: Decodable {
        let customerPrice: String?
    }

    let attributes: Attributes
}

struct ASCScreenshotReservation: Decodable, Identifiable {
    let id: String

    struct Attributes: Decodable {
        let sourceFileChecksum: String?
        let uploadOperations: [UploadOperation]?
    }

    let attributes: Attributes

    struct UploadOperation: Decodable {
        let method: String
        let url: String
        let offset: Int
        let length: Int
        let requestHeaders: [Header]

        struct Header: Decodable {
            let name: String
            let value: String
        }
    }
}

struct ASCReviewSubmission: Decodable, Identifiable {
    let id: String

    static func isActive(_ state: String?) -> Bool {
        // Unknown/absent state is potentially active: never let an older
        // completed review hide it. Presentation and writes still fail closed.
        !["COMPLETE", "ACCEPTED", "APPROVED", "CANCELED"].contains(ASCReleaseStatus.normalize(state))
    }

    struct Attributes: Decodable {
        let state: String?
        let submittedDate: String?
        let platform: String?
    }

    let attributes: Attributes
}

struct ASCReviewSubmissionItem: Decodable, Identifiable {
    let id: String

    struct Attributes: Decodable {
        let state: String?
        let resolved: Bool?
        let createdDate: String?
    }

    let attributes: Attributes
    let relationships: Relationships?

    struct Relationships: Decodable {
        let appStoreVersion: ToOneRelationship?

        struct ToOneRelationship: Decodable {
            let data: ResourceIdentifier?
        }

        struct ResourceIdentifier: Decodable {
            let type: String
            let id: String
        }
    }

    var appStoreVersionId: String? {
        relationships?.appStoreVersion?.data?.id
    }
}
