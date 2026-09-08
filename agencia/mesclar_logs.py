import json
import os

# agencia/mesclar_logs.py -> agencia/data
PASTA_DADOS = os.path.join(os.path.dirname(os.path.abspath(__file__)), "data")


def main():
    arquivos = [f for f in os.listdir(PASTA_DADOS) if f.endswith(".jsonl")]
    if not arquivos:
        print("Nenhum arquivo de log encontrado em agencia/data/.")
        return

    todos_eventos = []
    for arquivo in arquivos:
        with open(os.path.join(PASTA_DADOS, arquivo), encoding="utf-8") as arquivo_aberto:
            for linha in arquivo_aberto:
                linha = linha.strip()
                if linha:
                    todos_eventos.append(json.loads(linha))

    todos_eventos.sort(key=lambda e: e["timestampLamport"])

    print("=== Linha do tempo unificada (ordenada por relogio de Lamport) ===")
    for evento in todos_eventos:
        print(
            f"[Lamport {evento['timestampLamport']}] ({evento['horaParede']}) "
            f"{evento['agencia']} - {evento['tipo']}",
            json.dumps(evento["detalhes"]),
        )


if __name__ == "__main__":
    main()