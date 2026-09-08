export interface Conta {
  id: number;
  nomeAluno: string;
  saldo: number;
}

export interface EventoHistorico {
  agencia: string;
  tipo: string;
  timestampLamport: number;
  horaParede: string;
  detalhes: Record<string, unknown>;
}

export interface RespostaLogin {
  access_token: string;
  tipo: string;
  expiracao_min: number;
}

export interface Historico {
  conta: number;
  eventos: EventoHistorico[];
}