// Launch options, read from launch arguments (`open DockWings.app --args
// -Demo a`) or `defaults write local.dockwings Demo a`.
//   Demo:     a | b — fake music/todo/shelf states for screenshots; touches
//             no real player or Reminders
//             notch — a loop of notch alerts
//   Backdrop: path to an image shown behind the panels (wallpaper test)
//   Bar:      YES — the wings sit inside the Dock, over runs of spacer tiles
//             after Finder and before Trash (the Dock needs both)
//   NotchStyle: island — alerts in a glass pill below the notch; card — the
//             compact alert stays black, the card is glass below the notch
//   Open:     widget id whose drawer opens 1 s after launch (screenshot aid)
//   Review:   with Demo, an answer given to the first WaniKani review question
//             when the review starts
// Also holds small shared view helpers.
import AppKit
import SwiftUI

enum Config {
    static let demo = UserDefaults.standard.string(forKey: "Demo")
    static let backdrop = UserDefaults.standard.string(forKey: "Backdrop")
    static let bar = UserDefaults.standard.bool(forKey: "Bar")
    static let notchStyle = UserDefaults.standard.string(forKey: "NotchStyle")
}

extension EnvironmentValues {
    /// Draw widget text dark: the wallpaper behind this wing is bright and calm.
    @Entry var inkDark = false
    /// False while the wings can't be seen (covered, screen asleep, locked)
    /// and in the invisible measuring copies: looping animations stop.
    @Entry var ambient = true
}

/// Widget text and glyph colour at an opacity: white normally, near-black
/// where the wing sits on a bright wallpaper (set per wing by WingSide).
struct InkStyle: ShapeStyle {
    let opacity: Double

    func resolve(in environment: EnvironmentValues) -> Color.Resolved {
        Color(white: environment.inkDark ? 0.08 : 1).opacity(opacity).resolve(in: environment)
    }
}

func ink(_ opacity: Double) -> InkStyle { InkStyle(opacity: opacity) }

/// Keeps widgets readable: light text gets a dark shadow, a tight heavy one
/// on top when part of the background is bright; dark text only shows on
/// really bright backgrounds and needs none.
struct Legibility: ViewModifier {
    let dark: Bool
    var mixed = false

    func body(content: Content) -> some View {
        if dark {
            content
        } else if mixed {
            content.chrome().shadow(color: .black.opacity(0.75), radius: 1).shadow(color: .black.opacity(0.5), radius: 3)
        } else {
            content.chrome()
        }
    }
}

extension View {
    /// No backdrop: a wide soft shadow plus a tight one keep white text and
    /// covers readable on any wallpaper, the way desktop icon labels are.
    func chrome() -> some View {
        shadow(color: .black.opacity(0.45), radius: 9)
            .shadow(color: .black.opacity(0.35), radius: 1.5, y: 1)
    }

    /// Dark rounded card for popups (the todo drawer), where a list needs a
    /// surface to sit on.
    func card(radius: CGFloat = 18) -> some View {
        background(
            RoundedRectangle(cornerRadius: radius, style: .continuous).fill(Color(white: 0.09).opacity(0.88))
                .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(.white.opacity(0.1), lineWidth: 1))
        )
    }

    /// Lets text take its natural width up to `max`, then truncate.
    func hug(max: CGFloat) -> some View {
        frame(maxWidth: max, alignment: .leading).fixedSize(horizontal: true, vertical: false)
    }
}

/// Round icon button that lights up on hover and dips when pressed.
struct IconButton: View {
    let symbol: String
    var size: CGFloat = 13
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: size, weight: .semibold))
                .frame(width: 30, height: 30)
                .background(Circle().fill(.white.opacity(hovering ? 0.14 : 0)))
                .contentShape(Circle())
        }
        .buttonStyle(Press())
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering)
    }

    private struct Press: ButtonStyle {
        func makeBody(configuration: Configuration) -> some View {
            configuration.label
                .scaleEffect(configuration.isPressed ? 0.86 : 1)
                .animation(.spring(duration: 0.2, bounce: 0.4), value: configuration.isPressed)
        }
    }
}

/// Core Animation may run animations below the display rate to save power;
/// the wings' small animations ask for the full rate.
func fullRate<A: CAAnimation>(_ animation: A) -> A {
    animation.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
    return animation
}
