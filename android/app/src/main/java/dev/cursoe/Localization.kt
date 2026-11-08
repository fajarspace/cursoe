package dev.cursoe

import java.util.Locale

/**
 * Bahasa antarmuka Cursoe. English bawaan; Bahasa Indonesia bila bahasa HP adalah Indonesia, atau bila bahasa
 * itu dipilih khusus untuk Cursoe (Android 13+: Settings › Apps › Cursoe › Language; lihat res/xml/locales_config).
 * Teks resource (strings.xml) mengikuti aturan yang sama lewat values/ (English) dan values-in/ (Indonesia).
 */
fun isIndonesian(): Boolean = Locale.getDefault().language.let { it == "in" || it == "id" }

/** Teks antarmuka dalam dua bahasa: `tr("English", "Bahasa Indonesia")`. */
fun tr(english: String, indonesian: String): String = if (isIndonesian()) indonesian else english
