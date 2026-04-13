import 'package:flutter/material.dart';

import 'package:provider/provider.dart';

import 'package:omi/backend/preferences.dart';
import 'package:omi/pages/home/page.dart';
import 'package:omi/pages/onboarding/device_selection.dart';
import 'package:omi/pages/onboarding/permissions/permissions_checker.dart';
import 'package:omi/pages/onboarding/wrapper.dart';
import 'package:omi/pages/persona/persona_profile.dart';
import 'package:omi/providers/auth_provider.dart';
import 'package:omi/utils/analytics/mixpanel.dart';

class MobileApp extends StatelessWidget {
  const MobileApp({super.key});

  @override
  Widget build(BuildContext context) {
    // [A.I.S.A.] オンボーディング（名前・言語設定等）を完全スキップ
    // 再インストール時に毎回設定するのが面倒なため、直接ホーム画面へ
    return Consumer<AuthenticationProvider>(
      builder: (context, authProvider, child) {
        if (authProvider.isSignedIn()) {
          // オンボーディング未完了でも強制的に完了扱いにしてホームへ
          if (!SharedPreferencesUtil().onboardingCompleted) {
            SharedPreferencesUtil().onboardingCompleted = true;
            SharedPreferencesUtil().permissionsCompleted = true;
            // 言語ダイアログが毎回出るのを防ぐためデフォルト言語を日本語に設定
            if (!SharedPreferencesUtil().hasSetPrimaryLanguage) {
              SharedPreferencesUtil().userPrimaryLanguage = 'ja';
              SharedPreferencesUtil().hasSetPrimaryLanguage = true;
            }
          }
          if (!SharedPreferencesUtil().permissionsCompleted) {
            return const _PermissionsGate();
          }
          return const HomePageWrapper();
        } else {
          // 未ログイン時はデバイス選択画面（認証はここで行われる）
          return const DeviceSelectionPage();
        }
      },
    );
  }
}

/// Checks if permissions are already granted. If so, marks as completed
/// and shows home. Otherwise shows the permissions interstitial.
class _PermissionsGate extends StatefulWidget {
  const _PermissionsGate();

  @override
  State<_PermissionsGate> createState() => _PermissionsGateState();
}

class _PermissionsGateState extends State<_PermissionsGate> {
  bool? _permissionsGranted;

  @override
  void initState() {
    super.initState();
    _check();
  }

  Future<void> _check() async {
    // [A.I.S.A.] 5秒タイムアウト: permission_handler がハングした場合にスピナーが永久に出るのを防ぐ
    bool granted = false;
    try {
      granted = await arePermissionsGranted().timeout(
        const Duration(seconds: 5),
        onTimeout: () => false,
      );
    } catch (e) {
      granted = false;
    }
    if (granted) {
      SharedPreferencesUtil().permissionsCompleted = true;
    }
    if (mounted) {
      setState(() => _permissionsGranted = granted);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_permissionsGranted == null) {
      return const Scaffold(
        backgroundColor: Colors.black,
        body: Center(child: CircularProgressIndicator(color: Colors.white)),
      );
    }
    if (_permissionsGranted!) {
      return const HomePageWrapper();
    }
    MixpanelManager().permissionsInterstitialShown();
    return const PermissionsInterstitialPage();
  }
}
