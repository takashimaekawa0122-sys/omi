import 'dart:convert';

extension StringExtensions on String {
  /// Dart の String は既に UTF-16 で保持されているため、
  /// 一般的に再デコードは不要。ただし過去の Omi 実装で "utf-8 の生バイト列が
  /// そのまま String に詰まっている" ケースを救済するために残してある。
  ///
  /// 旧実装 `utf8.decode(codeUnits)` は日本語のような BMP 上位文字
  /// （コードユニット > 255）を渡すと ArgumentError / RangeError を投げ、
  /// かつ `on Exception catch` では Error を拾えず例外が build メソッドを
  /// 貫通して黒画面フリーズを引き起こしていた。
  ///
  /// 修正方針:
  /// - 全コードユニットが ASCII (< 128) → そのまま返す（デコード不要）
  /// - いずれかのコードユニットが 255 超 → 既に正しい Dart String と判断し、
  ///   utf8.decode を呼ばずにそのまま返す（バイト列ではないため）
  /// - それ以外 → 旧挙動で utf8.decode を試み、失敗時は元文字列を返す
  ///   （すべての Throwable を捕捉）
  String get decodeString {
    final units = codeUnits;
    if (units.isEmpty) return this;

    bool allAscii = true;
    for (final c in units) {
      if (c > 255) {
        // 255 超 = 真の Unicode 文字（日本語等）。byte 列ではないので返す。
        return this;
      }
      if (c >= 128) allAscii = false;
    }
    if (allAscii) return this; // ASCII のみ: デコード不要

    try {
      return utf8.decode(units);
    } catch (_) {
      // Exception だけでなく Error（ArgumentError 等）も安全に拾う
      return this;
    }
  }

  String capitalize() {
    return isNotEmpty ? '${this[0].toUpperCase()}${substring(1)}' : '';
  }
}
