import 'dart:async';
import 'dart:ui';
// trigger rebuild

import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:marionette_flutter/marionette_flutter.dart';

import 'package:awesome_notifications/awesome_notifications.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_crashlytics/firebase_crashlytics.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart' as ble;
import 'package:omi/gen/pigeon_communicator.g.dart';
import 'package:omi/services/bridges/ble_bridge.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:opus_dart/opus_dart.dart';
import 'package:opus_flutter/opus_flutter.dart' as opus_flutter;
import 'package:provider/provider.dart';
import 'package:talker_flutter/talker_flutter.dart';

import 'package:omi/app_globals.dart';
import 'package:omi/backend/http/shared.dart';
import 'package:omi/backend/preferences.dart';
import 'package:omi/core/app_shell.dart';
import 'package:omi/env/dev_env.dart';
import 'package:omi/env/env.dart';
import 'package:omi/env/prod_env.dart';
import 'package:omi/firebase_options_dev.dart' as dev;
import 'package:omi/firebase_options_prod.dart' as prod;
import 'package:omi/flavors.dart';
import 'package:omi/l10n/app_localizations.dart';
import 'package:omi/pages/apps/providers/add_app_provider.dart';
import 'package:omi/pages/conversation_detail/conversation_detail_provider.dart';
import 'package:omi/pages/payments/payment_method_provider.dart';
import 'package:omi/pages/persona/persona_provider.dart';
import 'package:omi/pages/settings/ai_app_generator_provider.dart';
import 'package:omi/providers/action_items_provider.dart';
import 'package:omi/providers/announcement_provider.dart';
import 'package:omi/providers/app_provider.dart';
import 'package:omi/providers/auth_provider.dart';
import 'package:omi/providers/calendar_provider.dart';
import 'package:omi/providers/capture_provider.dart';
import 'package:omi/providers/connectivity_provider.dart';
import 'package:omi/providers/conversation_provider.dart';
import 'package:omi/providers/developer_mode_provider.dart';
import 'package:omi/providers/device_provider.dart';
import 'package:omi/providers/folder_provider.dart';
import 'package:omi/providers/goals_provider.dart';
import 'package:omi/providers/home_provider.dart';
import 'package:omi/providers/integration_provider.dart';
import 'package:omi/providers/locale_provider.dart';
import 'package:omi/providers/mcp_provider.dart';
import 'package:omi/providers/memories_provider.dart';
import 'package:omi/providers/message_provider.dart';
import 'package:omi/providers/onboarding_provider.dart';
import 'package:omi/providers/people_provider.dart';
import 'package:omi/providers/speech_profile_provider.dart';
import 'package:omi/providers/sync_provider.dart';
import 'package:omi/providers/task_integration_provider.dart';
import 'package:omi/providers/usage_provider.dart';
import 'package:omi/providers/user_provider.dart';
import 'package:omi/providers/voice_recorder_provider.dart';
import 'package:omi/providers/phone_call_provider.dart';
import 'package:omi/services/auth_service.dart';
import 'package:omi/services/notifications.dart';
import 'package:omi/services/notifications/action_item_notification_handler.dart';
import 'package:omi/services/notifications/important_conversation_notification_handler.dart';
import 'package:omi/services/notifications/merge_notification_handler.dart';
import 'package:omi/services/services.dart';
import 'package:omi/utils/analytics/growthbook.dart';
import 'package:omi/utils/debug_log_manager.dart';
import 'package:omi/utils/debugging/crashlytics_manager.dart';
import 'package:omi/utils/l10n_extensions.dart';
import 'package:omi/utils/environment_detector.dart';
import 'package:omi/pages/settings/developer.dart';
import 'package:omi/utils/logger.dart';
import 'package:omi/utils/platform/platform_manager.dart';
import 'package:omi/services/aisa_firestore_service.dart';
import 'package:omi/utils/aisa_debug_logger.dart';

/// Background message handler for FCM data messages
@pragma('vm:entry-point')
Future<void> _firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  await Firebase.initializeApp();

  await AwesomeNotifications().initialize(null, [
    NotificationChannel(
      channelKey: 'channel',
      channelName: 'Omi Notifications',
      channelDescription: 'Notification channel for Omi',
      defaultColor: const Color(0xFF9D50DD),
      ledColor: Colors.white,
    ),
  ]);

  final data = message.data;
  final messageType = data['type'];
  const channelKey = 'channel';

  // Handle action item messages
  if (messageType == 'action_item_reminder') {
    await ActionItemNotificationHandler.handleReminderMessage(data, channelKey);
  } else if (messageType == 'action_item_update') {
    await ActionItemNotificationHandler.handleUpdateMessage(data, channelKey);
  } else if (messageType == 'action_item_delete') {
    await ActionItemNotificationHandler.handleDeletionMessage(data);
  } else if (messageType == 'merge_completed') {
    await MergeNotificationHandler.handleMergeCompleted(data, channelKey, isAppInForeground: false);
  } else if (messageType == 'important_conversation') {
    await ImportantConversationNotificationHandler.handleImportantConversation(
      data,
      channelKey,
      isAppInForeground: false,
    );
  }
}

Future _init() async {
  // [A.I.S.A.] 起動ステップログ: どのステップで止まるか特定するため
  void step(String name) => debugPrint('[AISA-INIT] >>> $name');

  // 【最優先】AISAログのファイル永続化を有効化する。
  // アプリがクラッシュ/killされても原因調査できるよう、
  // 他のどの初期化よりも先にディスク書き込みを開始する。
  // initFileLoggingは内部でtry/catchしているため失敗しても起動は続行。
  step('0: AisaDebugLogger.initFileLogging START');
  try {
    await AisaDebugLogger.instance.initFileLogging().timeout(
      const Duration(seconds: 3),
      onTimeout: () => debugPrint('[AISA] initFileLogging timeout'),
    );
  } catch (e) {
    debugPrint('[AISA] initFileLogging error: $e');
  }
  step('0: AisaDebugLogger.initFileLogging DONE');

  step('1: Env.init');
  if (F.env == Environment.prod) {
    Env.init(ProdEnv());
  } else {
    Env.init(DevEnv());
  }

  step('2: FlutterForegroundTask.initCommunicationPort');
  FlutterForegroundTask.initCommunicationPort();

  step('3: ServiceManager.init START');
  try {
    await ServiceManager.init().timeout(
      const Duration(seconds: 10),
      onTimeout: () => debugPrint('[AISA] ServiceManager.init timed out (10s)'),
    );
  } catch (e) {
    debugPrint('[AISA] ServiceManager.init error: $e');
  }
  step('3: ServiceManager.init DONE');

  step('4: Firebase.initializeApp START');
  try {
    if (Firebase.apps.isEmpty) {
      final options = F.env == Environment.prod
          ? prod.DefaultFirebaseOptions.currentPlatform
          : dev.DefaultFirebaseOptions.currentPlatform;
      await Firebase.initializeApp(options: options).timeout(
        const Duration(seconds: 15),
        onTimeout: () => throw TimeoutException('Firebase.initializeApp', const Duration(seconds: 15)),
      );
    } else {
      debugPrint('Firebase already initialized.');
    }
  } catch (e) {
    debugPrint('[AISA] Firebase.initializeApp error/timeout: $e');
  }
  step('4: Firebase.initializeApp DONE');

  step('5: AisaFirestoreService.initialize START');
  try {
    await AisaFirestoreService.instance.initialize().timeout(
      const Duration(seconds: 10),
      onTimeout: () => debugPrint('[AISA] Firestore初期化タイムアウト（10s）— スキップして続行'),
    );
  } catch (e) {
    debugPrint('[AISA] AisaFirestoreService error: $e');
  }
  step('5: AisaFirestoreService.initialize DONE');

  step('6: PlatformManager.initializeServices START');
  try {
    await PlatformManager.initializeServices().timeout(
      const Duration(seconds: 10),
      onTimeout: () => debugPrint('[AISA] PlatformManager.initializeServices timed out (10s)'),
    );
  } catch (e) {
    debugPrint('[AISA] PlatformManager.initializeServices error: $e');
  }
  step('6: PlatformManager.initializeServices DONE');

  step('7: NotificationService.initialize START');
  try {
    await NotificationService.instance.initialize().timeout(
      const Duration(seconds: 15),
      onTimeout: () => debugPrint('[AISA] NotificationService.initialize timed out (15s)'),
    );
  } catch (e) {
    debugPrint('[AISA] NotificationService.initialize error: $e');
  }
  step('7: NotificationService.initialize DONE');

  // Register FCM background message handler
  if (PlatformManager().isFCMSupported) {
    FirebaseMessaging.onBackgroundMessage(_firebaseMessagingBackgroundHandler);
  }

  step('8: SharedPreferencesUtil.init START');
  await SharedPreferencesUtil.init();
  step('8: SharedPreferencesUtil.init DONE');

  // TestFlight environment detection — must be after SharedPreferencesUtil.init()
  // devフレーバーなのでこのブロックは実行されない
  if (F.env == Environment.prod) {
    final isTestFlight = await EnvironmentDetector.isTestFlight();
    if (isTestFlight) {
      Env.isTestFlight = true;
      if (SharedPreferencesUtil().testFlightUseStagingApi) {
        final staging = Env.stagingApiUrl;
        if (staging != null) {
          Env.overrideApiBaseUrl(staging);
          debugPrint('TestFlight detected: using staging backend ($staging)');
        } else {
          debugPrint('TestFlight detected: staging preferred but STAGING_API_URL not configured, using production');
        }
      } else {
        debugPrint('TestFlight detected: user chose production backend');
      }
    }
  }

  step('9: getIdToken START');
  String? idToken;
  try {
    idToken = await AuthService.instance.getIdToken().timeout(
      const Duration(seconds: 10),
      onTimeout: () {
        debugPrint('[AISA] getIdToken timed out (10s) — continuing without auth');
        return null;
      },
    );
  } catch (e) {
    debugPrint('[AISA] getIdToken error: $e');
  }
  bool isAuth = idToken != null;
  step('9: getIdToken DONE isAuth=$isAuth');

  if (isAuth) {
    PlatformManager.instance.mixpanel.identify();
    if (!SharedPreferencesUtil().onboardingCompleted) {
      step('9b: restoreOnboardingState START');
      try {
        await AuthService.instance.restoreOnboardingState().timeout(
          const Duration(seconds: 10),
          onTimeout: () => debugPrint('[AISA] restoreOnboardingState timed out (10s) — skipping'),
        );
      } catch (e) {
        debugPrint('[AISA] restoreOnboardingState error: $e');
      }
      step('9b: restoreOnboardingState DONE');
    }
  }

  step('10: opus_flutter.load START');
  try {
    initOpus(await opus_flutter.load().timeout(
      const Duration(seconds: 10),
      onTimeout: () => throw TimeoutException('opus_flutter.load', const Duration(seconds: 10)),
    ));
  } catch (e) {
    debugPrint('[AISA] opus_flutter.load error/timeout: $e');
  }
  step('10: opus_flutter.load DONE');

  step('11: GrowthbookUtil.init START');
  try {
    await GrowthbookUtil.init().timeout(
      const Duration(seconds: 5),
      onTimeout: () => debugPrint('[AISA] GrowthbookUtil.init timed out (5s)'),
    );
  } catch (e) {
    debugPrint('[AISA] GrowthbookUtil.init error: $e');
  }
  step('11: GrowthbookUtil.init DONE');
  // Register native BLE bridge
  BleFlutterApi.setUp(BleBridge.instance);

  BleBridge.instance.stateRestoredCallback = (List<String> peripheralUuids) {
    Logger.debug('main: restored ${peripheralUuids.length} BLE peripherals');
  };

  step('12: CrashlyticsManager.init START');
  try {
    await CrashlyticsManager.init().timeout(
      const Duration(seconds: 5),
      onTimeout: () => debugPrint('[AISA] CrashlyticsManager.init timed out (5s)'),
    );
  } catch (e) {
    debugPrint('[AISA] CrashlyticsManager.init error: $e');
  }
  step('12: CrashlyticsManager.init DONE');

  if (isAuth) {
    PlatformManager.instance.crashReporter.identifyUser(
      FirebaseAuth.instance.currentUser?.email ?? '',
      SharedPreferencesUtil().fullName,
      SharedPreferencesUtil().uid,
    );
  }
  FlutterError.onError = (FlutterErrorDetails details) {
    FirebaseCrashlytics.instance.recordFlutterFatalError(details);
  };

  PlatformDispatcher.instance.onError = (error, stack) {
    FirebaseCrashlytics.instance.recordError(error, stack, fatal: true);
    return true;
  };

  step('13: ServiceManager.start START');
  try {
    await ServiceManager.instance().start().timeout(
      const Duration(seconds: 10),
      onTimeout: () => debugPrint('[AISA] ServiceManager.start timed out (10s)'),
    );
  } catch (e) {
    debugPrint('[AISA] ServiceManager.start error: $e');
  }
  step('13: ServiceManager.start DONE');
  step('_init() COMPLETE — calling runApp next');
  return;
}

void main() {
  runZonedGuarded(() async {
    // Ensure
    if (kDebugMode) {
      MarionetteBinding.ensureInitialized();
    } else {
      WidgetsFlutterBinding.ensureInitialized();
    }
    await _init();
    runApp(const MyApp());
  }, (error, stack) => FirebaseCrashlytics.instance.recordError(error, stack, fatal: true));
}

class MyApp extends StatefulWidget {
  const MyApp({super.key});

  @override
  State<MyApp> createState() => _MyAppState();

  static _MyAppState of(BuildContext context) => context.findAncestorStateOfType<_MyAppState>()!;

  // The navigator key is necessary to navigate using static methods
  // Delegates to the extracted globalNavigatorKey so files don't need to import main.dart
  static GlobalKey<NavigatorState> get navigatorKey => globalNavigatorKey;
}

class _MyAppState extends State<MyApp> with WidgetsBindingObserver {
  @override
  void initState() {
    NotificationUtil.initializeNotificationsEventListeners();
    NotificationUtil.initializeIsolateReceivePort();
    WidgetsBinding.instance.addObserver(this);
    if (SharedPreferencesUtil().devLogsToFileEnabled) {
      DebugLogManager.setEnabled(true);
    }

    super.initState();
  }

  void _deinit() {
    Logger.debug("App > _deinit");
    ServiceManager.instance().deinit();
    ApiClient.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);

    if (state == AppLifecycleState.paused) {
      _onAppPaused();
    } else if (state == AppLifecycleState.detached) {
      _deinit();
    }
  }

  void _onAppPaused() {
    imageCache.clear();
    imageCache.clearLiveImages();
  }

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ListenableProvider(create: (context) => ConnectivityProvider()),
        ChangeNotifierProvider(create: (context) => AuthenticationProvider()),
        ChangeNotifierProvider(create: (context) => ConversationProvider()),
        ListenableProvider(create: (context) => AppProvider()),
        ChangeNotifierProvider(create: (context) => PeopleProvider()),
        ChangeNotifierProvider(create: (context) => UsageProvider()),
        ChangeNotifierProxyProvider<AppProvider, MessageProvider>(
          create: (context) => MessageProvider(),
          update: (BuildContext context, value, MessageProvider? previous) =>
              (previous?..updateAppProvider(value)) ?? MessageProvider(),
        ),
        ChangeNotifierProxyProvider4<
          ConversationProvider,
          MessageProvider,
          PeopleProvider,
          UsageProvider,
          CaptureProvider
        >(
          create: (context) => CaptureProvider(),
          update: (BuildContext context, conversation, message, people, usage, CaptureProvider? previous) =>
              (previous?..updateProviderInstances(conversation, message, people, usage)) ?? CaptureProvider(),
        ),
        ChangeNotifierProxyProvider<CaptureProvider, DeviceProvider>(
          create: (context) => DeviceProvider(),
          update: (BuildContext context, captureProvider, DeviceProvider? previous) =>
              (previous?..setProviders(captureProvider)) ?? DeviceProvider(),
        ),
        ChangeNotifierProxyProvider<DeviceProvider, OnboardingProvider>(
          create: (context) => OnboardingProvider(),
          update: (BuildContext context, value, OnboardingProvider? previous) =>
              (previous?..setDeviceProvider(value)) ?? OnboardingProvider(),
        ),
        ListenableProvider(create: (context) => HomeProvider()),
        ChangeNotifierProxyProvider<DeviceProvider, SpeechProfileProvider>(
          create: (context) => SpeechProfileProvider(),
          update: (BuildContext context, device, SpeechProfileProvider? previous) =>
              (previous?..setProviders(device)) ?? SpeechProfileProvider(),
        ),
        ChangeNotifierProxyProvider2<AppProvider, ConversationProvider, ConversationDetailProvider>(
          create: (context) => ConversationDetailProvider(),
          update: (BuildContext context, app, conversation, ConversationDetailProvider? previous) =>
              (previous?..setProviders(app, conversation)) ?? ConversationDetailProvider(),
        ),
        ChangeNotifierProvider(create: (context) => DeveloperModeProvider()..initialize()),
        ChangeNotifierProvider(create: (context) => McpProvider()),
        ChangeNotifierProxyProvider<AppProvider, AddAppProvider>(
          create: (context) => AddAppProvider(),
          update: (BuildContext context, value, AddAppProvider? previous) =>
              (previous?..setAppProvider(value)) ?? AddAppProvider(),
        ),
        ChangeNotifierProxyProvider<AppProvider, AiAppGeneratorProvider>(
          create: (context) => AiAppGeneratorProvider(),
          update: (BuildContext context, value, AiAppGeneratorProvider? previous) =>
              (previous?..setAppProvider(value)) ?? AiAppGeneratorProvider(),
        ),
        ChangeNotifierProvider(create: (context) => PaymentMethodProvider()),
        ChangeNotifierProvider(create: (context) => PersonaProvider()),
        ChangeNotifierProxyProvider<ConnectivityProvider, MemoriesProvider>(
          create: (context) => MemoriesProvider(),
          update: (context, connectivity, previous) =>
              (previous?..setConnectivityProvider(connectivity)) ?? MemoriesProvider(),
        ),
        ChangeNotifierProvider(create: (context) => UserProvider()),
        ChangeNotifierProvider(create: (context) => ActionItemsProvider()),
        ChangeNotifierProvider(create: (context) => GoalsProvider()..init()),
        ChangeNotifierProvider(create: (context) => SyncProvider()),
        ChangeNotifierProvider(create: (context) => TaskIntegrationProvider()),
        ChangeNotifierProvider(create: (context) => IntegrationProvider()),
        ChangeNotifierProvider(create: (context) => CalendarProvider(), lazy: false),
        ChangeNotifierProvider(create: (context) => FolderProvider()),
        ChangeNotifierProvider(create: (context) => LocaleProvider()),
        ChangeNotifierProvider(create: (context) => VoiceRecorderProvider()),
        ChangeNotifierProvider(create: (context) => AnnouncementProvider()),
        ChangeNotifierProvider(create: (context) => PhoneCallProvider()),
      ],
      builder: (context, child) {
        return WithForegroundTask(
          child: MaterialApp(
            debugShowCheckedModeBanner: F.env == Environment.dev,
            title: F.title,
            navigatorKey: MyApp.navigatorKey,
            locale: context.watch<LocaleProvider>().locale,
            localizationsDelegates: const [
              AppLocalizations.delegate,
              GlobalMaterialLocalizations.delegate,
              GlobalWidgetsLocalizations.delegate,
              GlobalCupertinoLocalizations.delegate,
            ],
            supportedLocales: AppLocalizations.supportedLocales,
            theme: ThemeData(
              useMaterial3: false,
              colorScheme: const ColorScheme.dark(
                primary: Colors.black,
                secondary: Colors.deepPurple,
                surface: Colors.black38,
              ),
              snackBarTheme: const SnackBarThemeData(
                backgroundColor: Color(0xFF1F1F25),
                contentTextStyle: TextStyle(fontSize: 16, color: Colors.white, fontWeight: FontWeight.w500),
              ),
              textTheme: TextTheme(
                titleLarge: const TextStyle(fontSize: 18, color: Colors.white),
                titleMedium: const TextStyle(fontSize: 16, color: Colors.white),
                bodyMedium: const TextStyle(fontSize: 14, color: Colors.white),
                labelMedium: TextStyle(fontSize: 12, color: Colors.grey.shade200),
              ),
              textSelectionTheme: const TextSelectionThemeData(
                cursorColor: Colors.white,
                selectionColor: Colors.deepPurple,
                selectionHandleColor: Colors.white,
              ),
              cupertinoOverrideTheme: const CupertinoThemeData(
                primaryColor: Colors.white, // Controls the selection handles on iOS
              ),
            ),
            themeMode: ThemeMode.dark,
            builder: (context, child) {
              FlutterError.onError = (FlutterErrorDetails details) {
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  Logger.instance.talker.handle(details.exception, details.stack);
                  DebugLogManager.logError(details.exception, details.stack, 'FlutterError');
                });
              };
              ErrorWidget.builder = (errorDetails) {
                return CustomErrorWidget(errorMessage: errorDetails.exceptionAsString());
              };
              if (Env.isUsingStagingApi) {
                final topPadding = MediaQuery.of(context).padding.top;
                return Column(
                  children: [
                    GestureDetector(
                      onTap: () {
                        MyApp.navigatorKey.currentState?.push(
                          MaterialPageRoute(builder: (context) => const DeveloperSettingsPage()),
                        );
                      },
                      child: Container(
                        width: double.infinity,
                        padding: EdgeInsets.only(top: topPadding + 4, bottom: 4),
                        color: Colors.orange.shade800,
                        child: Text(
                          context.l10n.staging.toUpperCase(),
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            decoration: TextDecoration.none,
                          ),
                        ),
                      ),
                    ),
                    Expanded(
                      child: MediaQuery.removePadding(context: context, removeTop: true, child: child!),
                    ),
                  ],
                );
              }
              return child!;
            },
            home: TalkerWrapper(
              talker: Logger.instance.talker,
              options: const TalkerWrapperOptions(enableErrorAlerts: false, enableExceptionAlerts: false),
              child: const AppShell(),
            ),
          ),
        );
      },
    );
  }
}

class CustomErrorWidget extends StatelessWidget {
  final String errorMessage;

  const CustomErrorWidget({super.key, required this.errorMessage});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.error_outline, color: Colors.red, size: 50.0),
            const SizedBox(height: 10.0),
            Text(
              context.l10n.somethingWentWrong,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 18.0, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 10.0),
            Container(
              padding: const EdgeInsets.all(10),
              margin: const EdgeInsets.all(16),
              height: 200,
              decoration: BoxDecoration(
                color: const Color.fromARGB(255, 63, 63, 63),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(errorMessage, textAlign: TextAlign.start, style: const TextStyle(fontSize: 16.0)),
            ),
            const SizedBox(height: 10.0),
            SizedBox(
              width: 210,
              child: ElevatedButton(
                style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
                onPressed: () {
                  Clipboard.setData(ClipboardData(text: errorMessage));
                  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(context.l10n.errorCopied)));
                },
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    Text(context.l10n.copyErrorMessage),
                    const SizedBox(width: 10),
                    const Icon(Icons.copy_rounded),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
