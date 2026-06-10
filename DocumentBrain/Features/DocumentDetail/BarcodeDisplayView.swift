import SwiftUI
import CoreImage
import CoreImage.CIFilterBuiltins

// MARK: - Barcode kind classification

enum BarcodeKind {
    case boardingPass       // IATA BCBP: starts with "M"
    case url(URL)           // http/https URL
    case generic            // everything else

    init(payload: String) {
        // IATA Bar Coded Boarding Pass format always starts with 'M' followed by digit
        if payload.hasPrefix("M"), payload.count > 10 {
            let secondChar = payload.dropFirst().first
            if let c = secondChar, c.isNumber {
                self = .boardingPass
                return
            }
        }
        if let url = URL(string: payload), let scheme = url.scheme,
           scheme.hasPrefix("http") {
            self = .url(url)
            return
        }
        self = .generic
    }

    var systemImage: String {
        switch self {
        case .boardingPass: return "airplane.circle.fill"
        case .url:          return "link.circle.fill"
        case .generic:      return "qrcode"
        }
    }

    var label: String {
        switch self {
        case .boardingPass: return "Tarjeta de embarque"
        case .url:          return "Enlace"
        case .generic:      return "Código"
        }
    }

    func subtitle(for payload: String) -> String {
        switch self {
        case .boardingPass:
            // BCBP field 2 (char 2-22) contains passenger name
            if payload.count > 22 {
                let name = String(payload.dropFirst(2).prefix(20))
                    .trimmingCharacters(in: .whitespaces)
                return name.isEmpty ? "Toca para mostrar" : name
            }
            return "Toca para mostrar"
        case .url(let url):
            return url.host ?? payload
        case .generic:
            return "Toca para mostrar"
        }
    }
}

// MARK: - String + Identifiable (for .sheet(item:))

extension String: @retroactive Identifiable {
    public var id: String { self }
}

// MARK: - Full-screen barcode display

struct BarcodeDisplayView: View {
    let payload: String
    @Environment(\.dismiss) private var dismiss

    /// Screen brightness before we boosted it, restored on dismiss.
    @State private var previousBrightness: CGFloat?

    private var kind: BarcodeKind { BarcodeKind(payload: payload) }

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Spacer()

                // Generated barcode image
                if let image = generatedImage {
                    Image(uiImage: image)
                        .interpolation(.none)
                        .resizable()
                        .scaledToFit()
                        .padding(.horizontal, 24)
                        .background(Color.white)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .padding(.horizontal, 24)
                        .shadow(color: .black.opacity(0.1), radius: 8, y: 4)
                } else {
                    ContentUnavailableView(
                        "No se pudo generar el código",
                        systemImage: "qrcode.viewfinder",
                        description: Text("El payload no es compatible.")
                    )
                }

                VStack(spacing: 6) {
                    Text(kind.label)
                        .font(.headline)
                    Text("Muestra esta pantalla en el lector")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                // URL variant also gets an Open in Safari button
                if case .url(let url) = kind {
                    Link(destination: url) {
                        Label("Abrir en Safari", systemImage: "safari")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                    }
                    .buttonStyle(.borderedProminent)
                    .padding(.horizontal, 24)
                }
            }
            .padding(.bottom, 24)
            .background(Color(.systemBackground))
            .navigationTitle(kind.label)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cerrar") { dismiss() }
                }
            }
        }
        .onAppear {
            // Boost to max brightness for easy scanning, remembering the prior value
            previousBrightness = UIScreen.main.brightness
            UIScreen.main.brightness = 1.0
        }
        .onDisappear {
            // Restore the user's original brightness
            if let previousBrightness {
                UIScreen.main.brightness = previousBrightness
            }
        }
    }

    // MARK: - Image generation

    private var generatedImage: UIImage? {
        switch kind {
        case .boardingPass:
            return generatePDF417(from: payload) ?? generateQR(from: payload)
        case .url, .generic:
            return generateQR(from: payload)
        }
    }

    private func generateQR(from string: String) -> UIImage? {
        let data = Data(string.utf8)
        let filter = CIFilter.qrCodeGenerator()
        filter.message = data
        filter.correctionLevel = "H"
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 10, y: 10))
        return render(ciImage: scaled)
    }

    private func generatePDF417(from string: String) -> UIImage? {
        guard let filter = CIFilter(name: "CIPDF417BarcodeGenerator") else { return nil }
        filter.setValue(Data(string.utf8), forKey: "inputMessage")
        // inputCorrectionLevel: 0–8 (2 = standard error correction)
        filter.setValue(2, forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 3, y: 3))
        return render(ciImage: scaled)
    }

    private func render(ciImage: CIImage) -> UIImage? {
        let context = CIContext(options: nil)
        guard let cgImage = context.createCGImage(ciImage, from: ciImage.extent) else { return nil }
        return UIImage(cgImage: cgImage)
    }
}
