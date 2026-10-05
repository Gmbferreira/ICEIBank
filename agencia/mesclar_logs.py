"""Gera a linha do tempo unificada dos 3 servicingicos, agora por causalidade.

O Sprint 1 ordenava tudo por um unico numero (relogio de Lamport). No Sprint 2
o carimbo e um vetor por agencia, e vetores nao se comparam com < : nao existe
"[3,2,0] < [1,5,0]". A ordem que importa aqui nao e "qual numero primeiro", e
"o que veio antes por causa de quem".

Por isso a ordenacao e topologica (algoritmo de Kahn): um evento so aparece
depois que todos os eventos que ele causou ja apareceram. A Definicao de
causalidade e a do relogio vetorial:

    Y causou X  <=>  para todo i, vetor(Y)[i] <= vetor(X)[i]
                   e existe pelo menos um i com vetor(Y)[i] < vetor(X)[i]

Quando dois eventos nao se comparam em nenhuma direcao (nenhum e menor-ou-igual
ao outro em todas as posicoes), eles sao COMPROVADAMENTE CONCORRENTES: houve
nenhum exchanges de mensagens entre os dois. O script lista esses pares no
final, que e a razao de usar vetorial em vez de Lamport.

Eventos do Sprint 1 (timestampLamport, um contador inteiro) sao convertidos
automaticamente: o contador vira um vetor com o valor so na posicao da propria
agencia, [n, 0, 0]. Assim o script funciona com logs antigos e novos juntos,
sem precisar apagar nada.

Uso:
    python mesclar_logs.py            # linha do tempo + pares concorrentes
    python mesclar_logs.py --csv      # imprime so a tabela, em CSV
"""

import argparse
import json
import os

# agencia/mesclar_logs.py -> agencia/data
PASTA_DADOS = os.path.join(os.path.dirname(os.path.abspath(__file__)), "data")


def id_da_agencia(evento):
    """"agencia-1" -> 1. Tolera evento sem o campo, devolvendo None."""
    nome = evento.get("agencia", "")
    try:
        return int(nome.rsplit("-", 1)[1])
    except (IndexError, ValueError):
        return None


def vetor_do_evento(evento, total_agencias):
    """Devolve (vetor, veio_do_sprint1).

    Events do Sprint 2 ja gravam timestampVetorial. Os do Sprint 1 so tem
    timestampLamport, e sao convertidos aqui - sem essa conversao o script
    quebraria com KeyError ao encontrar um log antigo na pasta.
    """
    vetor = evento.get("timestampVetorial")
    if vetor is not None:
        return list(vetor), False
    contador = evento.get("timestampLamport")
    if contador is None:
        raise KeyError(
            f"evento sem timestamp nem vetor: {evento.get('tipo')} "
            f"em {evento.get('agencia')}"
        )
    vetor = [0] * total_agencias
    id_agencia = id_da_agencia(evento)
    if id_agencia is not None and 0 <= id_agencia < total_agencias:
        vetor[id_agencia] = contador
    return vetor, True


def causa(de_onde, para):
    """True se o evento 'de_onde' causou o evento 'para' (vetor menor-ou-igual).

    Exige que sejam estritamente diferentes em pelo menos uma posicao: dois
    eventos com o mesmo vetor sao concorrentes, nao um causa do outro.
    """
    if de_onde == para:
        return False
    return all(a <= b for a, b in zip(de_onde, para)) and any(a < b for a, b in zip(de_onde, para))


def ordenar_por_causa(eventos):
    """Ordenacao topologica: so emite um evento depois de todas as suas causas.

    Empates (varios eventos prontos ao mesmo tempo) sao desempatados pelo
    relogio de parede, para que a execucao seja reproduzivel - a ordem entre
    eventos concorrentes nao e determinada pelo vetorial, e sim por quem ficou
    pronto antes.
    """
    restantes = list(eventos)
    ordenados = []
    while restantes:
        prontos = [
            evento
            for evento in restantes
            if not any(causa(outro["vetor"], evento["vetor"]) for outro in restantes if outro is not evento)
        ]
        # Em um log bem formado nunca acontece: vetores causam um DAG. A guarda
        # evita loop infinito e avisa que ha inconsistencia nos dados.
        if not prontos:
            raise RuntimeError(
                "Ciclo de causalidade detectado nos logs - os vetores formam um "
                "ciclo, o que e impossivel com relogio vetorial. Logs corrompidos?"
            )
        proximo = min(
            prontos,
            key=lambda e: (e["horaParede"], e["agencia"], e["ordem"]),
        )
        ordenados.append(proximo)
        restantes.remove(proximo)
    return ordenados


def carregar_eventos():
    """Le todos os .jsonl da pasta data/ e anexa vetor e posicao de origem."""
    arquivos = sorted(
        f for f in os.listdir(PASTA_DADOS) if f.endswith(".jsonl")
    )
    if not arquivos:
        raise SystemExit(f"Nenhum arquivo .jsonl encontrado em {PASTA_DADOS}.")

    brutos = []
    for arquivo in arquivos:
        caminho = os.path.join(PASTA_DADOS, arquivo)
        with open(caminho, encoding="utf-8") as aberto:
            for numero, linha in enumerate(aberto):
                linha = linha.strip()
                if linha:
                    evento = json.loads(linha)
                    evento["arquivo"] = arquivo
                    evento["ordem"] = numero
                    brutos.append(evento)

    # O numero de agencias vem dos proprios nomes de arquivo (eventos-agencia-N),
    # e nao de um valor fixo: assim o script continua valendo se o numero de
    # agencias mudar.
    ids = {id_da_agencia(evento) for evento in brutos}
    ids.discard(None)
    total_agencias = max(ids) + 1 if ids else 1

    for evento in brutos:
        evento["vetor"], evento["do_sprint1"] = vetor_do_evento(evento, total_agencias)
    return brutos, arquivos, total_agencias


def pares_concorrentes(eventos):
    """Pares CONSECUTIVOS na ordem final que nao se causam.

    Sao os unicos empates que o desempate por relogio de parede resolveu, e os
    unicos que interessam a leitura da linha do tempo: entre dois eventos
    vizinhos sem relacao de causa, a ordem e arbitraria.

    Deliberadamente nao sao listados todos os pares concorrentes do log. Num log
    com varias execucoes misturadas (ver aviso de vetores repetidos) isso daria
    centenas de pares sem informacao util.
    """
    pares = []
    for primeiro, segundo in zip(eventos, eventos[1:]):
        if causa(primeiro["vetor"], segundo["vetor"]) or causa(segundo["vetor"], primeiro["vetor"]):
            continue
        pares.append((primeiro, segundo))
    return pares


def vetores_repetidos(eventos):
    """Vetores que aparecem em mais de um evento.

    Isso nao deveria acontecer em uma execucao continua: cada evento incrementa
    a propria posicao, entao dois eventos da mesma agencia nunca compartilham
    vetor. Repeticao significa que o log misturou mais de uma vida do processo -
    o relogio vetorial vive na memoria e zera quando a agencia reinicia (como o
    de Lamport fazia no Sprint 1).

    Esse aviso importa porque e ele que torna a linha do tempo destes logs
    apenas uma demonstracao de ordenacao: eventos de execucoes diferentes nao sao comparaveis
    entre si, ja que cada execucao recomecou do zero.
    """
    vistos = {}
    repetidos = 0
    for evento in eventos:
        chave = tuple(evento["vetor"])
        vistos[chave] = vistos.get(chave, 0) + 1
        if vistos[chave] == 2:
            repetidos += 1
    return repetidos


def imprimir_tabela(eventos):
    print("=== Linha do tempo causal (ordem topologica por relogio vetorial) ===")
    print()
    print(f"{'#':>3}  {'vetor':14}  {'agencia':10}  {'tipo':30}  arquivo")
    for posicao, evento in enumerate(eventos, start=1):
        vetor = "[" + ", ".join(str(i) for i in evento["vetor"]) + "]"
        marca = " (Sprint 1)" if evento["do_sprint1"] else ""
        print(
            f"{posicao:>3}  {vetor:14}  {evento['agencia']:10}  "
            f"{evento['tipo'] + marca:30}  {evento['arquivo']}"
        )


def imprimir_concorrencia(pares):
    print()
    if not pares:
        print("Nenhuma empate na linha do tempo: cada vizinho causou o anterior.")
        return
    print(f"=== Empates na ordem ({len(pares)} pares vizinhos sem relacao de causa) ===")
    print()
    print("Entre estes dois eventos a ordem e ARBITRARIA - nenhum causou o outro,")
    print("e e o que o relogio de Lamport nao conseguia dizer (ele dava uma ordem")
    print("total e falsa). O desempate abaixo veio do relogio de parede.")
    print()
    for primeiro, segundo in pares:
        vetor_a = "[" + ", ".join(str(i) for i in primeiro["vetor"]) + "]"
        vetor_b = "[" + ", ".join(str(i) for i in segundo["vetor"]) + "]"
        print(f"  {vetor_a:12} {primeiro['agencia']:10} {primeiro['tipo']}")
        print(f"  {vetor_b:12} {segundo['agencia']:10} {segundo['tipo']}")
        print(f"  {'':12} wall clock: {primeiro.get('horaParede', '')} / {segundo.get('horaParede', '')}")
        print()


def imprimir_csv(eventos):
    print("posicao,vetor,agencia,tipo,horaParede,detalhes")
    for posicao, evento in enumerate(eventos, start=1):
        vetor = " ".join(str(i) for i in evento["vetor"])
        detalhes = json.dumps(evento["detalhes"], ensure_ascii=False)
        print(
            f"{posicao},{vetor},\"{evento['agencia']}\",\"{evento['tipo']}\","
            f"\"{evento.get('horaParede', '')}\",\"{detalhes}\""
        )


def main():
    analisador = argparse.ArgumentParser(description=__doc__)
    analisador.add_argument("--csv", action="store_true", help="imprime so a tabela em CSV")
    argumentos = analisador.parse_args()

    brutos, arquivos, total_agencias = carregar_eventos()
    ordenados = ordenar_por_causa(brutos)

    if argumentos.csv:
        imprimir_csv(ordenados)
        return

    print(f"Arquivos lidos ({len(arquivos)}): {', '.join(arquivos)}")
    print(f"Total de eventos: {len(brutos)}  |  agencias: {total_agencias}")
    convertidos = sum(1 for evento in brutos if evento["do_sprint1"])
    if convertidos:
        print(
            f"Eventos do Sprint 1 convertidos para vetor (contador -> posicao "
            f"propria): {convertidos}"
        )
    repetidos = vetores_repetidos(brutos)
    if repetidos:
        print()
        print(f"AVISO: {repetidos} vetores se repetem entre eventos diferentes.")
        print("  O relogio vetorial vive na memoria e zera a cada reinicio da agencia,")
        print("  entao estes logs misturam mais de uma execucao. A ORDEM CAUSAL dentro de")
        print("  cada execucao continua correta, mas eventos de execucoes diferentes nao")
        print("  sao comparaveis entre si (todos recomecaram do zero). Para uma linha do")
        print("  tempo limpa, gere um log so de uma execucao: apague agencia/data/*.jsonl,")
        print("  suba as 3 agencias e rode o roteiro de novo.")
    print()

    imprimir_tabela(ordenados)
    imprimir_concorrencia(pares_concorrentes(ordenados))


if __name__ == "__main__":
    main()