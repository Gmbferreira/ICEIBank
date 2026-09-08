import { useState } from "react";
import type { FormEvent } from "react";
import { api, ApiErro, baseUrl, limparToken, salvarBaseUrl, salvarToken, tokenAtual } from "./api";
import type { Conta, EventoHistorico } from "./types";

interface Mensagem {
  tipo: "ok" | "erro" | "info";
  texto: string;
}

const AGENCIAS = [
  { id: 0, url: "http://localhost:4021", rotulo: "Agência 0 (porta 4021)" },
  { id: 1, url: "http://localhost:4022", rotulo: "Agência 1 (porta 4022)" },
  { id: 2, url: "http://localhost:4023", rotulo: "Agência 2 (porta 4023)" },
];

export default function App() {
  const [entrada, setEntrada] = useState<string>(() => baseUrl());
  const [token, setToken] = useState<string | null>(() => tokenAtual());
  const [mensagem, setMensagem] = useState<Mensagem | null>(null);

  const [usuario, setUsuario] = useState("admin");
  const [senha, setSenha] = useState("");
  const [contaId, setContaId] = useState("");
  const [valor, setValor] = useState("");
  const [idOrigem, setIdOrigem] = useState("");
  const [idDestino, setIdDestino] = useState("");
  const [nomeAluno, setNomeAluno] = useState("");
  const [saldoInicial, setSaldoInicial] = useState("");

  const [contaMostrada, setContaMostrada] = useState<Conta | null>(null);
  const [historico, setHistorico] = useState<EventoHistorico[]>([]);

  function trocarAgencia(url: string) {
    setEntrada(url);
    salvarBaseUrl(url);
    setContaMostrada(null);
    setHistorico([]);
    setMensagem({
      tipo: "info",
      texto:
        `Frontend agora aponta para ${url}. ` +
        "Cada agência só responde pelas contas sob sua responsabilidade (id % 3): use a agência dona da conta que quer operar.",
    });
  }

  function tratarErro(e: unknown): string {
    if (e instanceof ApiErro) {
      if (e.status === 401) {
        limparToken();
        setToken(null);
        setContaMostrada(null);
        setHistorico([]);
        return "Sessão expirada ou token inválido. Faça login novamente.";
      }
      return e.message;
    }
    return "Falha de comunicação com a agência. Verifique se ela está no ar e se a porta de entrada está correta.";
  }

  async function executar(acao: () => Promise<void>) {
    setMensagem(null);
    try {
      await acao();
    } catch (e) {
      setMensagem({ tipo: "erro", texto: tratarErro(e) });
    }
  }

  async function fazerLogin(ev: FormEvent) {
    ev.preventDefault();
    await executar(async () => {
      const resposta = await api.login(usuario, senha);
      salvarToken(resposta.access_token);
      setToken(resposta.access_token);
      setMensagem({ tipo: "ok", texto: "Login efetuado com sucesso." });
    });
  }

  function sair() {
    limparToken();
    setToken(null);
    setContaMostrada(null);
    setHistorico([]);
  }

  function atualizarConta(conta: Conta) {
    setContaMostrada(conta);
    setHistorico([]);
  }

  const idNum = Number(contaId);
  const valorNum = Number(valor);

  return (
    <div className="min-h-screen bg-slate-100 text-slate-800">
      <header className="bg-slate-900 text-white shadow">
        <div className="mx-auto flex max-w-4xl items-center justify-between px-4 py-4">
          <h1 className="text-xl font-bold">🧊 ICEIBank</h1>
          <label className="flex items-center gap-2 text-sm">
            Agência de entrada:
            <select
              className="rounded bg-slate-700 px-2 py-1 text-white"
              value={entrada}
              onChange={(e) => trocarAgencia(e.target.value)}
            >
              {AGENCIAS.map((a) => (
                <option key={a.id} value={a.url}>
                  {a.rotulo}
                </option>
              ))}
            </select>
          </label>
        </div>
      </header>

      <main className="mx-auto max-w-4xl px-4 py-6">
        {mensagem && (
          <div
            className={`mb-4 rounded border px-4 py-3 text-sm ${
              mensagem.tipo === "ok"
                ? "border-emerald-300 bg-emerald-50 text-emerald-800"
                : mensagem.tipo === "erro"
                  ? "border-rose-300 bg-rose-50 text-rose-800"
                  : "border-sky-300 bg-sky-50 text-sky-800"
            }`}
          >
            {mensagem.texto}
          </div>
        )}

        {!token ? (
          <div className="mx-auto mt-10 max-w-sm rounded-lg bg-white p-6 shadow">
            <h2 className="mb-4 text-lg font-semibold">Entrar no ICEIBank</h2>
            <form onSubmit={fazerLogin} className="flex flex-col gap-3">
              <div className="text-xs text-slate-500">
                Conectando em: <span className="font-mono">{entrada}</span>
              </div>
              <input
                className="rounded border border-slate-300 px-3 py-2 focus:outline-none focus:ring-2 focus:ring-slate-500"
                placeholder="Usuário"
                value={usuario}
                onChange={(e) => setUsuario(e.target.value)}
              />
              <input
                type="password"
                className="rounded border border-slate-300 px-3 py-2 focus:outline-none focus:ring-2 focus:ring-slate-500"
                placeholder="Senha"
                value={senha}
                onChange={(e) => setSenha(e.target.value)}
              />
              <button
                type="submit"
                className="rounded bg-slate-900 px-4 py-2 text-white hover:bg-slate-700"
              >
                Login
              </button>
            </form>
            <p className="mt-3 text-xs text-slate-400">
              Credenciais padrão: admin / icei123 (definidas no backend).
            </p>
          </div>
        ) : (
          <div className="flex flex-col gap-6">
            <div className="flex items-center justify-between">
              <p className="text-sm text-slate-600">
                Conectado em <span className="font-mono">{entrada}</span>
              </p>
              <button
                onClick={sair}
                className="rounded border border-slate-300 bg-white px-3 py-1 text-sm hover:bg-slate-200"
              >
                Sair
              </button>
            </div>

            <section className="rounded-lg bg-white p-5 shadow">
              <h2 className="mb-3 font-semibold">Operações de conta</h2>
              <div className="flex flex-wrap items-end gap-3">
                <div className="flex flex-col">
                  <label className="text-xs text-slate-500">Número da conta</label>
                  <input
                    className="w-28 rounded border border-slate-300 px-3 py-2"
                    inputMode="numeric"
                    value={contaId}
                    onChange={(e) => setContaId(e.target.value)}
                  />
                </div>
                <div className="flex flex-col">
                  <label className="text-xs text-slate-500">Valor</label>
                  <input
                    className="w-28 rounded border border-slate-300 px-3 py-2"
                    inputMode="decimal"
                    value={valor}
                    onChange={(e) => setValor(e.target.value)}
                  />
                </div>
                <div className="flex gap-2">
                  <button
                    onClick={() =>
                      executar(async () => {
                        atualizarConta(await api.consultarSaldo(idNum));
                        setMensagem({ tipo: "ok", texto: "Saldo consultado." });
                      })
                    }
                    className="rounded bg-slate-900 px-3 py-2 text-white hover:bg-slate-700"
                  >
                    Consultar saldo
                  </button>
                  <button
                    onClick={() =>
                      executar(async () => {
                        atualizarConta(await api.depositar(idNum, valorNum));
                        setMensagem({ tipo: "ok", texto: "Depósito realizado." });
                      })
                    }
                    className="rounded bg-emerald-700 px-3 py-2 text-white hover:bg-emerald-600"
                  >
                    Depositar
                  </button>
                  <button
                    onClick={() =>
                      executar(async () => {
                        atualizarConta(await api.sacar(idNum, valorNum));
                        setMensagem({ tipo: "ok", texto: "Saque realizado." });
                      })
                    }
                    className="rounded bg-amber-600 px-3 py-2 text-white hover:bg-amber-500"
                  >
                    Sacar
                  </button>
                  <button
                    onClick={() =>
                      executar(async () => {
                        const hist = await api.historico(idNum);
                        setHistorico(hist.eventos);
                        setMensagem({ tipo: "info", texto: `Histórico da conta ${hist.conta}:` });
                      })
                    }
                    className="rounded bg-sky-700 px-3 py-2 text-white hover:bg-sky-600"
                  >
                    Histórico
                  </button>
                </div>
              </div>
            </section>

            <section className="rounded-lg bg-white p-5 shadow">
              <h2 className="mb-3 font-semibold">Transferência</h2>
              <div className="flex flex-wrap items-end gap-3">
                <div className="flex flex-col">
                  <label className="text-xs text-slate-500">Conta de origem</label>
                  <input
                    className="w-28 rounded border border-slate-300 px-3 py-2"
                    inputMode="numeric"
                    value={idOrigem}
                    onChange={(e) => setIdOrigem(e.target.value)}
                  />
                </div>
                <div className="flex flex-col">
                  <label className="text-xs text-slate-500">Conta de destino</label>
                  <input
                    className="w-28 rounded border border-slate-300 px-3 py-2"
                    inputMode="numeric"
                    value={idDestino}
                    onChange={(e) => setIdDestino(e.target.value)}
                  />
                </div>
                <div className="flex flex-col">
                  <label className="text-xs text-slate-500">Valor</label>
                  <input
                    className="w-28 rounded border border-slate-300 px-3 py-2"
                    inputMode="decimal"
                    value={valor}
                    onChange={(e) => setValor(e.target.value)}
                  />
                </div>
                <button
                  onClick={() =>
                    executar(async () => {
                      const resposta = await api.transferir(Number(idOrigem), Number(idDestino), valorNum);
                      setMensagem({ tipo: "ok", texto: resposta.mensagem });
                      atualizarConta(await api.consultarSaldo(Number(idOrigem)));
                    })
                  }
                  className="rounded bg-slate-900 px-3 py-2 text-white hover:bg-slate-700"
                >
                  Transferir
                </button>
              </div>
              <p className="mt-2 text-xs text-slate-400">
                O backend decide sozinho se a transferência é local ou entre agências.
              </p>
            </section>

            <section className="rounded-lg bg-white p-5 shadow">
              <h2 className="mb-3 font-semibold">Criar conta</h2>
              <div className="flex flex-wrap items-end gap-3">
                <div className="flex flex-col">
                  <label className="text-xs text-slate-500">ID (conta)</label>
                  <input
                    className="w-28 rounded border border-slate-300 px-3 py-2"
                    inputMode="numeric"
                    value={contaId}
                    onChange={(e) => setContaId(e.target.value)}
                  />
                </div>
                <div className="flex flex-col">
                  <label className="text-xs text-slate-500">Nome do aluno</label>
                  <input
                    className="w-44 rounded border border-slate-300 px-3 py-2"
                    value={nomeAluno}
                    onChange={(e) => setNomeAluno(e.target.value)}
                  />
                </div>
                <div className="flex flex-col">
                  <label className="text-xs text-slate-500">Saldo inicial</label>
                  <input
                    className="w-28 rounded border border-slate-300 px-3 py-2"
                    inputMode="decimal"
                    value={saldoInicial}
                    onChange={(e) => setSaldoInicial(e.target.value)}
                  />
                </div>
                <button
                  onClick={() =>
                    executar(async () => {
                      atualizarConta(await api.criarConta(idNum, nomeAluno, Number(saldoInicial) || 0));
                      setMensagem({ tipo: "ok", texto: "Conta criada." });
                    })
                  }
                  className="rounded bg-indigo-700 px-3 py-2 text-white hover:bg-indigo-600"
                >
                  Criar
                </button>
              </div>
            </section>

            {contaMostrada && (
              <section className="rounded-lg bg-white p-5 shadow">
                <h2 className="mb-3 font-semibold">Conta {contaMostrada.id}</h2>
                <p>
                  Titular: <span className="font-medium">{contaMostrada.nomeAluno}</span>
                </p>
                <p className="text-2xl font-bold">R$ {contaMostrada.saldo.toFixed(2)}</p>
              </section>
            )}

            {historico.length > 0 && (
              <section className="rounded-lg bg-white p-5 shadow">
                <h2 className="mb-3 font-semibold">Histórico (ordenado por Lamport)</h2>
                <table className="w-full text-left text-sm">
                  <thead>
                    <tr className="border-b text-slate-500">
                      <th className="py-1 pr-3">Lamport</th>
                      <th className="py-1 pr-3">Tipo</th>
                      <th className="py-1">Detalhes</th>
                    </tr>
                  </thead>
                  <tbody>
                    {historico.map((evento, i) => (
                      <tr key={i} className="border-b last:border-0">
                        <td className="py-1 pr-3 font-mono">{evento.timestampLamport}</td>
                        <td className="py-1 pr-3">{evento.tipo}</td>
                        <td className="py-1 font-mono text-xs">
                          {JSON.stringify(evento.detalhes)}
                        </td>
                      </tr>
                    ))}
                  </tbody>
                </table>
              </section>
            )}
          </div>
        )}
      </main>
    </div>
  );
}