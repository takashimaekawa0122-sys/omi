#!/bin/bash
set -e

cd ~/omi

# ローカル変更を破棄してpull
git checkout -- .
git pull

cd app

# firebase_optionsファイルが無ければ作成
if [ ! -f lib/firebase_options_dev.dart ]; then
cat > lib/firebase_options_dev.dart << 'DART'
// ignore_for_file: type=lint
import 'package:firebase_core/firebase_core.dart' show FirebaseOptions;
import 'package:flutter/foundation.dart' show defaultTargetPlatform, TargetPlatform;
class DefaultFirebaseOptions {
  static FirebaseOptions get currentPlatform {
    switch (defaultTargetPlatform) {
      case TargetPlatform.iOS: return ios;
      default: throw UnsupportedError('Not supported');
    }
  }
  static const FirebaseOptions ios = FirebaseOptions(
    apiKey: 'AIzaSyCDMXPc798PXd2Q7V0zC3NfcG-95BXR3vY',
    appId: '1:587569678804:ios:2aa2aff62c2dd2baccee41',
    messagingSenderId: '587569678804',
    projectId: 'aisa-5c0bd',
    storageBucket: 'aisa-5c0bd.firebasestorage.app',
    iosBundleId: 'com.friend-app-with-wearable.ios12',
  );
}
DART
cp lib/firebase_options_dev.dart lib/firebase_options_prod.dart
fi

cat > .env << 'ENVEOF'
API_BASE_URL=https://api.omi.me/
AVALON_API_KEY=ava_T36UOxfEN_QUrpg2V-l6fzhZfplNoCFJUHLwAylKzrY
ENVEOF

cat > .dev.env << 'ENVEOF'
API_BASE_URL=https://api.omi.me/
AVALON_API_KEY=ava_T36UOxfEN_QUrpg2V-l6fzhZfplNoCFJUHLwAylKzrY
ENVEOF

flutter pub get
dart run build_runner build --delete-conflicting-outputs

# GROQ_API_KEY / ANTHROPIC_API_KEY は ~/omi_secrets.sh から読み込む（リポジトリには含めない）
if [ -f ~/omi_secrets.sh ]; then
  source ~/omi_secrets.sh
fi

# GROQ_API_KEY が未設定の場合、対話的に入力を促して ~/omi_secrets.sh に保存する
if [ -z "$GROQ_API_KEY" ]; then
  echo ""
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "  Groq API Key の設定が必要です"
  echo "  取得先: https://console.groq.com/keys"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  read -p "GROQ_API_KEY を入力してください: " input_groq_key
  if [ -z "$input_groq_key" ]; then
    echo "❌ APIキーが入力されませんでした。終了します。"
    exit 1
  fi
  export GROQ_API_KEY="$input_groq_key"
  # ~/omi_secrets.sh に保存（次回から自動読み込み）
  if [ -f ~/omi_secrets.sh ]; then
    # すでにファイルがある場合は GROQ_API_KEY 行を更新
    grep -q 'GROQ_API_KEY' ~/omi_secrets.sh \
      && sed -i '' "s|export GROQ_API_KEY=.*|export GROQ_API_KEY=\"$input_groq_key\"|" ~/omi_secrets.sh \
      || echo "export GROQ_API_KEY=\"$input_groq_key\"" >> ~/omi_secrets.sh
  else
    # ファイルがない場合は新規作成
    cat > ~/omi_secrets.sh << SECRETEOF
export GROQ_API_KEY="$input_groq_key"
SECRETEOF
  fi
  echo "✅ GROQ_API_KEY を ~/omi_secrets.sh に保存しました（次回から自動読み込みされます）"
  echo ""
fi

# ANTHROPIC_API_KEY が未設定の場合も同様に入力を促す（任意 - スキップ可）
if [ -z "$ANTHROPIC_API_KEY" ]; then
  echo ""
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "  Anthropic API Key（任意）"
  echo "  設定すると文字起こし後にClaude Haikuで誤字修正されます"
  echo "  取得先: https://console.anthropic.com/settings/api-keys"
  echo "  スキップする場合はそのままEnterを押してください"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  read -p "ANTHROPIC_API_KEY を入力してください（スキップ: Enter）: " input_anthropic_key
  if [ -n "$input_anthropic_key" ]; then
    export ANTHROPIC_API_KEY="$input_anthropic_key"
    if [ -f ~/omi_secrets.sh ]; then
      grep -q 'ANTHROPIC_API_KEY' ~/omi_secrets.sh \
        && sed -i '' "s|export ANTHROPIC_API_KEY=.*|export ANTHROPIC_API_KEY=\"$input_anthropic_key\"|" ~/omi_secrets.sh \
        || echo "export ANTHROPIC_API_KEY=\"$input_anthropic_key\"" >> ~/omi_secrets.sh
    else
      echo "export ANTHROPIC_API_KEY=\"$input_anthropic_key\"" >> ~/omi_secrets.sh
    fi
    echo "✅ ANTHROPIC_API_KEY を保存しました"
  else
    echo "⏭ ANTHROPIC_API_KEY をスキップ（Claude Haiku校正なしでビルドします）"
  fi
  echo ""
fi

mkdir -p ios/Config/Dev ios/Config/Prod
cp setup/prebuilt/GoogleService-Info.plist ios/Config/Dev/GoogleService-Info.plist
cp setup/prebuilt/GoogleService-Info.plist ios/Config/Prod/GoogleService-Info.plist
cp setup/prebuilt/GoogleService-Info.plist ios/Runner/GoogleService-Info.plist

# AISA: Xcodeプロジェクトに新規ファイルを登録（未登録の場合のみ）
if ! grep -q "AisaBackgroundAudio.swift" ios/Runner.xcodeproj/project.pbxproj 2>/dev/null; then
  echo "📎 AisaBackgroundAudio.swift と silence.wav をXcodeプロジェクトに追加..."
  ruby - <<'RUBY' 2>/dev/null || echo "⚠️  xcodeproj gem未インストール。手動でXcodeからファイルを追加してください。"
require 'xcodeproj'
project = Xcodeproj::Project.open('ios/Runner.xcodeproj')
target = project.targets.find { |t| t.name == 'Runner' }
group = project.main_group.find_subpath('Runner', true)

# AisaBackgroundAudio.swift
swift_path = 'Runner/AisaBackgroundAudio.swift'
unless group.files.any? { |f| f.path == 'AisaBackgroundAudio.swift' }
  ref = group.new_file(swift_path)
  target.source_build_phase.add_file_reference(ref)
  puts "  + AisaBackgroundAudio.swift"
end

# silence.wav
wav_path = 'Runner/silence.wav'
unless group.files.any? { |f| f.path == 'silence.wav' }
  ref = group.new_file(wav_path)
  target.resources_build_phase.add_file_reference(ref)
  puts "  + silence.wav"
end

project.save
puts "  ✅ Xcodeプロジェクト更新完了"
RUBY
fi

cd ios && pod install && cd ..

flutter build ios --flavor dev --release --no-codesign \
  "--dart-define=GROQ_API_KEY=$GROQ_API_KEY" \
  "--dart-define=ANTHROPIC_API_KEY=${ANTHROPIC_API_KEY:-}"

APP_PATH=$(find build/ios/iphoneos -name '*.app' | head -1)
rm -rf build/ios/ipa
mkdir -p build/ios/ipa/Payload
cp -r "$APP_PATH" build/ios/ipa/Payload/
cd build/ios/ipa
zip -r ~/Desktop/Runner-unsigned.ipa Payload/

echo "✅ 完了！デスクトップにRunner-unsigned.ipaが作成されました"
