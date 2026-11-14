import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:iceibank_app/config.dart';
import 'package:iceibank_app/main.dart';
import 'package:iceibank_app/services/api_client.dart';
import 'package:iceibank_app/services/sessao.dart';

void main() {
  testWidgets('sem sessao, o app abre na tela de login', (tester) async {
    await tester.pumpWidget(IceibankApp(api: ApiClient(Sessao.vazia())));

    expect(find.text('ICEIBank'), findsOneWidget);
    expect(find.widgetWithText(TextField, 'Usuário'), findsOneWidget);
    expect(find.widgetWithText(TextField, 'Senha'), findsOneWidget);
    expect(find.text('Entrar'), findsOneWidget);
  });

  testWidgets('login sem preencher mostra erro visivel', (tester) async {
    await tester.pumpWidget(IceibankApp(api: ApiClient(Sessao.vazia())));

    await tester.tap(find.text('Entrar'));
    await tester.pump();

    expect(find.text('Informe usuario e senha.'), findsOneWidget);
  });

  test('a agencia responsavel segue a mesma regra do backend (id % 3)', () {
    expect(agenciaResponsavel(0), 0);
    expect(agenciaResponsavel(4), 1);
    expect(agenciaResponsavel(5), 2);
    expect(portaAgencia(2), 4023);
  });
}
