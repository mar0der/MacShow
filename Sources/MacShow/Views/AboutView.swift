import SwiftUI

/// Settings › About: version, source code, and the open-source components inside
/// the app. Full notices and license texts ship in the app's Resources/Licenses.
struct AboutView: View {
    private struct Component: Identifiable {
        let name: String
        /// SPDX identifier.
        let license: String
        let url: String
        /// The license text's file name in Resources/Licenses, if not the SPDX id.
        var file: String?
        var id: String { name }
    }

    // Matches Resources/Licenses/ACKNOWLEDGEMENTS.txt (MPVKit's LGPL build, GRDB).
    private static let components = [
        Component(name: "MPVKit", license: "LGPL-3.0-only", url: "https://github.com/mpvkit/MPVKit", file: "LGPL-3.0-or-later"),
        Component(name: "mpv (libmpv)", license: "LGPL-2.1-or-later", url: "https://mpv.io"),
        Component(name: "FFmpeg", license: "LGPL-3.0-or-later", url: "https://ffmpeg.org"),
        Component(name: "libplacebo", license: "LGPL-2.1-or-later", url: "https://code.videolan.org/videolan/libplacebo"),
        Component(name: "libass", license: "ISC", url: "https://github.com/libass/libass"),
        Component(name: "FreeType", license: "FTL", url: "https://freetype.org"),
        Component(name: "HarfBuzz", license: "MIT-Modern-Variant", url: "https://harfbuzz.github.io"),
        Component(name: "GNU FriBidi", license: "LGPL-2.1-or-later", url: "https://github.com/fribidi/fribidi"),
        Component(name: "libunibreak", license: "Zlib", url: "https://github.com/adah1972/libunibreak"),
        Component(name: "dav1d", license: "BSD-2-Clause", url: "https://code.videolan.org/videolan/dav1d"),
        Component(name: "uavs3d", license: "BSD-3-Clause", url: "https://github.com/uavs3/uavs3d"),
        Component(name: "libdovi", license: "MIT", url: "https://github.com/quietvoid/dovi_tool"),
        Component(name: "Little CMS", license: "MIT", url: "https://www.littlecms.com"),
        Component(name: "MoltenVK", license: "Apache-2.0", url: "https://github.com/KhronosGroup/MoltenVK"),
        Component(name: "shaderc", license: "Apache-2.0", url: "https://github.com/google/shaderc"),
        Component(name: "libbluray", license: "LGPL-2.1-or-later", url: "https://www.videolan.org/developers/libbluray.html"),
        Component(name: "uchardet", license: "MPL-1.1", url: "https://www.freedesktop.org/wiki/Software/uchardet/"),
        Component(name: "GnuTLS", license: "LGPL-2.1-or-later", url: "https://gnutls.org"),
        Component(name: "GNU Nettle", license: "LGPL-3.0-or-later", url: "https://www.lysator.liu.se/~nisse/nettle/"),
        Component(name: "GNU MP", license: "LGPL-3.0-or-later", url: "https://gmplib.org"),
        Component(name: "OpenSSL", license: "Apache-2.0", url: "https://www.openssl.org"),
        Component(name: "LuaJIT", license: "MIT", url: "https://luajit.org"),
        Component(name: "GRDB.swift", license: "MIT", url: "https://github.com/groue/GRDB.swift"),
    ]

    private static let licenses = Bundle.main.resourceURL?.appendingPathComponent("Licenses")

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 64, height: 64)
                VStack(alignment: .leading, spacing: 3) {
                    Text("MacShow").font(.title2.weight(.bold))
                    Text("Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev")")
                        .foregroundStyle(.secondary)
                    Link("Source code on GitHub (MIT license)", destination: URL(string: "https://github.com/mar0der/MacShow")!)
                }
            }
            Text("MacShow is built on these open-source projects. The LGPL libraries are linked into the app; since MacShow's own source is public, you can rebuild it against modified versions of them. This software is based in part on the work of the Independent JPEG Group. Portions of this software are copyright © The FreeType Project (www.freetype.org).")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            List(Self.components) { component in
                HStack {
                    Link(component.name, destination: URL(string: component.url)!)
                    Spacer()
                    Button(component.license) { open((component.file ?? component.license) + ".txt") }
                        .buttonStyle(.link)
                        .foregroundStyle(.secondary)
                        .help("Show the license text")
                }
            }
            .listStyle(.bordered)
            Button("Copyright Notices and Acknowledgements") { open("ACKNOWLEDGEMENTS.txt") }
                .disabled(Self.licenses == nil)
        }
        .padding(20)
    }

    private func open(_ file: String) {
        guard let url = Self.licenses?.appendingPathComponent(file), FileManager.default.fileExists(atPath: url.path) else { return }
        NSWorkspace.shared.open(url)
    }
}
