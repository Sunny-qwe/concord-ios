import SwiftUI

// MARK: - Font picker (FlClash: FontFamilyView, lib/views/font_family.dart)
// Two sections: the system default, then every family installed on
// the device (UIFont.familyNames). Each row previews its own name
// in its own family. Tapping saves immediately (FontStore) and the
// app root re-renders with the new default font. The search field
// filters the long installed list. Footer states the CJK limit:
// most iOS families are Latin-only, so Chinese text falls back to
// the system font for CJK glyphs.

struct FontPickerView: View {
    @EnvironmentObject private var fontStore: FontStore
    @State private var searchText = ""

    private var filteredFamilies: [String] {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return fontStore.availableFamilies }
        return fontStore.availableFamilies.filter { $0.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        List {
            Section {
                Button {
                    fontStore.select(nil)
                } label: {
                    HStack(spacing: 12) {
                        Text("默认")
                            .foregroundStyle(Color(.label))
                        Spacer()
                        if fontStore.selectedFamily == nil {
                            Image(systemName: "checkmark")
                                .foregroundStyle(ConcordTheme.accent)
                        }
                    }
                }
                .buttonStyle(.plain)
            } footer: {
                Text("默认使用 iOS 系统字体。")
                    .font(.system(size: 13))
            }

            Section {
                ForEach(filteredFamilies, id: \.self) { family in
                    Button {
                        fontStore.select(family)
                    } label: {
                        HStack(spacing: 12) {
                            Text(family)
                                .font(fontStore.font(family: family, size: 13))
                                .foregroundStyle(Color(.label))
                            Spacer()
                            if fontStore.selectedFamily == family {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(ConcordTheme.accent)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
            } header: {
                Text("已安装字体")
            } footer: {
                Text("iOS 自带字体大多只含拉丁字母，中文仍会用系统字体显示；英文与数字会按所选字体显示。")
                    .font(.system(size: 13))
            }
        }
        .searchable(text: $searchText, prompt: "搜索字体")
        .scrollContentBackground(.hidden)
        .font(.system(size: 13, weight: .semibold))
        .background(ConcordTheme.pageBackground)
        .navigationTitle("字体")
        .navigationBarTitleDisplayMode(.inline)
    }
}
