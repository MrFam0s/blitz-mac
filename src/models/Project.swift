import Foundation

struct Project: Identifiable, Hashable {
    let id: String
    var metadata: BlitzProjectMetadata
    let path: String

    var name: String { metadata.name }
    var type: ProjectType { metadata.type }
    var platform: ProjectPlatform { metadata.resolvedPlatform }
    var releaseTargets: [ProjectReleaseTarget] { metadata.resolvedReleaseTargets }
    var selectedReleaseTarget: ProjectReleaseTarget? { metadata.selectedReleaseTarget }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    static func == (lhs: Project, rhs: Project) -> Bool {
        lhs.id == rhs.id
    }
}
