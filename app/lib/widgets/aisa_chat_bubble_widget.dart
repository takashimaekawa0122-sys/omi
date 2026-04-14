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

  Widget _buildBubble(_ChatMessage msg) {
    final isSelf = msg.speaker == '自分';
    final bubbleColor = isSelf ? const Color(0xFF6C63FF) : const Color(0xFF35343B);
    final alignment = isSelf ? CrossAxisAlignment.end : CrossAxisAlignment.start;

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
              isSelf ? '自分' : (msg.speaker == '相手' ? '不明' : msg.speaker),
              style: TextStyle(
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
                const Text('👤', style: TextStyle(fontSize: 20)),
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
                const Text('🎙️', style: TextStyle(fontSize: 20)),
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
