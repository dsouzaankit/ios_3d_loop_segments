import Foundation

/// Resolves pCloud JSON API hosts (regional + nearest from getapiserver).
enum PCloudAPIHostResolver {
    static func hostsToTry(for region: PCloudRegion, session: URLSession) async -> [String] {
        var ordered: [String] = []
        if let nearest = try? await fetchNearestAPIHosts(bootstrapHost: region.apiHost, session: session) {
            ordered.append(contentsOf: nearest)
        }
        ordered.append(region.apiHost)
        if let alternateNearest = try? await fetchNearestAPIHosts(
            bootstrapHost: region.alternate.apiHost,
            session: session
        ) {
            ordered.append(contentsOf: alternateNearest)
        }
        ordered.append(region.alternate.apiHost)
        return uniqueHosts(ordered)
    }

    private static func fetchNearestAPIHosts(bootstrapHost: String, session: URLSession) async throws -> [String] {
        let json = try await PCloudAPIRequest.get(host: bootstrapHost, method: "getapiserver", session: session)
        guard PCloudAPIRequest.resultCode(json) == 0 else { return [] }
        if let apis = json["api"] as? [String] {
            return apis.filter { !$0.isEmpty }
        }
        return []
    }

    private static func uniqueHosts(_ hosts: [String]) -> [String] {
        var seen = Set<String>()
        var unique: [String] = []
        unique.reserveCapacity(hosts.count)
        for host in hosts where seen.insert(host).inserted {
            unique.append(host)
        }
        return unique
    }
}
