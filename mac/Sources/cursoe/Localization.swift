import Foundation

/// Bahasa antarmuka Cursoe. English bawaan; Bahasa Indonesia bila itu bahasa pilihan di macOS, atau bahasa yang
/// dipilih khusus untuk Cursoe di Pengaturan Sistem › Umum › Bahasa & Wilayah › Aplikasi.
/// (Info.plist mendaftarkan en & id lewat CFBundleLocalizations agar Cursoe muncul di daftar itu.)
enum Language {
    static let isIndonesian = Bundle.preferredLocalizations(from: ["en", "id"]).first == "id"
}

/// Teks antarmuka dalam dua bahasa: `L("English", "Bahasa Indonesia")`.
func L(_ english: String, _ indonesian: String) -> String {
    Language.isIndonesian ? indonesian : english
}
