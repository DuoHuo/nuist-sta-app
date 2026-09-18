import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import 'core/app_info.dart';
import 'core/colors.dart';
import 'router.dart';

class NuistApp extends StatefulWidget {
  const NuistApp({super.key});

  @override
  State<NuistApp> createState() => _NuistAppState();
}

class _NuistAppState extends State<NuistApp> {
  late final GoRouter _router = buildRouter();

  @override
  Widget build(BuildContext context) {
    return MaterialApp.router(
      title: kAppName,
      theme: ThemeData(
        useMaterial3: true,
        scaffoldBackgroundColor: AppColors.pageBg,
        appBarTheme: const AppBarTheme(
          backgroundColor: Colors.white,
          surfaceTintColor: Colors.transparent,
          centerTitle: true,
          elevation: 0,
          titleTextStyle: TextStyle(
            color: AppColors.titleText,
            fontSize: 17,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
      routerConfig: _router,
    );
  }
}
