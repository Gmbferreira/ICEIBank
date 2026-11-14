import 'package:material_ui/material_ui.dart';

import 'screens/home_screen.dart';
import 'screens/login_screen.dart';
import 'services/api_client.dart';
import 'services/sessao.dart';

Future<void> main() async {
  // Necessario antes de usar plugins (shared_preferences) fora de um widget.
  WidgetsFlutterBinding.ensureInitialized();
  final sessao = await Sessao.carregar();
  runApp(IceibankApp(api: ApiClient(sessao)));
}

class IceibankApp extends StatelessWidget {
  const IceibankApp({super.key, required this.api});

  final ApiClient api;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'ICEIBank',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF1B5E9E)),
        useMaterial3: true,
      ),
      // Com token salvo e ainda valido, abre direto na tela principal.
      home: api.sessao.ativa ? HomeScreen(api: api) : LoginScreen(api: api),
    );
  }
}
