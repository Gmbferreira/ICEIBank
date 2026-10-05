"""Consulta as filas da instancia do RabbitMQ (material de evidencia do Sprint 2).

Mostra, para cada agencia, quantas mensagens estao retidas na fila principal e na
fila de falhas (dead-letter), e quantos consumidores estao conectados. E o que
comprova:

- no teste de resiliencia, que a mensagem publicada para uma agencia fora do ar
  ficou esperando na fila em vez de ter sido perdida;
- na Etapa 4, que o credito que a agencia nao conseguiu aplicar foi preservado
  em fila-agencia-<id>.falhas em vez de sumir sem deixar rastro.

Uso (com RABBITMQ_URL definida):
    .\\.venv\\Scripts\\python.exe filas.py --alerta --corpo

Com --alerta, avisa quando alguma fila tem mais de um consumidor. Como as filas
sao compartilhadas por todas as agencias do mesmo vhost, um consumidor a mais
significa que outro processo (agencia de outro terminal, ou uma instancia
esquecida de um teste anterior) pode roubar a mensagem antes da hora - o
credito apareceria na agencia errada. (Zero consumidores e o esperado no teste
de resiliencia, com a agencia fora do ar.)

Com --corpo, imprime o conteudo das mensagens retidas nas filas de falhas. Cada
mensagem lida e devolvida a fila (nack com requeue), entao a leitura nao altera
o que esta gravado no broker.
"""

import json
import os
import sys

import pika

TITULO = f"{'fila':30} {'mensagens':>10} {'consumidores':>14}"


def _abrir_canal(conexao):
    """Canal novo para cada consulta.

    Um passive declare em fila inexistente faz o broker FECHAR o canal (erro 404),
    entao um canal so nao serviria para varrer as seis filas: cada uma ganha o
    seu, e um canal morto nao afeta os demais.
    """
    return conexao.channel()


def _contar(conexao, fila, argumentos):
    """(mensagens, consumidores) da fila, ou (None, None) se ela nao existir."""
    canal = _abrir_canal(conexao)
    try:
        resultado = canal.queue_declare(queue=fila, durable=True, passive=True, arguments=argumentos)
        return resultado.method.message_count, resultado.method.consumer_count
    except pika.exceptions.ChannelClosedByBroker:
        return None, None
    finally:
        if canal.is_open:
            canal.close()


def _ler_falhas(conexao, fila, total):
    """Imprime o corpo das mensagens retidas e devolve cada uma a fila."""
    canal = _abrir_canal(conexao)
    try:
        for _ in range(total):
            metodo, _props, corpo = canal.basic_get(queue=fila, auto_ack=False)
            if metodo is None:
                break
            try:
                conteudo = json.loads(corpo.decode("utf-8"))
            except ValueError:
                conteudo = corpo.decode("utf-8", errors="replace")
            print(f"      conteudo: {json.dumps(conteudo, ensure_ascii=False)}")
            # Este script so inspeciona: devolve a mensagem, nada e consumido.
            canal.basic_nack(delivery_tag=metodo.delivery_tag, requeue=True)
    finally:
        if canal.is_open:
            canal.close()


def main():
    alerta = "--alerta" in sys.argv
    mostrar_corpo = "--corpo" in sys.argv
    url = os.getenv("RABBITMQ_URL")
    if not url:
        print("Defina RABBITMQ_URL antes de executar este script.")
        return 1

    # Os imports vem depois da checagem: src.services.mensageria exige a URL no
    # import e, se ela faltar, o traceback esconderia a mensagem acima.
    # Executar "python agencia/filas.py" ja coloca a pasta agencia/ no sys.path.
    from src.services.mensageria import (
        EXCHANGE,
        EXCHANGE_DLX,
        TTL_FILA_FALHAS_MS,
        argumentos_fila,
        nome_fila,
        nome_fila_falhas,
    )

    import src.config as config

    conexao = pika.BlockingConnection(pika.URLParameters(url))
    try:
        print(f"exchange de entrada: {EXCHANGE} (topic, durable)")
        print(f"exchange de falhas:  {EXCHANGE_DLX} (topic, durable)")
        print(f"TTL das falhas:      {TTL_FILA_FALHAS_MS // (24 * 60 * 60 * 1000)} dias")
        print(TITULO)
        for agencia in config.AGENCIAS:
            id_agencia = agencia["id"]
            # (nome, argumentos, mostrar corpo) - a declaracao usa os mesmos
            # argumentos da agencia para que o passive declare BATHA com a fila real.
            filas = (
                (nome_fila(id_agencia), argumentos_fila(id_agencia), False),
                (nome_fila_falhas(id_agencia), {"x-message-ttl": TTL_FILA_FALHAS_MS}, mostrar_corpo),
            )
            for fila, argumentos, com_corpo in filas:
                mensagens, consumidores = _contar(conexao, fila, argumentos)
                if mensagens is None:
                    print(f"{fila:30} {'nao existe':>10} {'-':>14}")
                    continue
                print(f"{fila:30} {mensagens:>10} {consumidores:>14}")
                if com_corpo and mensagens:
                    _ler_falhas(conexao, fila, mensagens)
                if alerta and consumidores > 1:
                    print(
                        f"    AVISO: {consumidores} consumidores em {fila}. Mais de um "
                        "processo conectado na mesma fila: a mensagem pode ser entregue "
                        "na agencia errada. (0 consumidores e o esperado no teste de "
                        "resiliencia, com a agencia fora do ar.)"
                    )
    finally:
        conexao.close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())