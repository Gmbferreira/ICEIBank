"""Consulta as filas da instancia do RabbitMQ (material de evidencia do Sprint 2).

Mostra, para cada agencia, quantas mensagens estao retidas na fila e quantos
consumidores estao conectados. E o que prova, no teste de resiliencia, que a
mensagem publicada para uma agencia fora do ar ficou esperando na fila em vez de
ter sido perdida.

Uso (com RABBITMQ_URL definida):
    .\\.venv\\Scripts\\python.exe filas.py --alerta

Com --alerta, avisa quando alguma fila tem consumidores diferentes de 1. Como as
filas sao compartilhadas por todas as agencias do mesmo vhost, um consumidor a
mais significa que outro processo (agencia de outro terminal, ou uma instancia
esquecida de um teste anterior) pode roubar a mensagem antes da hora - o
credito apareceria na agency errada.
"""

import os
import sys

import pika


def main():
    alerta = "--alerta" in sys.argv
    url = os.getenv("RABBITMQ_URL")
    if not url:
        print("Defina RABBITMQ_URL antes de executar este script.")
        return 1

    # Os imports vem depois da checagem: src.services.mensageria exige a URL no
    # import e, se ela faltar, o traceback esconderia a mensagem acima.
    # Executar "python agencia/filas.py" ja coloca a pasta agencia/ no sys.path.
    from src.services.mensageria import EXCHANGE, nome_fila

    import src.config as config

    conexao = pika.BlockingConnection(pika.URLParameters(url))
    try:
        canal = conexao.channel()
        print(f"exchange: {EXCHANGE} (topic, durable)")
        print(f"{'fila':22} {'mensagens':>10} {'consumidores':>14}")
        for agencia in config.AGENCIAS:
            fila = nome_fila(agencia["id"])
            try:
                resultado = canal.queue_declare(queue=fila, durable=True, passive=True)
                print(f"{fila:22} {resultado.method.message_count:>10} {resultado.method.consumer_count:>14}")
                if alerta and resultado.method.consumer_count > 1:
                    print(
                        f"    AVISO: {resultado.method.consumer_count} consumidores em {fila}. "
                        "Mais de um processo conectado na mesma fila: a mensagem pode ser "
                        "entregue na agencia errada. (0 consumidores e o esperado no teste "
                        "de resiliencia, com a agencia fora do ar.)"
                    )
            except pika.exceptions.ChannelClosedByBroker:
                print(f"{fila:22} {'nao existe':>10} {'-':>14}")
    finally:
        conexao.close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())