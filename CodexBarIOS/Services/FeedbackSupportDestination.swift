import Foundation

struct FeedbackSupportContext: Equatable, Sendable {
    let appVersion: String
    let buildNumber: String
    let operatingSystemName: String
    let operatingSystemVersion: String
    let deviceCategory: String

    var systemDetails: String {
        "CodexBar \(appVersion) (\(buildNumber)), \(operatingSystemName) \(operatingSystemVersion), \(deviceCategory)"
    }
}

enum FeedbackSupportDestination: String, CaseIterable, Identifiable, Sendable {
    case reportProblem
    case suggestImprovement
    case knownIssues
    case supportGuide
    case rateCodexBar

    var id: String {
        rawValue
    }

    var title: String {
        switch self {
        case .reportProblem:
            "Report a Problem"
        case .suggestImprovement:
            "Suggest an Improvement"
        case .knownIssues:
            "View Known Issues"
        case .supportGuide:
            "Support Guide"
        case .rateCodexBar:
            "Rate CodexBar"
        }
    }

    var detail: String {
        switch self {
        case .reportProblem:
            "Open the structured public bug-report form."
        case .suggestImprovement:
            "Open the structured public feature-request form."
        case .knownIssues:
            "Search open reports and known limitations."
        case .supportGuide:
            "Read troubleshooting and reporting guidance."
        case .rateCodexBar:
            "Write a review on the App Store."
        }
    }

    var serviceName: String {
        switch self {
        case .rateCodexBar:
            "App Store"
        default:
            "GitHub"
        }
    }

    var systemImage: String {
        switch self {
        case .reportProblem:
            "ladybug"
        case .suggestImprovement:
            "lightbulb"
        case .knownIssues:
            "list.bullet.rectangle"
        case .supportGuide:
            "book.closed"
        case .rateCodexBar:
            "star"
        }
    }

    func url(context: FeedbackSupportContext) -> URL {
        switch self {
        case .reportProblem:
            var components = URLComponents(
                string: "https://github.com/HemSoft/codexbar-ios/issues/new"
            )!
            components.queryItems = [
                URLQueryItem(name: "template", value: "bug_report.yml"),
                URLQueryItem(name: "system-details", value: context.systemDetails),
            ]
            components.percentEncodedQuery = components.percentEncodedQuery?
                .replacingOccurrences(of: "+", with: "%2B")
            return components.url!
        case .suggestImprovement:
            return URL(
                string: "https://github.com/HemSoft/codexbar-ios/issues/new?template=feature_request.yml"
            )!
        case .knownIssues:
            var components = URLComponents(
                string: "https://github.com/HemSoft/codexbar-ios/issues"
            )!
            components.queryItems = [
                URLQueryItem(name: "q", value: "is:issue is:open"),
            ]
            return components.url!
        case .supportGuide:
            return AppReviewLinks.supportURL
        case .rateCodexBar:
            return AppReviewLinks.writeReviewURL
        }
    }
}
