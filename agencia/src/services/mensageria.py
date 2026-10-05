import json
import os
import threading

import pika

# Topologia do Sprint 2 (Publish/Subscribe):
#   - uma exchange do tipo topic, compartilhada por todas as agencias;
#   - uma fila duravel por agencia (fila-agencia-<id>);
#   - routing key no formato agencia.<id>.creditar, para que cada agencia receba
#     apenas os creditos destinados a ela, mesmo com a exchange sendo comum.
EXCHANGE = "iceibank.eventos"

URL_RABBITMQ = os.getenv("RABBITMQ_URL")
if not URL_RABBITMQ:
    # Falhar aqui, no import, evita o erro confuso de conexao para quem lupa de
    # definir a variavel de ambiente antes de subir a agencia.
    raise RuntimeError(
        "Defina a variavel de ambiente RABBITMQ_URL com a URL AMQP da sua instancia "
        "do CloudAMQP (ex.: amqps://usuario:senha@host/vhost) antes de iniciar a agencia."
    )


def nome_fila(id_agencia):
    return f"fila-agencia-{id_agencia}"


def routing_key_credito(id_agencia):
    return f"agencia.{id_agencia}.creditar"


# Conexao do PUBLICADOR: uma unica, compartilhada, protegida por lock. As rotas
# HTTP rodam no threadpool do uvicorn e todas publicam por aqui; como o
# BlockingConnection do pika nao e thread-safe, o lock serializa os basic_publish.
_lock_publicacao = threading.RLock()
_conexao_publicacao = None
_canal_publicacao = None


def _abrir_canal_publicacao():
    """Abre (ou reaproveita) a conexao do publicador. Exige o lock ocupado."""
    global _conexao_publicacao, _canal_publicacao
    if _canal_publicacao is None or _conexao_publicacao.is_closed:
        parametros = pika.URLParameters(URL_RABBITMQ)
        _conexao_publicacao = pika.BlockingConnection(parametros)
        _canal_publicacao = _conexao_publicacao.channel()
        _canal_publicacao.exchange_declare(
            exchange=EXCHANGE, exchange_type="topic", durable=True
        )
        # Modo confirmacao: basic_publish so retorna quando o broker confirma que
        # recebeu a mensagem. Sem isso, a resposta HTTP 200 diria "publicada" sem
        # nenhuma garantia de que o broker realmente assumiu a mensagem.
        _canal_publicacao.confirm_delivery()
    return _canal_publicacao


def publicar(routing_key, mensagem):
    """Publica um evento na exchange iceibank.eventos.

    durable na exchange/fila + delivery_mode Persistent sao o que garante que
    uma mensagem publicada para uma agencia fora do ar nao se perde: ela fica
    gravada no disco do broker ate alguem consumir.
    """
    with _lock_publicacao:
        canal = _abrir_canal_publicacao()
        canal.basic_publish(
            exchange=EXCHANGE,
            routing_key=routing_key,
            body=json.dumps(mensagem).encode("utf-8"),
            properties=pika.BasicProperties(
                content_type="application/json",
                delivery_mode=pika.DeliveryMode.Persistent,
            ),
        )


def fechar_publicador():
    """Fecha a conexao do publicador (chamado no shutdown do servidor)."""
    global _conexao_publicacao, _canal_publicacao
    with _lock_publicacao:
        if _conexao_publicacao is not None and _conexao_publicacao.is_open:
            _conexao_publicacao.close()
        _conexao_publicacao = None
        _canal_publicacao = None


# Conexao do CONSUMIDOR: separada da do publicador, porque o consumo fica preso
# esperando frames do broker e nao pode compartilhar canal com quem so publica.
_consumidor = {"thread": None, "parar": None}


def iniciar_consumidor(id_agencia, ao_receber_mensagem):
    """Declara a fila desta agencia, assina a exchange e comeca a consumir.

    Roda em uma thread daemon: o consumo e bloqueante, e se rodasse na thread do
    servidor HTTP ele travaria a API inteira. A thread e daemon para nao
    impedir o encerramento do processo no Ctrl+C.
    """
    parar = threading.Event()

    def _consumir():
        conexao = pika.BlockingConnection(pika.URLParameters(URL_RABBITMQ))
        try:
            canal = conexao.channel()
            canal.exchange_declare(exchange=EXCHANGE, exchange_type="topic", durable=True)
            canal.queue_declare(queue=nome_fila(id_agencia), durable=True)
            canal.queue_bind(
                queue=nome_fila(id_agencia),
                exchange=EXCHANGE,
                routing_key=routing_key_credito(id_agencia),
            )
            # Uma mensagem por vez: preserva a ordem de causalidade dos creditos.
            canal.basic_qos(prefetch_count=1)

            def ao_receber(_canal, metodo, _props, corpo):
                mensagem = json.loads(corpo.decode("utf-8"))
                try:
                    ao_receber_mensagem(mensagem)
                except Exception as erro:  # noqa: BLE001
                    # Nao fazer ack: sem confirmacao, a mensagem volta para a
                    # fila quando a conexao cair. Em producao o caminho esperado
                    # seria o contrario - nack sem requeue para uma dead-letter
                    # queue, para nao ficar em laco com uma mensagem "venenosa"
                    # (funcionalidade adicional do Sprint 2, Etapa 4).
                    print(f"[RabbitMQ] erro ao tratar mensagem: {erro}")
                else:
                    _canal.basic_ack(delivery_tag=metodo.delivery_tag)

            canal.basic_consume(
                queue=nome_fila(id_agencia), on_message_callback=ao_receber, auto_ack=False
            )
            print(
                f"[RabbitMQ] agencia {id_agencia} consumindo {nome_fila(id_agencia)} "
                f"(routing key {routing_key_credito(id_agencia)})",
                flush=True,
            )
            # Em vez de start_consuming() (que fica preso esperando frames e nunca
            # olha um flag de parada), o consumo e feito em janelas curtas: cada
            # volta de process_data_events devolve o controle, e a thread confere
            # o Evento de parada. Isso torna o encerramento POSSIVEL - chamar
            # stop_consuming() de outra thread, como manda a documentacao do
            # pika, trava o processo no Ctrl+C.
            while not parar.is_set() and not conexao.is_closed:
                # process_data_events devolve None (nao um booleano): quem
                # controla o fim do laco sao o Evento de parada e o estado da
                # conexao, nunca o retorno do metodo.
                conexao.process_data_events(time_limit=0.5)
        except Exception as erro:  # noqa: BLE001
            print(f"[RabbitMQ] consumidor da agencia {id_agencia} encerrou: {erro}", flush=True)
        finally:
            if conexao.is_open:
                conexao.close()
            print(f"[RabbitMQ] consumidor da agencia {id_agencia} finalizado", flush=True)

    thread = threading.Thread(
        target=_consumir, name=f"consumidor-agencia-{id_agencia}", daemon=True
    )
    _consumidor["thread"] = thread
    _consumidor["parar"] = parar
    thread.start()


def parar_consumidor():
    """Encerra o consumidor e espera a thread terminar (chamado no shutdown)."""
    parar = _consumidor.get("parar")
    thread = _consumidor.get("thread")
    if parar is None:
        return
    parar.set()
    if thread is not None:
        thread.join(timeout=5)