// Configuracao das agencias que o app conhece.
//
// No emulador Android, "localhost" e o proprio celular virtual: o computador
// (onde as agencias rodam) e alcancado pelo endereco especial 10.0.2.2, que
// chega no 127.0.0.1 do Windows - exatamente onde o uvicorn escuta.
//
// Para rodar em outro alvo, troque o host sem mexer no codigo:
//   flutter run -d chrome --dart-define=API_HOST=127.0.0.1
//   flutter run --dart-define=API_HOST=192.168.0.10   (celular fisico na mesma rede)

const String apiHost = String.fromEnvironment('API_HOST', defaultValue: '10.0.2.2');

// 4021 = 4000 + OFFSET 21, igual ao agencia/src/config.py.
const int portaBase = int.fromEnvironment('PORTA_BASE', defaultValue: 4021);

const int numeroAgencias = 3;

// Tempo maximo de espera por uma agencia antes de considerar que ela nao
// respondeu. Maior que o timeout de 1 s do Bully, porque a rede do celular
// (e a ponte do emulador) e mais lenta que a comunicacao entre agencias.
const Duration timeoutRequisicao = Duration(seconds: 5);

/// IDs de todas as agencias conhecidas: 0, 1 e 2.
List<int> get idsAgencias => List<int>.generate(numeroAgencias, (i) => i);

/// Porta de uma agencia (4021, 4022 ou 4023).
int portaAgencia(int idAgencia) => portaBase + idAgencia;

/// URL base de uma agencia, ex.: http://10.0.2.2:4021
String urlAgencia(int idAgencia) => 'http://$apiHost:${portaAgencia(idAgencia)}';

/// Mesma regra de particao do backend (config.agencia_responsavel): a agencia
/// dona da conta e id_conta % numero_de_agencias.
int agenciaResponsavel(int idConta) => idConta % numeroAgencias;
