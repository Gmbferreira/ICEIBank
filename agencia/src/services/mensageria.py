import json
import os
import threading

import pika

# Topologia do Sprint 2 (Publish/Subscribe):
#   - uma exchange do tipo topic, compartilhada por todas as agencias;
#   - uma fila duravel por agencia (fila-agencia-<id>);
#   - routing key no formato agencia.<id>.creditar, para que cada agencia receba
#     apenas os creditos destinados a ela, mesmo com a exchange sendo comum.
#   - uma dead-letter exchange (iceibank.dlx) e uma fila de falhas por agencia
#     (fila-agencia-<id>.falhas): o que a agencia nao conseguiu aplicar nao e
#     descartado em silencio, e guardado para inspecao.
EXCHANGE = "iceibank.eventos"
EXCHANGE_DLX = "iceibank.dlx"

# As mensagens rejeitadas ficam na DLQ por uma semana e depois somem sozinhas:
# elas servem para inspecao/diagnostico, nao para reprocessamento automatico.
# (Se o requisito for reentrega manual, deixar sem TTL.)
TTL_FILA_FALHAS_MS = 7 * 24 * 60 * 60 * 1000

URL_RABBITMQ = os.getenv("RABBITMQ_URL")
if not URL_RABBITMQ:
    # Falhar aqui, no import, evita o erro confuso de conexao para quem lupa de
    # definir a variavel de ambiente antes de subir a agencia.
    raise RuntimeError(
        "Defina a variavel de ambiente RABBITMQ_URL com a URL AMQP da sua instancia "
        "do CloudAMQP (ex.: amqps://usuario:senha@host/vhost) antes de iniciar a agencia."
    )


class CreditoRecusado(Exception):
    """Recusa de negocio: a mensagem chegou, mas nao pode ser aplicada.

    Separar isto de um erro inesperado e o que permite decidir, no consumidor, entre
    "descartar" e "guardar na dead-letter queue". Um erro de programacao tambem
    cai na DLQ (ninguem quer perder a evidencia), mas o log mostra os dois casos
    com clareza.
    """


def nome_fila(id_agencia):
    return f"fila-agencia-{id_agencia}"


def nome_fila_falhas(id_agencia):
    """Fila de mensagens que a agencia recebeu e nao conseguiu aplicar."""
    return f"fila-agencia-{id_agencia}.falhas"


def routing_key_credito(id_agencia):
    return f"agencia.{id_agencia}.creditar"


def routing_key_falha(id_agencia):
    return f"agencia.{id_agencia}.creditar.falha"


def argumentos_fila(id_agencia):
    """Argumentos de declaracao da fila principal (dead-letter).

    RabbitMQ so aceita re-declarar uma fila existente com os MESMOS argumentos: se
    as filas do projeto ja existissem sem estes dois campos, o queue_declare
    responderia 406 PRECONDITION_FAILED e o consumidor morreria no startup.
    """
    return {
        "x-dead-letter-exchange": EXCHANGE_DLX,
        "x-dead-letter-routing-key": routing_key_falha(id_agencia),
    }


def descrever_erro(erro):
    """Texto util para registrar uma excecao do pika.

    O str() de varias excecoes do pika vem vazio - AMQPConnectionError, por
    exemplo, devolve "" mesmo tendo a causa real em .args. Sem isso, o log da
    evidencia mostrava "erro": "" e a falha ficava sem explicacao. O nome da
    excecao vem sempre; a causa vem do str() quando existe e dos args quando nao.
    """
    detalhe = str(erro) or repr(getattr(erro, "args", ()))
    return f"{type(erro).__name__}: {detalhe}"


def routing_key_credito(id_agencia):
    return f"agencia.{id_agencia}.creditar"


# Conexao do PUBLICADOR: uma unica, compartilhada, protegida por lock. As rotas
# HTTP rodam no threadpool do uvicorn e todas publicam por aqui; como o
# BlockingConnection do pika nao e thread-safe, o lock serializa os basic_publish.
_lock_publicacao = threading.RLock()
_conexao_publicacao = None
_canal_publicacao = None


def _conectar_publicador():
    parametros = pika.URLParameters(URL_RABBITMQ)
    # heartbeat=0 desliga o mecanismo de heartbeat de proposito. Um
    # BlockingConnection so envia heartbeats quando alguem chama
    # process_data_events, e o publicador fica ocioso entre transferencias: com
    # heartbeat ativo o broker dropava a conexao depois de ~2 intervalos e a
    # transferencia seguinte falhava com "Stream connection lost: EOF" mesmo com o
    # RabbitMQ saudavel. Sem heartbeat, quem detecta conexao morta e o proprio
    # basic_publish - e o retry de publicar() refaz a conexao.
    parametros.heartbeat = 0
    # Se o broker/publicar ficar bloqueado, nao travar a request HTTP por muito
    # tempo: o chamador precisa receber o erro para reverter o debito.
    parametros.blocked_connection_timeout = 5
    parametros.socket_timeout = 5
    return pika.BlockingConnection(parametros)


def _abrir_canal_publicacao():
    """Abre (ou reaproveita) a conexao do publicador. Exige o lock ocupado."""
    global _conexao_publicacao, _canal_publicacao
    if _canal_publicacao is None or _conexao_publicacao.is_closed:
        _conexao_publicacao = _conectar_publicador()
        _canal_publicacao = _conexao_publicacao.channel()
        _canal_publicacao.exchange_declare(
            exchange=EXCHANGE, exchange_type="topic", durable=True
        )
        # Modo confirmacao: basic_publish so retorna quando o broker confirma que
        # recebeu a mensagem. Sem isso, a resposta HTTP 200 diria "publicada" sem
        # nenhuma garantia de que o broker realmente assumiu a mensagem.
        _canal_publicacao.confirm_delivery()
    return _canal_publicacao


def _descartar_publicador():
    """Joga fora a conexao do publicador, para a proxima tentativa reabrir."""
    global _conexao_publicacao, _canal_publicacao
    conexao, _conexao_publicacao, _canal_publicacao = _conexao_publicacao, None, None
    try:
        if conexao is not None and conexao.is_open:
            conexao.close()
    except Exception:  # noqa: BLE001 - ja estamos descartando a conexao
        pass


def publicar(routing_key, mensagem):
    """Publica um evento na exchange iceibank.eventos.

    durable na exchange/fila + delivery_mode Persistent sao o que garante que
    uma mensagem publicada para uma agencia fora do ar nao se perde: ela fica
    gravada no disco do broker ate alguem consumir.

    Uma tentativa extra quando a conexao estava morta: com heartbeat desligado
    (ver _conectar_publicador), uma conexao perdida nao e mais detectada pelo
    broker, so pelo basic_publish - e ai o retry evita devolver 502 por causa de
    um simples salto de rede. Um broker realmente fora do ar continua falhando nas
    duas tentativas.
    """
    corpo = json.dumps(mensagem).encode("utf-8")
    with _lock_publicacao:
        for tentativa in (1, 2):
            try:
                canal = _abrir_canal_publicacao()
                canal.basic_publish(
                    exchange=EXCHANGE,
                    routing_key=routing_key,
                    body=corpo,
                    properties=pika.BasicProperties(
                        content_type="application/json",
                        delivery_mode=pika.DeliveryMode.Persistent,
                    ),
                )
                return
            except (pika.exceptions.AMQPError, OSError):
                _descartar_publicador()
                if tentativa == 2:
                    raise


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

    Politica de confirmacao (o coracao da Etapa 4 - dead-letter queue):
        mensagem aplicada            -> basic_ack
        recusa de negocio            -> basic_nack(requeue=False) -> DLQ
        erro inesperado              -> basic_nack(requeue=False) -> DLQ
        agencia cai no meio do trato -> sem confirmacao, o broker devolve o
                                         delivery_tag para a fila (a garantia de
                                         "ao menos uma vez" do AMQP)
    """
    parar = threading.Event()

    def _consumir():
        conexao = pika.BlockingConnection(pika.URLParameters(URL_RABBITMQ))
        try:
            canal = conexao.channel()
            canal.exchange_declare(exchange=EXCHANGE, exchange_type="topic", durable=True)
            canal.exchange_declare(exchange=EXCHANGE_DLX, exchange_type="topic", durable=True)
            canal.queue_declare(
                queue=nome_fila(id_agencia), durable=True, arguments=argumentos_fila(id_agencia)
            )
            canal.queue_bind(
                queue=nome_fila(id_agencia),
                exchange=EXCHANGE,
                routing_key=routing_key_credito(id_agencia),
            )
            # A fila de falhas: uma por agencia, onde o broker deposita o que foi
            # descartado com basic_nack(requeue=False).
            canal.queue_declare(
                queue=nome_fila_falhas(id_agencia),
                durable=True,
                arguments={"x-message-ttl": TTL_FILA_FALHAS_MS},
            )
            canal.queue_bind(
                queue=nome_fila_falhas(id_agencia),
                exchange=EXCHANGE_DLX,
                routing_key=routing_key_falha(id_agencia),
            )
            # Uma mensagem por vez: preserva a ordem de causalidade dos creditos.
            canal.basic_qos(prefetch_count=1)

            def ao_receber(_canal, metodo, _props, corpo):
                mensagem = json.loads(corpo.decode("utf-8"))
                try:
                    ao_receber_mensagem(mensagem)
                except CreditoRecusado as recusa:
                    # Recusa de negocio (ex.: a conta destino nao existe mais). A
                    # mensagem nao volta para a fila principal - assim nao ha laco
                    # de mensagem "venenosa" - e o broker a deposita na DLQ.
                    print(f"[RabbitMQ] credito recusado: {recusa}", flush=True)
                    _canal.basic_nack(delivery_tag=metodo.delivery_tag, requeue=False)
                except Exception as erro:  # noqa: BLE001
                    # Erro inesperado tambem vai para a DLQ: perder a mensagem
                    # silenciosamente seria pior do que deixar o registro pendente
                    # para alguem investigar.
                    print(f"[RabbitMQ] erro ao tratar mensagem: {descrever_erro(erro)}")
                    _canal.basic_nack(delivery_tag=metodo.delivery_tag, requeue=False)
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
            print(
            f"[RabbitMQ] consumidor da agencia {id_agencia} encerrou: "
            f"{descrever_erro(erro)}",
            flush=True,
        )
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