import SwiftUI

/// Three pages shown once, before the first scan.
struct IntroView: View {
    /// UserDefaults key recording that the introduction has been read.
    static let shownKey = "introShown"

    let onDone: () -> Void
    @State private var page = 0

    private let lastPage = 2

    init(onDone: @escaping () -> Void) {
        self.onDone = onDone
    }

    var body: some View {
        VStack(spacing: 16) {
            TabView(selection: $page) {
                IntroPage(symbol: "square.grid.3x3",
                          title: "Lay the pieces out",
                          text: "Spread your pieces in a single layer on a plain surface, such as a table or a sheet of paper. Pick a surface whose colour differs from the pieces, and keep the pieces from touching.")
                    .tag(0)
                IntroPage(symbol: "iphone.gen3",
                          title: "Sweep slowly in rows",
                          text: "Hold the phone flat, about 30 cm above the pieces, and move it slowly along one row, then the next, like mowing a lawn. A dot appears on each piece as it is found.")
                    .tag(1)
                IntroPage(symbol: "checklist",
                          title: "Check what it is unsure about",
                          text: "Pieces the app is confident about are added for you. It shows you only the ones it is unsure of, with pictures to choose from. Then see which sets you can build.")
                    .tag(2)
            }
            .tabViewStyle(.page(indexDisplayMode: .always))
            .indexViewStyle(.page(backgroundDisplayMode: .always))

            Button {
                if page < lastPage {
                    withAnimation { page += 1 }
                } else {
                    onDone()
                }
            } label: {
                Text(page < lastPage ? "Next" : "Start scanning")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding(.horizontal, 24)

            Button("Skip", action: onDone)
                .font(.subheadline)
                .opacity(page < lastPage ? 1 : 0)
                .disabled(page >= lastPage)
                .padding(.bottom, 12)
        }
    }
}

private struct IntroPage: View {
    let symbol: String
    let title: String
    let text: String

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                Image(systemName: symbol)
                    .font(.largeTitle)
                    .imageScale(.large)
                    .foregroundStyle(Color.accentColor)
                    .padding(.top, 48)
                    .accessibilityHidden(true)
                Text(title)
                    .font(.title.weight(.bold))
                    .multilineTextAlignment(.center)
                Text(text)
                    .font(.body)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 28)
            .padding(.bottom, 56)
            .frame(maxWidth: .infinity)
        }
    }
}

#if DEBUG
#Preview("Introduction") {
    IntroView(onDone: { })
}
#endif
