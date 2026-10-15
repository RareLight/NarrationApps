import Foundation
import Darwin

public enum PlanningError: Error, LocalizedError {
    case invalidName, collision(String), protectedInput, invalidDestination, replacementRequired
    public var errorDescription: String? {
        switch self {
        case .invalidName: "Output names must be relative paths with a nonempty filename."
        case .collision(let path): "Output conflict: \(path). Choose a different output name before starting."
        case .protectedInput: "An output would overwrite a selected input. Choose another destination."
        case .invalidDestination: "The output folder is unavailable or not writable. Browse to recover it."
        case .replacementRequired: "An output already exists. Review destinations and approve replacement before generating again."
        }
    }
}

public enum OutputPaths {
    public static func key(_ path: String) -> String {
        path.precomposedStringWithCanonicalMapping.folding(options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }

    public static func resolved(_ url: URL) throws -> URL {
        guard url.isFileURL else { throw PlanningError.invalidDestination }
        var ancestor = url.standardizedFileURL
        var missing: [String] = []
        while !FileManager.default.fileExists(atPath: ancestor.path) {
            guard ancestor.path != "/", (try? FileManager.default.destinationOfSymbolicLink(atPath: ancestor.path)) == nil else {
                throw PlanningError.invalidDestination
            }
            missing.append(ancestor.lastPathComponent); ancestor.deleteLastPathComponent()
        }
        var result = ancestor.resolvingSymlinksInPath()
        for part in missing.reversed() { result.appendPathComponent(part) }
        return result
    }
}
