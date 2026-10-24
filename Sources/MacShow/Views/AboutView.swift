import SwiftUI

/// Settings › About: version, source code, and the open-source components inside the app.
struct AboutView: View {
    private struct Component: Identifiable {
        let name: String
        let license: String
        let url: String
        var id: String { name }
    }

    // What MPVKit's LGPL build and the app's own dependencies bundle.
    private static let components = [
        Component(name: "mpv (libmpv)", license: "LGPL 2.1 or later", url: "https://mpv.io"),
        Component(name: "FFmpeg", license: "LGPL 2.1 or later", url: "https://ffmpeg.org"),
        Component(name: "MPVKit", license: "LGPL 3.0", url: "https://github.com/mpvkit/MPVKit"),
        Component(name: "libplacebo", license: "LGPL 2.1 or later", url: "https://code.videolan.org/videolan/libplacebo"),
        Component(name: "libass", license: "ISC", url: "https://github.com/libass/libass"),
        Component(name: "FreeType", license: "FreeType License", url: "https://freetype.org"),
        Component(name: "HarfBuzz", license: "MIT", url: "https://harfbuzz.github.io"),
        Component(name: "FriBidi", license: "LGPL 2.1 or later", url: "https://github.com/fribidi/fribidi"),
        Component(name: "libunibreak", license: "zlib", url: "https://github.com/adah1972/libunibreak"),
        Component(name: "dav1d", license: "BSD 2-Clause", url: "https://code.videolan.org/videolan/dav1d"),
        Component(name: "libdovi", license: "MIT", url: "https://github.com/quietvoid/dovi_tool"),
        Component(name: "Little CMS", license: "MIT", url: "https://www.littlecms.com"),
        Component(name: "MoltenVK", license: "Apache 2.0", url: "https://github.com/KhronosGroup/MoltenVK"),
        Component(name: "shaderc", license: "Apache 2.0", url: "https://github.com/google/shaderc"),
        Component(name: "libbluray", license: "LGPL 2.1 or later", url: "https://www.videolan.org/developers/libbluray.html"),
        Component(name: "uchardet", license: "MPL 1.1 / LGPL 2.1", url: "https://www.freedesktop.org/wiki/Software/uchardet/"),
        Component(name: "GnuTLS", license: "LGPL 2.1 or later", url: "https://gnutls.org"),
        Component(name: "Nettle", license: "LGPL 3 or GPL 2", url: "https://www.lysator.liu.se/~nisse/nettle/"),
        Component(name: "GMP", license: "LGPL 3 or GPL 2", url: "https://gmplib.org"),
        Component(name: "OpenSSL", license: "Apache 2.0", url: "https://www.openssl.org"),
        Component(name: "LuaJIT", license: "MIT", url: "https://luajit.org"),
        Component(name: "GRDB.swift", license: "MIT", url: "https://github.com/groue/GRDB.swift"),
    ]

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
            Text("MacShow is built on these open-source projects. The LGPL libraries are linked into the app; since MacShow's own source is public, you can rebuild it against modified versions of them.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            List(Self.components) { component in
                HStack {
                    Link(component.name, destination: URL(string: component.url)!)
                    Spacer()
                    Text(component.license).foregroundStyle(.secondary)
                }
            }
            .listStyle(.bordered)
        }
        .padding(20)
    }
}
