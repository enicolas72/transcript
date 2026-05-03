import SwiftUI
import StoreKit

/// Modal sheet that pitches xTranscript Pro and runs the StoreKit
/// purchase flow. Reachable from the sidebar's "Upgrade" button and
/// from the file-row "Upgrade to Pro" action shown when a Free user
/// drops a file longer than 5 minutes.
struct UpgradeView: View {
    @Binding var isPresented: Bool
    @ObservedObject var subscription: SubscriptionManager
    @State private var didJustPurchase = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Image(systemName: "sparkles")
                    .foregroundStyle(.tint)
                    .font(.title2)
                Text("xTranscript Pro").font(.title).bold()
                Spacer()
                Button("Close") { isPresented = false }
                    .keyboardShortcut(.cancelAction)
            }

            VStack(alignment: .leading, spacing: 8) {
                bullet("Unlimited file length",
                       "Transcribe full meetings, lectures, and interviews — no 5-minute cap.")
                bullet("Same xAI-powered accuracy",
                       "Identical streaming pipeline as Free, just without the limit.")
                bullet("Cancel anytime",
                       "Yearly subscription, manageable from System Settings → Apple Account → Subscriptions.")
            }

            if subscription.isPro || didJustPurchase {
                Label("You're on xTranscript Pro. Thanks!", systemImage: "checkmark.seal.fill")
                    .foregroundStyle(.green)
                    .padding(.vertical, 8)
            } else if let product = subscription.product {
                purchaseSection(product: product)
            } else if let err = subscription.lastError {
                loadingErrorSection(message: err)
            } else {
                ProgressView("Loading subscription…")
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 8)
            }

            // Errors raised by purchase / restore (product is loaded but the
            // action itself failed) — distinct from the load-time error which
            // owns its own retry surface above.
            if subscription.product != nil, let err = subscription.lastError {
                Text(err).font(.caption).foregroundStyle(.red)
            }

            footer
        }
        .padding(20)
        .frame(width: 480)
        .task {
            if subscription.product == nil { await subscription.loadProduct() }
        }
    }

    /// Replaces the indefinite spinner when `loadProduct()` fails or returns
    /// no products. Gives App Review (and any user on a flaky connection) a
    /// visible explanation plus a one-click retry, instead of a paywall that
    /// looks frozen.
    private func loadingErrorSection(message: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
            Button("Retry") {
                Task { await subscription.loadProduct() }
            }
            .controlSize(.small)
        }
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func purchaseSection(product: Product) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(product.displayPrice).font(.title2).bold()
                Text("/ year").foregroundStyle(.secondary)
                Spacer()
                Button {
                    Task {
                        let ok = await subscription.purchase()
                        if ok {
                            didJustPurchase = true
                            // Auto-dismiss after a beat so the user sees the
                            // confirmation state.
                            try? await Task.sleep(nanoseconds: 1_500_000_000)
                            isPresented = false
                        }
                    }
                } label: {
                    if subscription.purchaseInFlight {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("Subscribe").bold()
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(subscription.purchaseInFlight)
            }
            Button("Restore Purchases") {
                Task { await subscription.restore() }
            }
            .buttonStyle(.link)
            .font(.caption)
        }
    }

    private func bullet(_ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.tint)
                .font(.callout)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).bold()
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    /// Required by App Store Guideline 3.1.2(a): subscription terms,
    /// auto-renewal disclosure, links to privacy + EULA. Apple's standard
    /// EULA URL is acceptable when no custom EULA is provided.
    private var footer: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Auto-renews yearly until cancelled. Manage or cancel in System Settings → Apple Account → Subscriptions. Payment is charged to your Apple ID.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 12) {
                Link("Privacy Policy", destination: URL(string: "https://github.com/enicolas72/transcript/blob/main/docs/privacy.md")!)
                Link("Terms of Use (EULA)", destination: URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")!)
            }
            .font(.caption2)
        }
    }
}
