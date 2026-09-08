import type { Conta, Historico, RespostaLogin } from "./types";

const TOKEN_CHAVE = "iceibank_token";
const BASE_CHAVE = "iceibank_base_url";

export function salvarToken(token: string): void {
  localStorage.setItem(TOKEN_CHAVE, token);
}

export function tokenAtual(): string | null {
  return localStorage.getItem(TOKEN_CHAVE);
}

export function limparToken(): void {
  localStorage.removeItem(TOKEN_CHAVE);
}

export function salvarBaseUrl(url: string): void {
  localStorage.setItem(BASE_CHAVE, url);
}

export function baseUrl(): string {
  return localStorage.getItem(BASE_CHAVE) || "http://localhost:4021";
}

export class ApiErro extends Error {
  status: number;

  constructor(status: number, mensagem: string) {
    super(mensagem);
    this.name = "ApiErro";
    this.status = status;
  }
}

interface Opcoes extends RequestInit {
  headers?: Record<string, string>;
}

async function requisicao(caminho: string, opcoes: Opcoes = {}): Promise<unknown> {
  const cabecalhos: Record<string, string> = { ...(opcoes.headers ?? {}) };
  const token = tokenAtual();
  if (token) cabecalhos.Authorization = `Bearer ${token}`;
  if (opcoes.body) cabecalhos["Content-Type"] = "application/json";

  const resposta = await fetch(`${baseUrl()}${caminho}`, { ...opcoes, headers: cabecalhos });

  if (!resposta.ok) {
    let mensagem = `Erro HTTP ${resposta.status}`;
    try {
      const corpo = await resposta.json();
      if (corpo.erro) mensagem = String(corpo.erro);
    } catch {
      // corpo nao-JSON: usa a mensagem padrao
    }
    throw new ApiErro(resposta.status, mensagem);
  }
  if (resposta.status === 204) return null;
  return resposta.json();
}

export const api = {
  login: (usuario: string, senha: string): Promise<RespostaLogin> =>
    requisicao("/auth/login", { method: "POST", body: JSON.stringify({ usuario, senha }) }) as Promise<RespostaLogin>,

  criarConta: (id: number, nomeAluno: string, saldoInicial: number): Promise<Conta> =>
    requisicao("/contas", { method: "POST", body: JSON.stringify({ id, nomeAluno, saldoInicial }) }) as Promise<Conta>,

  consultarSaldo: (id: number): Promise<Conta> => requisicao(`/contas/${id}`) as Promise<Conta>,

  depositar: (id: number, valor: number): Promise<Conta> =>
    requisicao(`/contas/${id}/depositar`, { method: "POST", body: JSON.stringify({ valor }) }) as Promise<Conta>,

  sacar: (id: number, valor: number): Promise<Conta> =>
    requisicao(`/contas/${id}/sacar`, { method: "POST", body: JSON.stringify({ valor }) }) as Promise<Conta>,

  transferir: (idOrigem: number, idDestino: number, valor: number): Promise<{ mensagem: string }> =>
    requisicao("/transferencias", { method: "POST", body: JSON.stringify({ idOrigem, idDestino, valor }) }) as Promise<{
      mensagem: string;
    }>,

  historico: (id: number): Promise<Historico> => requisicao(`/contas/${id}/historico`) as Promise<Historico>,
};