import Foundation
import CoreML

/// What a piece of text is used for. e5 models are trained with asymmetric prefixes:
/// questions are embedded as "query: …" and indexed text as "passage: …".
enum EmbeddingKind {
    case query
    case passage

    var prefix: String {
        switch self {
        case .query: return "query: "
        case .passage: return "passage: "
        }
    }
}

final class EmbeddingService {
    /// Bump this string when the model, tokenizer or prefixes change. Any mismatch with
    /// the stored UserDefaults value triggers a full re-index on next launch.
    static let modelVersion = "multilingual-e5-small-int4"
    static let embeddingDimension = 384

    // MARK: - Retrieval calibration for this model
    //
    // e5 cosine similarities are compressed into a high band: on the retrieval benchmark,
    // chunks from the right document score ~0.79–0.87 and the rest ~0.73–0.81. These
    // values are model-specific — re-measure them with eval/run_retrieval_eval.py when
    // the model changes.

    /// Below this, a chunk with no keyword or entity match is not considered relevant.
    static let semanticFloor: Float = 0.75

    nonisolated(unsafe) static let shared: EmbeddingService? = {
        do {
            return try EmbeddingService()
        } catch {
            AppLogger.error("Error inicializando EmbeddingService: \(error)")
            return nil
        }
    }()

    private let model: E5Small
    private let tokenizer: SentencePieceTokenizer

    private init() throws {
        let config = MLModelConfiguration()
        // Use CPU for simulator compatibility. On device, .all enables Neural Engine.
        #if targetEnvironment(simulator)
        config.computeUnits = .cpuOnly
        #else
        config.computeUnits = .all
        #endif

        self.model = try E5Small(configuration: config)

        guard let vocabURL = Bundle.main.url(forResource: "e5_vocab", withExtension: "tsv") else {
            throw EmbeddingError.vocabNotFound
        }
        self.tokenizer = try SentencePieceTokenizer(vocabURL: vocabURL)
    }

    /// Returns a 384-dim L2-normalized embedding. `kind` adds the prefix e5 expects.
    func generateEmbedding(for text: String, kind: EmbeddingKind) async throws -> [Float] {
        let (inputIDs, mask) = try tokenizer.tokenizeToMLArrays(text: kind.prefix + text)
        let output = try model.prediction(input_ids: inputIDs, attention_mask: mask)
        return extractEmbedding(from: output.embedding)
    }

    private func extractEmbedding(from multiArray: MLMultiArray) -> [Float] {
        let dim = Self.embeddingDimension
        var embedding = [Float](repeating: 0, count: dim)
        for i in 0..<dim {
            embedding[i] = multiArray[[0, NSNumber(value: i)] as [NSNumber]].floatValue
        }
        return embedding
    }
}

enum EmbeddingError: LocalizedError {
    case vocabNotFound

    var errorDescription: String? {
        switch self {
        case .vocabNotFound: return "No se encontró e5_vocab.tsv en el bundle"
        }
    }
}
