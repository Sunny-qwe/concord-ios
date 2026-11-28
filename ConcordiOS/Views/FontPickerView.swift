import SwiftUI

// MARK: - Font picker (FlClash: FontFamilyView, lib/views/font_family.dart)
// Two sections: the system default, then every family installed on
// the device (UIFont.familyNames). Each row previews its own name
// in its own family. Tapping saves immediately (FontStore) and the
// app root re-renders with the new default font. The search field
// filters the long installed list. Footer states the CJK limit:
// most iOS families are Latin-only, so Chinese text falls back to
// the system font for CJK glyphs.
// v0.2.159: upstream nav bar; the 13pt semibold container font is
// gone — rows render at the 17pt body size upstream's SelectionSheet
// uses, each name in its own family.

struct FontPickerView: View {
    @EnvironmentObject private var fontStore: FontStore
    @State private var searchText = ""

    private var filteredFamilies: [String] {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return fontStore.availableFamilies }
        return fontStore.availableFamilies.filter { $0.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        // v0.2.165 (B): the docked search pill lives in this
        // ZStack, replacing the top .searchable field. It only
        // shows when there are at least 10 families (upstream
        // sheetSearchMinItemCount = 10).
        ZStack(alignment: .bottom) {
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
                    .font(.footnote)
            }

            Section {
                ForEach(filteredFamilies, id: \.self) { family in
                    Button {
                        fontStore.select(family)
                    } label: {
                        HStack(spacing: 12) {
                            Text(family)
                                .font(fontStore.font(family: family, size: 17))
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
                    .font(.headline)
                    .foregroundStyle(ConcordTheme.onSurfaceVariant)
            } footer: {
                Text("iOS 自带字体大多只含拉丁字母，中文仍会用系统字体显示；英文与数字会按所选字体显示。")
                    .font(.footnote)
            }
        }
        // v0.2.66: tab-bar clearance for pushed pages.
        // v0.2.165 (B): 64 for the docked search pill (16 + 48);
        // the pill only shows with >= 10 families, but the inset
        // is unconditional (harmless when the pill is hidden).
        .contentMargins(.bottom, ConcordTheme.dockedSearchContentInset)
        .scrollContentBackground(.hidden)
        .padding(.top, 16)
        .background(ConcordTheme.pageBackground)
        .upstreamNavBar(title: "字体")
        if fontStore.availableFamilies.count >= 10 {
            DockedSearchBar(text: $searchText, prompt: "搜索字体")
                .padding(.horizontal, 16)
                .padding(.bottom, ConcordTheme.dockedSearchBottomMargin)
        }
        }
    }
}
