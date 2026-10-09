import SwiftUI
import TetherCore

/// Settings → Appearance. Classic SwiftUI only — theme presets and type controls.
struct HostAppearanceSettings: View {
    @Bindable private var appearance = AppearancePreferences.shared

    var body: some View {
        Form {
            Section {
                Picker("Theme", selection: Binding(
                    get: { appearance.presetID },
                    set: { appearance.setPresetID($0) }
                )) {
                    ForEach(AppearancePresets.all) { preset in
                        Text(preset.name).tag(preset.id)
                    }
                }
            } footer: {
                Text("Themes change accent and type. Layout and controls stay system.")
            }

            Section {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Text size")
                        Spacer()
                        Text("\(Int(appearance.guiFontSize)) pt")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    Slider(
                        value: Binding(
                            get: { appearance.guiFontSize },
                            set: { appearance.setGUIFontSize($0) }
                        ),
                        in: AppearancePreferences.minGUIFontSize...AppearancePreferences.maxGUIFontSize,
                        step: 1
                    )
                }
                Picker("Text weight", selection: Binding(
                    get: { appearance.guiFontWeight },
                    set: { appearance.setGUIFontWeight($0) }
                )) {
                    ForEach(GuiFontWeight.allCases) { weight in
                        Text(weight.title).tag(weight)
                    }
                }
                .pickerStyle(.segmented)
            } header: {
                Text("Type")
            }

            Section {
                Picker("Icon", selection: Binding(
                    get: { AppIconChoice.current },
                    set: { $0.save() }
                )) {
                    ForEach(AppIconChoice.allCases) { choice in
                        Text(choice.title).tag(choice)
                    }
                }
                Text("Light and Dark follow the Mac’s appearance while Tether is open.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                LabeledContent("Version", value: AppVersion.marketing)
            } header: {
                Text("App icon")
            }
        }
        .formStyle(.grouped)
    }
}
