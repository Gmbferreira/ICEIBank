"""Reconstroi o historico de liderancas a partir dos logs das 3 agencias (Sprint 3, Parte C).

Le todos os agencia/data/*.jsonl, filtra os eventos do algoritmo de Bully e
imprime, em ordem de relogio de parede:

  1. o historico de eventos de eleicao (quem iniciou, recebeu, anunciou...);
  2. a linha do tempo de lideres (cada TORNOU_LIDER), classificada:
       - lider inicial         primeira lider do log, ou a primeira depois que a
                               lider anterior reiniciou (nova execucao);
       - reafirmacao           a mesma agencia se declarando de novo (a
                               "tempestade" de eleicoes da subida);
       - troca X -> Y          a lideranca mudou de maos de fato - apos a queda
                               da lider (LIDER_NAO_RESPONDEU) ou porque uma
                               agencia de ID maior voltou e tomou a lideranca;
  3. um resumo: quantas declaracoes x quantas trocas efetivas.

Os horarios sao mostrados no fuso local (o log grava em UTC), para baterem com o
Get-Date e o relogio do Windows nos prints de evidencia.

Uso:
    python historico_lideranca.py                    # todo o log
    python historico_lideranca.py --desde 19:41      # so a partir das 19:41 (hora local)
    python historico_lideranca.py --desde "2026-11-12 19:41"

Diferente do mesclar_logs.py, aqui a ordem e a do relogio de parede (como no
roteiro): o objetivo e contar a historia da lideranca, nao provar causalidade.
"""

import argparse
import json
import os
from datetime import datetime

# agencia/historico_lideranca.py -> agencia/data
PASTA_DADOS = os.path.join(os.path.dirname(os.path.abspath(__file__)), "data")

TIPOS_BULLY = (
    "ELEICAO_INICIADA",
    "ELEICAO_RECEBIDA",
    "TORNOU_LIDER",
    "LIDER_ANUNCIADO",
    "LIDER_NAO_RESPONDEU",
)


def id_da_agencia(evento):
    """"agencia-1" -> 1. Devolve None se o nome nao estiver no formato esperado."""
    try:
        return int(evento.get("agencia", "").rsplit("-", 1)[1])
    except (IndexError, ValueError):
        return None


def carregar_eventos_bully():
    if not os.path.isdir(PASTA_DADOS):
        raise SystemExit(f"Pasta de logs nao encontrada: {PASTA_DADOS}")
    arquivos = sorted(f for f in os.listdir(PASTA_DADOS) if f.endswith(".jsonl"))
    if not arquivos:
        raise SystemExit(f"Nenhum arquivo .jsonl encontrado em {PASTA_DADOS}.")

    eventos = []
    for arquivo in arquivos:
        with open(os.path.join(PASTA_DADOS, arquivo), encoding="utf-8") as aberto:
            for linha in aberto:
                linha = linha.strip()
                if not linha:
                    continue
                evento = json.loads(linha)
                if evento.get("tipo") not in TIPOS_BULLY:
                    continue
                # horaParede e ISO com fuso (UTC). astimezone() sem argumento
                # converte para o fuso local da maquina.
                evento["hora_local"] = datetime.fromisoformat(evento["horaParede"]).astimezone()
                eventos.append(evento)

    eventos.sort(key=lambda e: e["hora_local"])
    return eventos


def agencia_acabou_de_iniciar(evento):
    """ELEICAO_INICIADA com a propria posicao do vetor em 1 = processo recem-iniciado.

    O relogio vetorial vive na memoria e zera quando a agencia reinicia; o
    primeiro evento de cada vida do processo e a eleicao disparada no startup.
    """
    if evento["tipo"] != "ELEICAO_INICIADA":
        return False
    id_agencia = id_da_agencia(evento)
    vetor = evento.get("timestampVetorial") or []
    return id_agencia is not None and id_agencia < len(vetor) and vetor[id_agencia] == 1


def classificar_liderancas(eventos):
    """Percorre o log em ordem e rotula cada TORNOU_LIDER.

    Anota em cada evento TORNOU_LIDER a chave "classificacao" e devolve a lista
    desses eventos. A classificacao usa o log inteiro (mesmo com --desde), para
    que o primeiro evento exibido nao seja confundido com uma "lider inicial".
    """
    lider = None              # lider segundo o log ate aqui
    lider_caiu = None         # lider que alguma agencia registrou como fora do ar
    liderancas = []

    for evento in eventos:
        if agencia_acabou_de_iniciar(evento) and id_da_agencia(evento) == lider:
            # A propria lider reiniciou: a lideranca anterior acabou junto com o
            # processo. A proxima declaracao conta como lider inicial de novo.
            lider = None
            lider_caiu = None

        if evento["tipo"] == "LIDER_NAO_RESPONDEU":
            lider_caiu = evento["detalhes"].get("liderAtual")

        if evento["tipo"] != "TORNOU_LIDER":
            continue

        nova = evento["detalhes"].get("idAgencia")
        if lider is None:
            evento["classificacao"] = "lider inicial"
            evento["troca"] = False
        elif nova == lider:
            evento["classificacao"] = "reafirmacao (ja era a lider)"
            evento["troca"] = False
        else:
            if lider_caiu == lider:
                motivo = f"apos queda da lider {lider}"
            elif nova > lider:
                motivo = f"agencia {nova}, de ID maior, voltou e tomou a lideranca"
            else:
                motivo = "sem queda registrada no log"
            evento["classificacao"] = f"TROCA {lider} -> {nova} ({motivo})"
            evento["troca"] = True
            lider_caiu = None
        lider = nova
        liderancas.append(evento)
    return liderancas


def interpretar_desde(texto, eventos):
    """'HH:MM' (no dia do evento mais recente) ou 'AAAA-MM-DD HH:MM', hora local."""
    texto = texto.strip()
    fuso_local = datetime.now().astimezone().tzinfo
    try:
        return datetime.strptime(texto, "%Y-%m-%d %H:%M").replace(tzinfo=fuso_local)
    except ValueError:
        pass
    try:
        hora = datetime.strptime(texto, "%H:%M").time()
    except ValueError:
        raise SystemExit(f"--desde invalido: '{texto}'. Use HH:MM ou \"AAAA-MM-DD HH:MM\".")
    dia = eventos[-1]["hora_local"].date() if eventos else datetime.now().date()
    return datetime.combine(dia, hora).replace(tzinfo=fuso_local)


def formatar_hora(evento):
    hora = evento["hora_local"]
    return hora.strftime("%d/%m %H:%M:%S.") + f"{hora.microsecond // 1000:03d}"


def formatar_vetor(evento):
    vetor = evento.get("timestampVetorial") or []
    return "[" + ", ".join(str(v) for v in vetor) + "]"


def main():
    parser = argparse.ArgumentParser(description="Historico de liderancas (algoritmo de Bully).")
    parser.add_argument("--desde", help="mostra so eventos a partir deste horario local (HH:MM)")
    args = parser.parse_args()

    eventos = carregar_eventos_bully()
    if not eventos:
        raise SystemExit("Nenhum evento de eleicao nos logs. As agencias ja subiram com o Sprint 3?")

    liderancas = classificar_liderancas(eventos)

    if args.desde:
        inicio = interpretar_desde(args.desde, eventos)
        eventos = [e for e in eventos if e["hora_local"] >= inicio]
        liderancas = [e for e in liderancas if e["hora_local"] >= inicio]
        print(f"(filtro: eventos a partir de {inicio.strftime('%d/%m/%Y %H:%M')}, hora local)")
        print()

    print("=== Historico de eventos de eleicao ===")
    for evento in eventos:
        if agencia_acabou_de_iniciar(evento):
            print(f"--- {evento['agencia']} iniciou (relogio vetorial zerado) ---")
        detalhes = json.dumps(evento.get("detalhes", {}), ensure_ascii=False)
        print(
            f"({formatar_hora(evento)}) [{evento['agencia']}] "
            f"{formatar_vetor(evento):14} {evento['tipo']:20} {detalhes}"
        )

    print()
    print("=== Linha do tempo de lideres ===")
    for evento in liderancas:
        print(
            f"A partir de {formatar_hora(evento)}: Agencia {evento['detalhes'].get('idAgencia')} "
            f"e a lider   [{evento['classificacao']}]"
        )

    trocas = [e for e in liderancas if e["troca"]]
    iniciais = [e for e in liderancas if e["classificacao"] == "lider inicial"]
    reafirmacoes = len(liderancas) - len(trocas) - len(iniciais)
    print()
    print("=== Resumo ===")
    print(f"Declaracoes de lideranca (TORNOU_LIDER): {len(liderancas)}")
    print(f"  lider inicial (inicio de execucao):   {len(iniciais)}")
    print(f"  reafirmacoes (mesma agencia de novo):  {reafirmacoes}")
    print(f"  trocas efetivas de lider:              {len(trocas)}")
    if liderancas:
        print(f"Lider ao final do trecho exibido: agencia {liderancas[-1]['detalhes'].get('idAgencia')}")


if __name__ == "__main__":
    main()
