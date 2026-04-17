import 'package:flutter/material.dart';

/// AISA会話テキストをチャット風の吹き出しUIで表示するウィジェット。
/// [自分] / [相手] / [名前] タグをパースして、LINEのようなバブル表示に変換する。
class AisaChatBubbleWidget extends StatelessWidget {
  final String content;

  const AisaChatBubbleWidget({super.key, required this.content});

  @override
  Widget build(BuildContext context) {
    final messages = _parseMessages(content);
    if (messages.isEmpty) {
      return const SizedBox.shrink();
    }

    return SelectionArea(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: messages.map((msg) => _buildBubble(msg)).toList(),
      ),
    );
  }

  List<_ChatMessage> _parseMessages(String text) {
    final lines = text.split('\n').where((l) => l.trim().isNotEmpty).toList();
    final messages = <_ChatMessage>[];
    final tagPattern = RegExp(r'^\[(.+?)\]\s*');
    String lastSpeaker = '自分';

    for (final line in lines) {
      final match = tagPattern.firstMatch(line);
      if (match != null) {
        lastSpeaker = match.group(1)!;
        final messageText = line.substring(match.end).trim();
        if (messageText.isNotEmpty) {
          messages.add(_ChatMessage(speaker: lastSpeaker, text: messageText));
        }
      } else {
        // タグなし行は直前の話者を引き継ぐ
        messages.add(_ChatMessage(speaker: lastSpeaker, text: line.trim()));
      }
    }

    return messages;
  }

  /// 話者タグから属性絵文字を抽出する。例: `自分🧔` → `🧔`、`相手👨` → `👨`、`自分` → null
  String? _extractSpeakerEmoji(String speaker) {
    // 「自分」「相手」プレフィックスを除去して残りを絵文字候補として返す
    String rest = speaker;
    if (rest.startsWith('自分')) rest = rest.substring(2);
    else if (rest.startsWith('相手')) rest = rest.substring(2);
    rest = rest.trim();
    return rest.isEmpty ? null : rest;
  }

  /// 話者タグが「自分」系かどうか判定（`自分` `自分🧔` `自分👩` 等すべてを自分扱い）
  bool _isSelf(String speaker) => speaker.startsWith('自分');

  /// 話者ラベルの表示文字列を決める。名前ベース（「田中」等）はそのまま、
  /// `自分` は「自分」、`相手` は「不明」、`相手👨` は「👨 相手」のように表示。
  String _speakerLabel(String speaker) {
    if (_isSelf(speaker)) return '自分';
    if (speaker == '相手') return '不明';
    if (speaker.startsWith('相手')) {
      final emoji = _extractSpeakerEmoji(speaker);
      return emoji != null ? '$emoji 相手' : '相手';
    }
    return speaker;
  }

  Widget _buildBubble(_ChatMessage msg) {
    final isSelf = _isSelf(msg.speaker);
    final bubbleColor = isSelf ? const Color(0xFF6C63FF) : const Color(0xFF35343B);
    final alignment = isSelf ? CrossAxisAlignment.end : CrossAxisAlignment.start;
    // タグに含まれる絵文字があればそれをアバターに使う。無ければ既定絵文字。
    final tagEmoji = _extractSpeakerEmoji(msg.speaker);
    final selfEmoji = tagEmoji ?? '🎙️';
    final otherEmoji = tagEmoji ?? '👤';

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Column(
        crossAxisAlignment: alignment,
        children: [
          // 話者名ラベル
          Padding(
            padding: EdgeInsets.only(
              left: isSelf ? 0 : 32,
              right: isSelf ? 32 : 0,
              bottom: 2,
            ),
            child: Text(
              _speakerLabel(msg.speaker),
              style: const TextStyle(
                color: Colors.white38,
                fontSize: 11,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
          Row(
            mainAxisAlignment: isSelf ? MainAxisAlignment.end : MainAxisAlignment.start,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              if (!isSelf) ...[
                Text(otherEmoji, style: const TextStyle(fontSize: 20)),
                const SizedBox(width: 6),
              ],
              Flexible(
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                  decoration: BoxDecoration(
                    color: bubbleColor,
                    borderRadius: BorderRadius.only(
                      topLeft: const Radius.circular(16),
                      topRight: const Radius.circular(16),
                      bottomLeft: Radius.circular(isSelf ? 16 : 4),
                      bottomRight: Radius.circular(isSelf ? 4 : 16),
                    ),
                  ),
                  child: Text(
                    msg.text,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 15,
                      height: 1.4,
                    ),
                  ),
                ),
              ),
              if (isSelf) ...[
                const SizedBox(width: 6),
                Text(selfEmoji, style: const TextStyle(fontSize: 20)),
              ],
            ],
          ),
        ],
      ),
    );
  }
}

class _ChatMessage {
  final String speaker;
  final String text;

  const _ChatMessage({required this.speaker, required this.text});
}
