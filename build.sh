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

mkdir -p ios/Config/Dev ios/Config/Prod
cp setup/prebuilt/GoogleService-Info.plist ios/Config/Dev/GoogleService-Info.plist
cp setup/prebuilt/GoogleService-Info.plist ios/Config/Prod/GoogleService-Info.plist
cp setup/prebuilt/GoogleService-Info.plist ios/Runner/GoogleService-Info.plist

cd ios && pod install && cd ..

flutter build ios --flavor dev --release --no-codesign

APP_PATH=$(find build/ios/iphoneos -name '*.app' | head -1)
rm -rf build/ios/ipa
mkdir -p build/ios/ipa/Payload
cp -r "$APP_PATH" build/ios/ipa/Payload/
cd build/ios/ipa
zip -r ~/Desktop/Runner-unsigned.ipa Payload/

echo "✅ 完了！デスクトップにRunner-unsigned.ipaが作成されました"
