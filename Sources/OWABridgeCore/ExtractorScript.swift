import Foundation

enum ExtractorScript {
    static func load() throws -> String {
        if let url = Bundle.main.url(forResource: "extractor", withExtension: "js"),
           let source = try? String(contentsOf: url, encoding: .utf8), !source.isEmpty {
            return source
        }
        if let url = Bundle.main.url(forResource: "extractor", withExtension: "js", subdirectory: "Resources"),
           let source = try? String(contentsOf: url, encoding: .utf8), !source.isEmpty {
            return source
        }
        if let url = Bundle.module.url(forResource: "extractor", withExtension: "js", subdirectory: "Resources"),
           let source = try? String(contentsOf: url, encoding: .utf8), !source.isEmpty {
            return source
        }
        if let url = Bundle.module.url(forResource: "extractor", withExtension: "js"),
           let source = try? String(contentsOf: url, encoding: .utf8), !source.isEmpty {
            return source
        }
        throw ExtractorScriptError.missing
    }
}

enum ExtractorScriptError: Error {
    case missing
}
