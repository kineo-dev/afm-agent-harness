import Foundation
import FoundationModels

// MARK: - Model Tier

/// Which on-device Foundation Models capability tier this host actually has.
/// `SystemLanguageModel.default` resolves to whichever variant the OS decides is
/// appropriate for the current hardware — there is no public API to explicitly request
/// a specific variant, and there is no cross-host dispatch. This type exists purely to
/// observe that resolved choice so the agent can react to it locally.
public enum ModelTier: String, Codable, Sendable, Equatable {
    case baseline
    case advanced

    @available(macOS 27.0, *)
    private static func detectLocal() -> ModelTier {
        SystemLanguageModel.default.variant == SystemLanguageModel.Variant.coreAdvanced3 ? .advanced : .baseline
    }

    public static func detectLocalTier() -> ModelTier {
        if #available(macOS 27.0, *) {
            return detectLocal()
        }
        return .baseline
    }
}

// MARK: - TriageDecision

/// Structured, schema-constrained triage output used to decide whether a request should be
/// handled with routine (baseline) effort or escalated to the advanced generation path.
/// Kept to a single field so the triage call itself stays fast regardless of which tier
/// actually answers it.
public struct TriageDecision: Generable, Codable, Sendable {
    public let tier: String

    public static var generationSchema: GenerationSchema {
        GenerationSchema(
            type: TriageDecision.self,
            description: "Routing decision for whether a request needs baseline or advanced handling",
            properties: [
                GenerationSchema.Property(
                    name: "tier",
                    description: "\"baseline\" for routine/simple requests, or \"advanced\" for requests needing deep multi-step reasoning or complex code understanding",
                    type: String.self
                )
            ]
        )
    }

    public init(tier: String) {
        self.tier = tier
    }

    public init(_ content: GeneratedContent) throws {
        guard case .structure(let props, _) = content.kind else {
            throw NSError(domain: "TriageDecision", code: 1, userInfo: [NSLocalizedDescriptionKey: "Expected structure"])
        }
        self.tier = props.string(for: "tier") ?? "baseline"
    }

    public var generatedContent: GeneratedContent {
        GeneratedContent(kind: .structure(properties: [
            "tier": GeneratedContent(kind: .string(tier))
        ], orderedKeys: ["tier"]))
    }

    public var resolvedTier: ModelTier {
        tier.lowercased().contains("advanced") ? .advanced : .baseline
    }
}
