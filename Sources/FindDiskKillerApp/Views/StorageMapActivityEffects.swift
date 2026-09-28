import SwiftUI

/// A local light pass. It never changes layout or implies a completion percentage.
struct StorageMapLightSweep: View {
    var strength: Double = 1

    var body: some View {
        GeometryReader { proxy in
            let width = max(36, min(140, proxy.size.width * 0.55))
            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0),
                    .init(color: Color.primary.opacity(0.18 * strength), location: 0.25),
                    .init(color: Color.primary.opacity(strength), location: 0.52),
                    .init(color: .clear, location: 1)
                ],
                startPoint: .leading,
                endPoint: .trailing
            )
            .frame(width: width, height: proxy.size.height + width)
            .rotationEffect(.degrees(12))
            .offset(y: -width / 2)
            .phaseAnimator([false, true]) { light, moving in
                light.offset(x: moving ? proxy.size.width + width : -width)
            } animation: { moving in
                moving ? .linear(duration: 2.6) : .linear(duration: 0)
            }
        }
        .clipped()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

struct StorageMapTextShimmer: ViewModifier {
    let isActive: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        content.overlay {
            if isActive, !reduceMotion {
                StorageMapLightSweep(strength: colorScheme == .dark ? 1 : 0.8)
                    .mask(content)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
    }
}

/// Roll changed digits in place; the formatted value and units remain readable as one label.
struct StorageMapNumberText: View {
    let value: String
    let size: CGFloat
    let weight: Font.Weight
    let rounded: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(_ value: String, size: CGFloat, weight: Font.Weight = .regular, rounded: Bool = false) {
        self.value = value
        self.size = size
        self.weight = weight
        self.rounded = rounded
    }

    var body: some View {
        Text(value)
            .font(.system(size: size, weight: weight, design: rounded ? .rounded : .default))
            .monospacedDigit()
            .lineLimit(1)
            .minimumScaleFactor(0.64)
            .contentTransition(reduceMotion ? .identity : .numericText(countsDown: false))
            .animation(reduceMotion ? nil : .smooth(duration: 0.4), value: value)
    }
}
